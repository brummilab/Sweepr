package main

import "time"

// The sources are the only place where the program touches the operating
// system. Each one returns raw, cumulative counters or current totals and
// never a finished rate, so every calculation lives in the platform-neutral
// sampler and can be tested with artificial readings. Every source can fail on
// its own; a failure makes the matching part of the snapshot unknown and
// leaves the other parts alone.

// CPUTimes holds the cumulative idle and total (kernel plus user) time of one
// logical processor in 100 ns units.
type CPUTimes struct {
	Idle  uint64
	Total uint64
}

// CPUReading lists the processors in the order of the system.
type CPUReading struct {
	PerCPU []CPUTimes
	// PhysicalCores is 0 when the system does not report it.
	PhysicalCores int
}

// MemoryReading is the physical memory in bytes.
type MemoryReading struct {
	Total     uint64
	Available uint64
}

// SwapReading sums all page files in bytes.
type SwapReading struct {
	Used  uint64
	Total uint64
}

// DriveReading describes one local drive. Name has the form "C:\".
type DriveReading struct {
	Name      string
	Total     uint64
	Free      uint64
	FSType    string
	Removable bool
}

// DiskIOReading holds cumulative bytes over all fixed drives.
type DiskIOReading struct {
	ReadBytes  uint64
	WriteBytes uint64
}

// NetCounterReading holds the cumulative bytes of one adapter.
type NetCounterReading struct {
	Name    string
	RxBytes uint64
	TxBytes uint64
}

// AdapterReading describes one network adapter that is in service and not a
// loopback adapter. The source decides which adapter carries the default
// route; the sampler decides what tunnels count.
type AdapterReading struct {
	Name         string
	IPv4         []string
	DefaultRoute bool
	Tunnel       bool
}

// ProcessReading is one row of the process table. StartTime together with PID
// identifies a process; CPUTime is cumulative user plus kernel time in 100 ns
// units.
type ProcessReading struct {
	PID          uint32
	Name         string
	StartTime    uint64
	CPUTime      uint64
	PrivateBytes uint64
}

// Sources bundles one replaceable reader per category.
type Sources struct {
	CPU         func() (CPUReading, error)
	Memory      func() (MemoryReading, error)
	Swap        func() (SwapReading, error)
	Drives      func() ([]DriveReading, error)
	DiskIO      func() (DiskIOReading, error)
	NetCounters func() ([]NetCounterReading, error)
	Adapters    func() ([]AdapterReading, error)
	Processes   func() ([]ProcessReading, error)
	Uptime      func() (time.Duration, error)
	Platform    func() (string, error)
}

// Clock is the time source of the sampler and the display. Tests replace it so
// that waiting costs no real time.
type Clock interface {
	Now() time.Time
	Sleep(d time.Duration)
}

type systemClock struct{}

func (systemClock) Now() time.Time        { return time.Now() }
func (systemClock) Sleep(d time.Duration) { time.Sleep(d) }
