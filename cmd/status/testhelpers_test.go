package main

import (
	"testing"
	"time"
)

// stubPlatformForTest replaces every platform reader with a deterministic
// fixture, so collector tests run the same on Windows CI and a developer Mac
// and never read the real machine.
func stubPlatformForTest() {
	readCPUFunc = func() (CPUStatus, error) {
		return CPUStatus{Usage: 12, PerCore: []float64{20, 4}, CoreCount: 2, LogicalCPU: 2}, nil
	}
	readMemoryFunc = func() (MemoryStatus, error) {
		return MemoryStatus{Used: 4 << 30, Total: 16 << 30, Available: 12 << 30, UsedPercent: 25}, nil
	}
	readDisksFunc = func(map[string]bool) ([]DiskStatus, error) {
		return []DiskStatus{{Mount: `C:\`, Device: "C:", Total: 100 << 30, Used: 40 << 30, UsedPercent: 40}}, nil
	}
	readExternalDrives = func() (map[string]bool, error) { return map[string]bool{}, nil }
	readDiskIOFunc = func() (uint64, uint64, error) { return 0, 0, nil }
	readNetCountersFn = func() (map[string]netCounter, error) {
		return map[string]netCounter{"Ethernet": {}}, nil
	}
	readNetAdaptersFn = func() ([]netAdapter, error) {
		return []netAdapter{{Name: "Ethernet", IP: "10.0.0.2", IsDefault: true}}, nil
	}
	readProcessesFunc = func() ([]procSample, error) {
		return []procSample{{PID: 42, Image: "app.exe", CPUTime: 0, MemoryBytes: 1 << 20}}, nil
	}
	readBatteriesFunc = func() ([]BatteryStatus, error) { return nil, nil }
	readHardwareFunc = func() HardwareInfo { return HardwareInfo{Model: "Test PC", CPUModel: "Test CPU"} }
	readSystemProxyFn = func() ProxyStatus { return ProxyStatus{} }
	readUptimeFunc = func() uint64 { return 3600 }
	sleepFunc = func(time.Duration) {}
}

// stubPlatform stubs every reader for one in-process test and restores the
// real ones afterwards.
func stubPlatform(t *testing.T) {
	t.Helper()
	cpuFn, memFn, disksFn, extFn, ioFn := readCPUFunc, readMemoryFunc, readDisksFunc, readExternalDrives, readDiskIOFunc
	netFn, adaptFn, procFn, battFn, hwFn := readNetCountersFn, readNetAdaptersFn, readProcessesFunc, readBatteriesFunc, readHardwareFunc
	proxyFn, uptimeFn, sleepFn := readSystemProxyFn, readUptimeFunc, sleepFunc
	t.Cleanup(func() {
		readCPUFunc, readMemoryFunc, readDisksFunc, readExternalDrives, readDiskIOFunc = cpuFn, memFn, disksFn, extFn, ioFn
		readNetCountersFn, readNetAdaptersFn, readProcessesFunc, readBatteriesFunc, readHardwareFunc = netFn, adaptFn, procFn, battFn, hwFn
		readSystemProxyFn, readUptimeFunc, sleepFunc = proxyFn, uptimeFn, sleepFn
	})
	stubPlatformForTest()
}

// the other SMART states. Windows never reports SMART, so production only
// needs smartStatusFailing; the ported view tests still pin how each renders.
const (
	smartStatusVerified    = "verified"
	smartStatusUnsupported = "unsupported"
	smartStatusUnknown     = "unknown"
)
