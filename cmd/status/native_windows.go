package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/mem"
	"golang.org/x/sys/windows"
)

// The Windows readers. They open nothing for writing, start no other program
// and need no elevation. Each one returns raw counters; the rates are
// calculated in the sampler.

var (
	kernel32                             = windows.NewLazySystemDLL("kernel32.dll")
	procGetTickCount64                   = kernel32.NewProc("GetTickCount64")
	procGetLogicalProcessorInformationEx = kernel32.NewProc("GetLogicalProcessorInformationEx")
)

func nativeSources() Sources {
	return Sources{
		CPU:         readCPU,
		Memory:      readMemory,
		Swap:        readSwap,
		Drives:      readDrives,
		DiskIO:      readDiskIO,
		NetCounters: readNetCounters,
		Adapters:    readAdapters,
		Processes:   readProcesses,
		Uptime:      readUptime,
		Platform:    readPlatform,
	}
}

// ---------------------------------------------------------------------------
// CPU

// processorPerformance is SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION. Times are
// in 100 ns units and the kernel time includes the idle time.
type processorPerformance struct {
	IdleTime       int64
	KernelTime     int64
	UserTime       int64
	DpcTime        int64
	InterruptTime  int64
	InterruptCount uint32
}

// maxProcessors bounds the buffer of the processor query; the call fails
// rather than truncates when the machine has more.
const maxProcessors = 1024

func readCPU() (CPUReading, error) {
	buf := make([]processorPerformance, maxProcessors)
	size := uint32(len(buf)) * uint32(unsafe.Sizeof(buf[0]))
	var returned uint32
	if err := windows.NtQuerySystemInformation(windows.SystemProcessorPerformanceInformation,
		unsafe.Pointer(&buf[0]), size, &returned); err != nil {
		return CPUReading{}, err
	}
	n := int(returned) / int(unsafe.Sizeof(buf[0]))
	if n == 0 {
		return CPUReading{}, errors.New("no processor times returned")
	}
	per := make([]CPUTimes, n)
	for i, b := range buf[:n] {
		per[i] = CPUTimes{Idle: uint64(b.IdleTime), Total: uint64(b.KernelTime) + uint64(b.UserTime)}
	}
	return CPUReading{PerCPU: per, PhysicalCores: physicalCores()}, nil
}

var (
	physicalOnce  sync.Once
	physicalCount int
)

// physicalCores counts the processor cores from the system's processor
// topology. It returns 0 when the system does not say.
func physicalCores() int {
	physicalOnce.Do(func() {
		const relationProcessorCore = 0
		var length uint32
		// The first call only asks for the size and is expected to fail.
		if r, _, _ := procGetLogicalProcessorInformationEx.Call(relationProcessorCore, 0, uintptr(unsafe.Pointer(&length))); r != 0 || length == 0 {
			return
		}
		buf := make([]byte, length)
		if r, _, _ := procGetLogicalProcessorInformationEx.Call(relationProcessorCore,
			uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&length))); r == 0 {
			return
		}
		// Every record starts with its relationship and its size, both 32 bit.
		for off := uint32(0); off+8 <= length; {
			rel := binary.LittleEndian.Uint32(buf[off:])
			size := binary.LittleEndian.Uint32(buf[off+4:])
			if size == 0 {
				break
			}
			if rel == relationProcessorCore {
				physicalCount++
			}
			off += size
		}
	})
	return physicalCount
}

// ---------------------------------------------------------------------------
// Memory

func readMemory() (MemoryReading, error) {
	v, err := mem.VirtualMemory()
	if err != nil {
		return MemoryReading{}, err
	}
	return MemoryReading{Total: v.Total, Available: v.Available}, nil
}

// readSwap sums the page files. The commit limit is not a page file and is
// not used here.
func readSwap() (SwapReading, error) {
	files, err := mem.SwapDevices()
	if err != nil {
		return SwapReading{}, err
	}
	var r SwapReading
	for _, f := range files {
		r.Used += f.UsedBytes
		r.Total += f.UsedBytes + f.FreeBytes
	}
	return r, nil
}

// ---------------------------------------------------------------------------
// Drives

