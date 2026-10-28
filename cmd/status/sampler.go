package main

import (
	"errors"
	"net/netip"
	"sort"
	"strings"
	"time"
)

const (
	// minWindow is the shortest time between two counter readings. Rates over
	// a shorter window are dominated by the coarse resolution of the system
	// timers.
	minWindow = 250 * time.Millisecond

	bytesPerMB = 1 << 20

	// cpuTimeUnits is the number of 100 ns units per second.
	cpuTimeUnits = 1e7

	maxTopProcesses    = 5
	maxNetworkAdapters = 3
)

// Snapshot is one measurement and the JSON document of the output schema. A
// nil pointer or slice is an area that could not be measured and marshals to
// null; a measured but empty list is an empty array.
type Snapshot struct {
	CollectedAt   string                `json:"collected_at"`
	Platform      *string               `json:"platform"`
	UptimeSeconds *int64                `json:"uptime_seconds"`
	Procs         *int                  `json:"procs"`
	CPU           *CPUSnapshot          `json:"cpu"`
	Memory        *MemorySnapshot       `json:"memory"`
	Disks         []DiskSnapshot        `json:"disks"`
	DiskIO        *DiskIOSnapshot       `json:"disk_io"`
	Network       []NetworkSnapshot     `json:"network"`
	NetworkTotal  *NetworkTotalSnapshot `json:"network_total"`
	TopProcesses  []ProcessSnapshot     `json:"top_processes"`

	// defaultIPv4 is shown on the screen only and never leaves the program
	// through the JSON output.
	defaultIPv4 string
}

type CPUSnapshot struct {
	Usage      float64   `json:"usage"`
	PerCore    []float64 `json:"per_core"`
	CoreCount  *int      `json:"core_count"`
	LogicalCPU int       `json:"logical_cpu"`
}

type MemorySnapshot struct {
	Used        uint64  `json:"used"`
	Total       uint64  `json:"total"`
	Available   uint64  `json:"available"`
	UsedPercent float64 `json:"used_percent"`
	SwapUsed    *uint64 `json:"swap_used"`
	SwapTotal   *uint64 `json:"swap_total"`
}

type DiskSnapshot struct {
	Mount       string  `json:"mount"`
	FSType      *string `json:"fstype"`
	Used        uint64  `json:"used"`
	Total       uint64  `json:"total"`
	UsedPercent float64 `json:"used_percent"`
	External    bool    `json:"external"`
}

type DiskIOSnapshot struct {
	ReadRate  float64 `json:"read_rate"`
	WriteRate float64 `json:"write_rate"`
}

type NetworkSnapshot struct {
	Name      string  `json:"name"`
	RxRateMBs float64 `json:"rx_rate_mbs"`
	TxRateMBs float64 `json:"tx_rate_mbs"`
}

type NetworkTotalSnapshot struct {
	RxRateMBs float64 `json:"rx_rate_mbs"`
	TxRateMBs float64 `json:"tx_rate_mbs"`
}

type ProcessSnapshot struct {
	PID         uint32  `json:"pid"`
	Name        string  `json:"name"`
	CPU         float64 `json:"cpu"`
	MemoryBytes uint64  `json:"memory_bytes"`
}

var errNothingMeasurable = errors.New("no area could be measured")

// counters is the part of a measurement that needs a predecessor to become a
// rate. A nil or false member means the source failed.
type counters struct {
	cpu     *CPUReading
	diskIO  *DiskIOReading
	net     map[string]NetCounterReading
	procs   []ProcessReading
	procsOK bool
}

type processKey struct {
	pid   uint32
	start uint64
}

// Sampler turns the raw readings of its sources into snapshots. The first
// counter reading happens when the sampler is created; every Sample call
// computes rates against the reading before it. A Sampler is not safe for
// concurrent use.
type Sampler struct {
	src      Sources
	clk      Clock
	sysDrive string

	prev   counters
	prevAt time.Time
}

