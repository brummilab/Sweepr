//go:build !windows

package main

import (
	"errors"
	"runtime"
)

// The status binary ships for Windows only. These stubs let the
// platform-neutral rendering, health, and collector logic build and run its
// tests on the macOS and Linux machines developers use.

var errUnsupportedPlatform = errors.New("status metrics are only collected on Windows")

func platformName() string                            { return runtime.GOOS }
func readUptime() uint64                              { return 0 }
func systemDriveMount() string                        { return normalizeDriveMount("C:") }
func readCPU() (CPUStatus, error)                     { return CPUStatus{}, errUnsupportedPlatform }
func readMemory() (MemoryStatus, error)               { return MemoryStatus{}, errUnsupportedPlatform }
func readDisks(map[string]bool) ([]DiskStatus, error) { return nil, errUnsupportedPlatform }
func readExternalDriveSet() (map[string]bool, error)  { return nil, errUnsupportedPlatform }
func readDiskIO() (uint64, uint64, error)             { return 0, 0, errUnsupportedPlatform }
func readNetCounters() (map[string]netCounter, error) { return nil, errUnsupportedPlatform }
func readNetAdapters() ([]netAdapter, error)          { return nil, errUnsupportedPlatform }
func readSystemProxy() ProxyStatus                    { return ProxyStatus{} }
func readProcesses() ([]procSample, error)            { return nil, errUnsupportedPlatform }
func readBatteries() ([]BatteryStatus, error)         { return nil, errUnsupportedPlatform }
func readHardware() HardwareInfo                      { return HardwareInfo{} }
