//go:build !windows

package main

import (
	"errors"
	"time"
)

var errUnavailable = errors.New("not available on this platform")

// nativeSources reports every area as not measurable: the program is shipped
// for Windows and builds elsewhere only so that checks and development work.
// Nothing is ever invented here.
func nativeSources() Sources {
	return Sources{
		CPU:         func() (CPUReading, error) { return CPUReading{}, errUnavailable },
		Memory:      func() (MemoryReading, error) { return MemoryReading{}, errUnavailable },
		Swap:        func() (SwapReading, error) { return SwapReading{}, errUnavailable },
		Drives:      func() ([]DriveReading, error) { return nil, errUnavailable },
		DiskIO:      func() (DiskIOReading, error) { return DiskIOReading{}, errUnavailable },
		NetCounters: func() ([]NetCounterReading, error) { return nil, errUnavailable },
		Adapters:    func() ([]AdapterReading, error) { return nil, errUnavailable },
		Processes:   func() ([]ProcessReading, error) { return nil, errUnavailable },
		Uptime:      func() (time.Duration, error) { return 0, errUnavailable },
		Platform:    func() (string, error) { return "", errUnavailable },
	}
}