// NewSampler takes the first counter reading.
func NewSampler(src Sources, clk Clock) *Sampler {
	s := &Sampler{src: src, clk: clk, sysDrive: `C:\`}
	s.prevAt = clk.Now()
	s.prev = s.readCounters()
	return s
}

// SetSystemDrive names the drive that is listed first, for example "C:". An
// unusable value selects "C:".
func (s *Sampler) SetSystemDrive(drive string) {
	drive = strings.TrimSpace(drive)
	if len(drive) >= 2 && drive[1] == ':' {
		c := drive[0]
		if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		if c >= 'A' && c <= 'Z' {
			s.sysDrive = string(c) + `:\`
			return
		}
	}
	s.sysDrive = `C:\`
}

func (s *Sampler) readCounters() counters {
	var c counters
	if r, err := s.src.CPU(); err == nil {
		r.PerCPU = append([]CPUTimes(nil), r.PerCPU...)
		c.cpu = &r
	}
	if r, err := s.src.DiskIO(); err == nil {
		c.diskIO = &r
	}
	if list, err := s.src.NetCounters(); err == nil {
		c.net = make(map[string]NetCounterReading, len(list))
		for _, n := range list {
			if _, dup := c.net[n.Name]; !dup {
				c.net[n.Name] = n
			}
		}
	}
	if list, err := s.src.Processes(); err == nil {
		c.procs, c.procsOK = list, true
	}
	return c
}

// Sample waits, if needed, until the minimum window since the previous
// counter reading has passed, reads every source once and returns the
// snapshot. The snapshot is always complete in shape. The error is non-nil
// only when no area could be measured at all.
func (s *Sampler) Sample() (Snapshot, error) {
	if wait := minWindow - s.clk.Now().Sub(s.prevAt); wait > 0 {
		s.clk.Sleep(wait)
	}
	at := s.clk.Now()
	window := at.Sub(s.prevAt)
	cur := s.readCounters()

	snap := Snapshot{CollectedAt: at.Format(time.RFC3339)}
	secs := window.Seconds()
	haveWindow := secs > 0

	if p, err := s.src.Platform(); err == nil {
		snap.Platform = &p
	}
	if d, err := s.src.Uptime(); err == nil && d >= 0 {
		sec := int64(d / time.Second)
		snap.UptimeSeconds = &sec
	}

	if cur.cpu != nil && s.prev.cpu != nil && haveWindow {
		snap.CPU = cpuSnapshot(s.prev.cpu.PerCPU, *cur.cpu)
	}

	snap.Memory = s.memory()
	snap.Disks = s.drives()

	if cur.diskIO != nil && s.prev.diskIO != nil && haveWindow {
		snap.DiskIO = &DiskIOSnapshot{
			ReadRate:  rate(s.prev.diskIO.ReadBytes, cur.diskIO.ReadBytes, secs),
			WriteRate: rate(s.prev.diskIO.WriteBytes, cur.diskIO.WriteBytes, secs),
		}
	}

	if adapters, err := s.src.Adapters(); err == nil && cur.net != nil && s.prev.net != nil && haveWindow {
		snap.Network, snap.NetworkTotal, snap.defaultIPv4 = networkSnapshot(adapters, s.prev.net, cur.net, secs)
	} else if err == nil {
		snap.defaultIPv4 = defaultAddress(adapters)
	}

	if cur.procsOK {
		n := 0
		for _, p := range cur.procs {
			if p.PID != 0 {
				n++
			}
		}
		snap.Procs = &n
		// The load of a process is relative to the machine, so the ranking
		// needs the processor count of the CPU source.
		if cur.cpu != nil && len(cur.cpu.PerCPU) > 0 && s.prev.procsOK && haveWindow {
			snap.TopProcesses = topProcesses(s.prev.procs, cur.procs, secs, len(cur.cpu.PerCPU))
		}
	}

	s.prev, s.prevAt = cur, at

	if snap.measuredNothing() {
		return snap, errNothingMeasurable
	}
	return snap, nil
}

func (s Snapshot) measuredNothing() bool {
	return s.Platform == nil && s.UptimeSeconds == nil && s.Procs == nil && s.CPU == nil &&
		s.Memory == nil && s.Disks == nil && s.DiskIO == nil && s.Network == nil &&
		s.NetworkTotal == nil && s.TopProcesses == nil
}

// rate converts the growth of a cumulative byte counter into MB/s. A counter
// that shrank (overflow, restarted adapter) saw no traffic in this window.
func rate(prev, cur uint64, secs float64) float64 {
	if cur < prev {
		return 0
	}
	return float64(cur-prev) / bytesPerMB / secs
}

// cpuSnapshot returns nil when the processors cannot be compared: a different
// count, a time that stood still or went backwards.
func cpuSnapshot(prev []CPUTimes, cur CPUReading) *CPUSnapshot {
	n := len(cur.PerCPU)
	if n == 0 || len(prev) != n {
		return nil
	}
	per := make([]float64, n)
	sum := 0.0
	for i, c := range cur.PerCPU {
		p := prev[i]
		if c.Total <= p.Total || c.Idle < p.Idle {
			return nil
		}
		total := c.Total - p.Total
		idle := c.Idle - p.Idle
		var pct float64
		if idle < total {
			pct = 100 * float64(total-idle) / float64(total)
		}
		per[i] = pct
		sum += pct
	}
	out := &CPUSnapshot{Usage: sum / float64(n), PerCore: per, LogicalCPU: n}
	if cur.PhysicalCores > 0 {
		cores := cur.PhysicalCores
		out.CoreCount = &cores
	}
	return out
}

func (s *Sampler) memory() *MemorySnapshot {
	m, err := s.src.Memory()
	if err != nil || m.Total == 0 {
		return nil
	}
	var used uint64
	if m.Available < m.Total {
		used = m.Total - m.Available
	}
	out := &MemorySnapshot{
		Used:        used,
		Total:       m.Total,
		Available:   m.Available,
		UsedPercent: 100 * float64(used) / float64(m.Total),
	}
	if sw, err := s.src.Swap(); err == nil {
		used, total := sw.Used, sw.Total
		out.SwapUsed, out.SwapTotal = &used, &total
	}
	return out
}

func (s *Sampler) drives() []DiskSnapshot {
	list, err := s.src.Drives()
	if err != nil {
		return nil
	}
	var out []DiskSnapshot
	for _, d := range list {
		if d.Total == 0 {
			continue
		}
		var used uint64
		if d.Free < d.Total {
			used = d.Total - d.Free
		}
		ds := DiskSnapshot{
			Mount:       strings.ToUpper(d.Name),
			Used:        used,
			Total:       d.Total,
			UsedPercent: 100 * float64(used) / float64(d.Total),
			External:    d.Removable,
		}
		if d.FSType != "" {
			fs := d.FSType
			ds.FSType = &fs
		}
		out = append(out, ds)
	}
	sort.SliceStable(out, func(i, j int) bool {
		si, sj := out[i].Mount == s.sysDrive, out[j].Mount == s.sysDrive
		if si != sj {
			return si
		}
		return out[i].Mount < out[j].Mount
	})
	return out
}

type adapterRate struct {
	name     string
	rx, tx   float64
	tunnel   bool
	fallback bool // an adapter that carries the default route through a tunnel
}

// networkSnapshot lists the adapters and sums their traffic. An adapter that
// has no counter in the previous reading has no window yet and appears with the
// next sample. A tunnel on the default route counts alone, because its
// counters and those of the carrier adapter describe the same traffic.
func networkSnapshot(adapters []AdapterReading, prev, cur map[string]NetCounterReading, secs float64) ([]NetworkSnapshot, *NetworkTotalSnapshot, string) {
	ip := defaultAddress(adapters)

	var counted []AdapterReading
	tunnelOnDefault := false
	for _, a := range adapters {
		if a.Tunnel && !a.DefaultRoute {
			continue
		}
		counted = append(counted, a)
		if a.Tunnel && a.DefaultRoute {
			tunnelOnDefault = true
		}
	}
	if len(counted) == 0 {
		return []NetworkSnapshot{}, &NetworkTotalSnapshot{}, ip
	}

	var rates []adapterRate
	seen := map[string]bool{}
	for _, a := range counted {
		if seen[a.Name] {
			continue
		}
		seen[a.Name] = true
		p, okPrev := prev[a.Name]
		c, okCur := cur[a.Name]
		if !okPrev || !okCur {
			continue
		}
		rates = append(rates, adapterRate{
			name:     a.Name,
			rx:       rate(p.RxBytes, c.RxBytes, secs),
			tx:       rate(p.TxBytes, c.TxBytes, secs),
			tunnel:   a.Tunnel,
			fallback: a.Tunnel && a.DefaultRoute,
		})
	}
	if len(rates) == 0 {
		return nil, nil, ip
	}

	total := &NetworkTotalSnapshot{}
	counts := 0
	for _, r := range rates {
		if tunnelOnDefault && !r.fallback {
			continue
		}
		total.RxRateMBs += r.rx
		total.TxRateMBs += r.tx
		counts++
	}
	if counts == 0 {
		// The tunnel on the default route has no window yet.
		return nil, nil, ip
	}

	sort.SliceStable(rates, func(i, j int) bool {
		a, b := rates[i], rates[j]
		if a.fallback != b.fallback {
			return a.fallback
		}
		if sa, sb := a.rx+a.tx, b.rx+b.tx; sa != sb {
			return sa > sb
		}
		return a.name < b.name
	})
	if len(rates) > maxNetworkAdapters {
		rates = rates[:maxNetworkAdapters]
	}
	list := make([]NetworkSnapshot, len(rates))
	for i, r := range rates {
		list[i] = NetworkSnapshot{Name: r.name, RxRateMBs: r.rx, TxRateMBs: r.tx}
	}
	return list, total, ip
}

// defaultAddress returns the first IPv4 address of the default-route adapter
// that is neither loopback nor link-local, or "" when there is none.
func defaultAddress(adapters []AdapterReading) string {
	for _, a := range adapters {
		if !a.DefaultRoute {
			continue
		}
		for _, text := range a.IPv4 {
			addr, err := netip.ParseAddr(text)
			if err != nil || !addr.Is4() || addr.IsLoopback() || addr.IsLinkLocalUnicast() || addr.IsUnspecified() {
				continue
			}
			return addr.String()
		}
		return ""
	}
	return ""
}

// topProcesses ranks the processes that have a window, which means they were
// in the previous reading with the same PID and start time. The load is in
// percent of the whole machine, like the total CPU usage.
func topProcesses(prev, cur []ProcessReading, secs float64, logical int) []ProcessSnapshot {
	before := make(map[processKey]ProcessReading, len(prev))
	for _, p := range prev {
		before[processKey{p.PID, p.StartTime}] = p
	}
	capacity := secs * cpuTimeUnits * float64(logical)
	out := []ProcessSnapshot{}
	for _, p := range cur {
		if p.PID == 0 {
			continue
		}
		old, ok := before[processKey{p.PID, p.StartTime}]
		if !ok {
			continue
		}
		var pct float64
		if p.CPUTime > old.CPUTime {
			pct = 100 * float64(p.CPUTime-old.CPUTime) / capacity
			if pct > 100 {
				pct = 100
			}
		}
		out = append(out, ProcessSnapshot{
			PID:         p.PID,
			Name:        processName(p),
			CPU:         pct,
			MemoryBytes: p.PrivateBytes,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.CPU != b.CPU {
			return a.CPU > b.CPU
		}
		if a.MemoryBytes != b.MemoryBytes {
			return a.MemoryBytes > b.MemoryBytes
		}
		return a.PID < b.PID
	})
	if len(out) > maxTopProcesses {
		out = out[:maxTopProcesses]
	}
	return out
}

// processName is the program file name without directory and without the
// .exe extension. The system process has no image name.
func processName(p ProcessReading) string {
	name := p.Name
	if i := strings.LastIndexAny(name, `\/`); i >= 0 {
		name = name[i+1:]
	}
	if len(name) > 4 && strings.EqualFold(name[len(name)-4:], ".exe") {
		name = name[:len(name)-4]
	}
	if name == "" && p.PID == 4 {
		return "System"
	}
	return name
}