// readDrives lists fixed and removable drives with a letter. Network and
// optical drives are skipped before any size query: asking an unreachable
// network drive for its size can block for a long time.
func readDrives() ([]DriveReading, error) {
	mask, err := windows.GetLogicalDrives()
	if mask == 0 {
		if err == nil {
			err = errors.New("no drives")
		}
		return nil, err
	}
	var out []DriveReading
	for i := 0; i < 26; i++ {
		if mask&(1<<uint(i)) == 0 {
			continue
		}
		root, err := windows.UTF16PtrFromString(string(rune('A'+i)) + `:\`)
		if err != nil {
			continue
		}
		kind := windows.GetDriveType(root)
		if kind != windows.DRIVE_FIXED && kind != windows.DRIVE_REMOVABLE {
			continue
		}
		// Total free space of the volume, not the part left for the user's quota.
		var freeToCaller, total, free uint64
		if err := windows.GetDiskFreeSpaceEx(root, &freeToCaller, &total, &free); err != nil || total == 0 {
			continue
		}
		out = append(out, DriveReading{
			Name:      string(rune('A'+i)) + `:\`,
			Total:     total,
			Free:      free,
			FSType:    fileSystemName(root),
			Removable: kind == windows.DRIVE_REMOVABLE,
		})
	}
	return out, nil
}

func fileSystemName(root *uint16) string {
	var name [windows.MAX_PATH + 1]uint16
	if err := windows.GetVolumeInformation(root, nil, 0, nil, nil, nil, &name[0], uint32(len(name))); err != nil {
		return ""
	}
	return windows.UTF16ToString(name[:])
}

// readDiskIO sums the byte counters of all fixed drives. gopsutil opens each
// volume with access rights 0, which only allows the query.
func readDiskIO() (DiskIOReading, error) {
	counters, err := disk.IOCounters()
	if err != nil {
		return DiskIOReading{}, err
	}
	if len(counters) == 0 {
		return DiskIOReading{}, errors.New("no fixed drive")
	}
	var r DiskIOReading
	for _, c := range counters {
		r.ReadBytes += c.ReadBytes
		r.WriteBytes += c.WriteBytes
	}
	return r, nil
}

// ---------------------------------------------------------------------------
// Network

const (
	ifTypePPP              = 23
	ifTypeSoftwareLoopback = 24
	ifTypeProprietaryVirt  = 53
	ifTypeTunnel           = 131
)

type adapterInfo struct {
	name    string
	luid    uint64
	index   uint32
	ipv4    []string
	gateway bool
	metric  uint32
	tunnel  bool
}

// queryAdapters lists the adapters that are in service and no loopback
// adapter, in the order of the system.
func queryAdapters() ([]adapterInfo, error) {
	// Only the gateway addresses are needed besides the defaults.
	const flags = windows.GAA_FLAG_INCLUDE_GATEWAYS
	size := uint32(32 * 1024)
	for try := 0; try < 6; try++ {
		buf := make([]byte, size)
		first := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0]))
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, flags, 0, first, &size)
		if errors.Is(err, windows.ERROR_BUFFER_OVERFLOW) {
			continue
		}
		if err != nil {
			return nil, err
		}
		var out []adapterInfo
		for a := first; a != nil; a = a.Next {
			if a.OperStatus != windows.IfOperStatusUp || a.IfType == ifTypeSoftwareLoopback {
				continue
			}
			info := adapterInfo{
				name:   windows.UTF16PtrToString(a.FriendlyName),
				luid:   a.Luid,
				index:  a.IfIndex,
				metric: a.Ipv4Metric,
				tunnel: a.IfType == ifTypeTunnel || a.IfType == ifTypePPP || a.IfType == ifTypeProprietaryVirt,
			}
			for u := a.FirstUnicastAddress; u != nil; u = u.Next {
				if ip, ok := ipv4Of(u.Address); ok {
					info.ipv4 = append(info.ipv4, ip)
				}
			}
			for g := a.FirstGatewayAddress; g != nil; g = g.Next {
				if ip, ok := ipv4Of(g.Address); ok && ip != "0.0.0.0" {
					info.gateway = true
				}
			}
			out = append(out, info)
		}
		runtime.KeepAlive(buf)
		return out, nil
	}
	return nil, errors.New("network adapter list changed during every read attempt")
}

// ipv4Of returns the text of an IPv4 socket address.
func ipv4Of(sa windows.SocketAddress) (string, bool) {
	if sa.Sockaddr == nil || sa.Sockaddr.Addr.Family != windows.AF_INET {
		return "", false
	}
	a := (*syscall.RawSockaddrInet4)(unsafe.Pointer(sa.Sockaddr)).Addr
	return fmt.Sprintf("%d.%d.%d.%d", a[0], a[1], a[2], a[3]), true
}

// readAdapters marks the adapter with an IPv4 gateway and the lowest IPv4
// metric as the carrier of the default route; the first one wins a tie.
func readAdapters() ([]AdapterReading, error) {
	list, err := queryAdapters()
	if err != nil {
		return nil, err
	}
	best := -1
	for i, a := range list {
		if a.gateway && (best < 0 || a.metric < list[best].metric) {
			best = i
		}
	}
	out := make([]AdapterReading, len(list))
	for i, a := range list {
		out[i] = AdapterReading{Name: a.name, IPv4: a.ipv4, DefaultRoute: i == best, Tunnel: a.tunnel}
	}
	return out, nil
}

// readNetCounters reads the 64 bit byte counters of the listed adapters by
// their identity, so the names match those of the adapter list. An adapter
// that cannot be read is skipped.
func readNetCounters() ([]NetCounterReading, error) {
	list, err := queryAdapters()
	if err != nil {
		return nil, err
	}
	var out []NetCounterReading
	for _, a := range list {
		row := windows.MibIfRow2{InterfaceLuid: a.luid}
		if a.luid == 0 {
			row.InterfaceIndex = a.index
		}
		if err := windows.GetIfEntry2Ex(windows.MibIfEntryNormal, &row); err != nil {
			continue
		}
		out = append(out, NetCounterReading{Name: a.name, RxBytes: row.InOctets, TxBytes: row.OutOctets})
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// Processes

// readProcesses reads the whole process table with one query. No handle is
// opened per process, so processes that an ordinary user cannot open are
// listed as well.
func readProcesses() ([]ProcessReading, error) {
	size := uint32(1 << 20)
	var buf []byte
	var returned uint32
	for try := 0; ; try++ {
		buf = make([]byte, size)
		err := windows.NtQuerySystemInformation(windows.SystemProcessInformation,
			unsafe.Pointer(&buf[0]), size, &returned)
		if err == nil {
			break
		}
		if err != windows.STATUS_INFO_LENGTH_MISMATCH || try >= 8 {
			return nil, err
		}
		// Processes may start between two calls, and the reported size can be 0:
		// grow to the reported size plus headroom, but at least double.
		size = max(returned+256*1024, 2*size)
	}

	var out []ProcessReading
	for off := uint32(0); off < returned; {
		p := (*windows.SYSTEM_PROCESS_INFORMATION)(unsafe.Pointer(&buf[off]))
		private := p.WorkingSetPrivateSize
		if private < 0 {
			private = 0
		}
		out = append(out, ProcessReading{
			PID:          uint32(p.UniqueProcessID),
			Name:         p.ImageName.String(),
			StartTime:    uint64(p.CreateTime),
			CPUTime:      uint64(p.UserTime) + uint64(p.KernelTime),
			PrivateBytes: uint64(private),
		})
		if p.NextEntryOffset == 0 {
			break
		}
		off += p.NextEntryOffset
	}
	runtime.KeepAlive(buf)
	return out, nil
}

// ---------------------------------------------------------------------------
// Uptime and platform

func readUptime() (time.Duration, error) {
	r, _, _ := procGetTickCount64.Call()
	if r == 0 {
		return 0, errors.New("GetTickCount64 returned 0")
	}
	return time.Duration(r) * time.Millisecond, nil
}

// readPlatform asks RtlGetVersion, which tells the real version even for a
// program that runs in a compatibility mode.
func readPlatform() (string, error) {
	v := windows.RtlGetVersion()
	if v.MajorVersion == 0 {
		return "", errors.New("version not available")
	}
	return fmt.Sprintf("windows %d.%d.%d", v.MajorVersion, v.MinorVersion, v.BuildNumber), nil
}
