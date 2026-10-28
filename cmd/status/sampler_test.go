package main

// Calculation rules of the sampler (ST-5 to ST-14), tested with artificial
// cumulative counters and an artificial clock.

import (
	"testing"
	"time"
)

// tstSampleAfter creates a sampler on the current counters, lets window pass,
// applies change (the counters at the second reading) and samples once.
func tstSampleAfter(t *testing.T, w *fakeWorld, clk *fakeClock, window time.Duration, change func()) (map[string]any, error) {
	t.Helper()
	s := tstNewSampler(w, clk)
	clk.Advance(window)
	if change != nil {
		w.set(change)
	}
	snap, err := s.Sample()
	return tstSnapshotDoc(t, snap), err
}

func tstMustSample(t *testing.T, w *fakeWorld, clk *fakeClock, window time.Duration, change func()) map[string]any {
	t.Helper()
	doc, err := tstSampleAfter(t, w, clk, window, change)
	if err != nil {
		t.Fatalf("Sample returned an error although every source works: %v", err)
	}
	return doc
}

// four processors; usage of the second reading is set through the deltas.
func tstFourCPUWorld(clk *fakeClock) *fakeWorld {
	w := newManualWorld(clk)
	w.cpu = []fakeCPU{{100, 200}, {100, 200}, {100, 200}, {100, 200}}
	w.physical = 2
	w.procs = nil
	return w
}

func tstBumpCPUs(w *fakeWorld, idle, total uint64) {
	for i := range w.cpu {
		w.cpu[i].Idle += idle
		w.cpu[i].Total += total
	}
}

// ---------------------------------------------------------------------------
// ST-7: measurement window

func TestSamplerWaitsUntilTheMinimumWindowHasPassed(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	s := tstNewSampler(w, clk)
	clk.Advance(100 * time.Millisecond)
	if _, err := s.Sample(); err != nil {
		t.Fatal(err)
	}
	reads := w.readTimes("cpu")
	if len(reads) < 2 {
		t.Fatalf("CPU source read %d times, want a reading at creation and one per sample", len(reads))
	}
	gap := reads[len(reads)-1].Sub(reads[0])
	if gap < 250*time.Millisecond {
		t.Errorf("window between the two readings is %v, want at least 250ms", gap)
	}
	if gap > 260*time.Millisecond {
		t.Errorf("window between the two readings is %v, the sampler waited longer than needed", gap)
	}
	if slept := clk.totalSlept(); slept < 150*time.Millisecond || slept > 160*time.Millisecond {
		t.Errorf("slept %v through the clock, want about 150ms", slept)
	}
}

func TestSamplerDoesNotWaitWhenTheWindowHasAlreadyPassed(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	tstMustSample(t, w, clk, 2*time.Second, nil)
	if slept := clk.totalSlept(); slept != 0 {
		t.Errorf("slept %v although 2s had passed", slept)
	}
}

func TestSamplerMeasuresTheWindowFromThePreviousReading(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	s := tstNewSampler(w, clk)
	clk.Advance(2 * time.Second)
	if _, err := s.Sample(); err != nil {
		t.Fatal(err)
	}
	before := clk.totalSlept()
	clk.Advance(100 * time.Millisecond)
	if _, err := s.Sample(); err != nil {
		t.Fatal(err)
	}
	reads := w.readTimes("cpu")
	if len(reads) < 3 {
		t.Fatalf("CPU source read %d times, want at least 3", len(reads))
	}
	if gap := reads[len(reads)-1].Sub(reads[len(reads)-2]); gap < 250*time.Millisecond {
		t.Errorf("window of the second sample is %v, want at least 250ms", gap)
	}
	if extra := clk.totalSlept() - before; extra < 150*time.Millisecond || extra > 160*time.Millisecond {
		t.Errorf("second sample slept %v, want about 150ms", extra)
	}
}

func TestSamplerRatesUseTheMeasuredTimeNotTheNominalOne(t *testing.T) {
	for _, window := range []time.Duration{100 * time.Millisecond, 250 * time.Millisecond, 3 * time.Second} {
		clk := newFakeClock()
		w := newManualWorld(clk)
		start := clk.Now()
		// Counters follow the artificial time: 10 MiB/s read, 5 MiB/s write.
		w.onRead = func(w *fakeWorld, src string, n int) {
			if src != "diskio" {
				return
			}
			el := w.clk.Now().Sub(start).Seconds()
			w.diskRead = uint64(10 * tstMiB * el)
			w.diskWrite = uint64(5 * tstMiB * el)
		}
		doc := tstMustSample(t, w, clk, window, nil)
		tstWantNum(t, doc, 10, "disk_io", "read_rate")
		tstWantNum(t, doc, 5, "disk_io", "write_rate")
	}
}

// ---------------------------------------------------------------------------
// ST-5, ST-6: unknown instead of invented values

func TestSamplerFillsEveryAreaWhenEverySourceWorks(t *testing.T) {
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	doc := tstMustSample(t, w, clk, time.Second, nil)
	for _, k := range tstTopLevelKeys {
		tstWantNotNull(t, doc, k)
	}
}

func TestSamplerReportsCollectionTimeFromTheClock(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	doc := tstMustSample(t, w, clk, time.Second, nil)
	v, _ := tstAt(doc, "collected_at")
	s, _ := v.(string)
	got, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatalf("collected_at %q is not RFC 3339: %v", s, err)
	}
	if !got.Equal(clk.Now()) {
		t.Errorf("collected_at = %v, want the clock time %v", got, clk.Now())
	}
	if _, off := got.Zone(); off != 2*3600 {
		t.Errorf("collected_at %q lost the zone offset of the clock (+02:00)", s)
	}
}

func TestSamplerSourcesFailIndependently(t *testing.T) {
	cases := []struct {
		name  string
		fail  func(w *fakeWorld)
		nulls [][]string
		skip  []string // areas that may legitimately be affected
	}{
		// Process load is relative to the processor count, which the CPU
		// source reports; the process list may fall back to null with it.
		{"cpu", func(w *fakeWorld) { w.cpuErr = errFakeUnavailable }, [][]string{{"cpu"}}, []string{"top_processes"}},
		{"memory", func(w *fakeWorld) { w.memErr = errFakeUnavailable }, [][]string{{"memory"}}, nil},
		{"swap", func(w *fakeWorld) { w.swapErr = errFakeUnavailable }, [][]string{{"memory", "swap_used"}, {"memory", "swap_total"}}, nil},
		{"drives", func(w *fakeWorld) { w.drivesErr = errFakeUnavailable }, [][]string{{"disks"}}, nil},
		{"disk counters", func(w *fakeWorld) { w.diskErr = errFakeUnavailable }, [][]string{{"disk_io"}}, nil},
		{"network counters", func(w *fakeWorld) { w.netErr = errFakeUnavailable }, [][]string{{"network"}, {"network_total"}}, nil},
		{"adapters", func(w *fakeWorld) { w.adaptersErr = errFakeUnavailable }, [][]string{{"network"}, {"network_total"}}, nil},
		{"processes", func(w *fakeWorld) { w.procsErr = errFakeUnavailable }, [][]string{{"procs"}, {"top_processes"}}, nil},
		{"uptime", func(w *fakeWorld) { w.uptimeErr = errFakeUnavailable }, [][]string{{"uptime_seconds"}}, nil},
		{"platform", func(w *fakeWorld) { w.platformErr = errFakeUnavailable }, [][]string{{"platform"}}, nil},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			clk := newFakeClock()
			w := newHealthyWorld(clk)
			c.fail(w)
			doc, _ := tstSampleAfter(t, w, clk, time.Second, nil)
			isNull := map[string]bool{}
			for _, path := range c.nulls {
				tstWantNull(t, doc, path...)
				isNull[path[0]] = len(path) == 1
			}
			for _, k := range tstTopLevelKeys {
				if isNull[k] || containsString(c.skip, k) {
					continue
				}
				tstWantNotNull(t, doc, k)
			}
			if c.name == "swap" {
				tstWantNotNull(t, doc, "memory", "used")
				tstWantNotNull(t, doc, "memory", "total")
			}
		})
	}
}

func TestSamplerKeepsEveryKeyWhenNothingIsMeasurable(t *testing.T) {
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	w.failAll()
	doc, _ := tstSampleAfter(t, w, clk, time.Second, nil)
	tstWantNotNull(t, doc, "collected_at")
	for _, k := range tstTopLevelKeys[1:] {
		tstWantNull(t, doc, k)
	}
}

func TestSamplerRateWithoutPredecessorIsUnknown(t *testing.T) {
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	w.cpuErr, w.diskErr, w.netErr, w.procsErr = errFakeUnavailable, errFakeUnavailable, errFakeUnavailable, errFakeUnavailable
	s := tstNewSampler(w, clk) // the counters are unreadable at creation
	w.set(func() { w.cpuErr, w.diskErr, w.netErr, w.procsErr = nil, nil, nil, nil })
	clk.Advance(time.Second)
	snap, _ := s.Sample()
	doc := tstSnapshotDoc(t, snap)
	tstWantNull(t, doc, "cpu")
	tstWantNull(t, doc, "disk_io")
	tstWantNull(t, doc, "network_total")
	if v, _ := tstAt(doc, "top_processes"); v != nil {
		if a, ok := v.([]any); !ok || len(a) != 0 {
			t.Errorf("top_processes = %v, want null or empty without a previous reading", v)
		}
	}
	// The next sample has a predecessor again.
	clk.Advance(time.Second)
	snap, _ = s.Sample()
	doc = tstSnapshotDoc(t, snap)
	tstWantNotNull(t, doc, "cpu")
	tstWantNotNull(t, doc, "disk_io")
	tstWantNotNull(t, doc, "network_total")
}

// ---------------------------------------------------------------------------
// ST-8: CPU

func TestSamplerCPUUsageIsTheMeanOfThePerProcessorUsage(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.cpu = []fakeCPU{{5_000_000, 8_000_000}, {5_000_000, 8_000_000}}
	w.physical = 2
	doc := tstMustSample(t, w, clk, time.Second, func() {
		w.cpu[0].Idle += 4_000_000 // 40 % idle
		w.cpu[0].Total += 10_000_000
		w.cpu[1].Idle += 9_000_000 // 90 % idle
		w.cpu[1].Total += 10_000_000
	})
	per := tstArr(t, doc, "cpu", "per_core")
	if len(per) != 2 {
		t.Fatalf("per_core has %d values, want 2", len(per))
	}
	if f, _ := per[0].(float64); f < 59.999 || f > 60.001 {
		t.Errorf("per_core[0] = %v, want 60", per[0])
	}
	if f, _ := per[1].(float64); f < 9.999 || f > 10.001 {
		t.Errorf("per_core[1] = %v, want 10", per[1])
	}
	tstWantNum(t, doc, 35, "cpu", "usage")
	tstWantNum(t, doc, 2, "cpu", "logical_cpu")
	tstWantNum(t, doc, 2, "cpu", "core_count")
}

func TestSamplerCPUUnknownPhysicalCoreCountIsNull(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.physical = 0
	doc := tstMustSample(t, w, clk, time.Second, func() { tstBumpCPUs(w, 5, 10) })
	tstWantNull(t, doc, "cpu", "core_count")
	tstWantNum(t, doc, 2, "cpu", "logical_cpu")
	tstWantNotNull(t, doc, "cpu", "usage")
}

func TestSamplerCPUListsProcessorsInTheirOwnOrder(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.cpu = []fakeCPU{{}, {}, {}}
	doc := tstMustSample(t, w, clk, time.Second, func() {
		w.cpu[0].Idle, w.cpu[0].Total = 1_000_000, 10_000_000 // 90 %
		w.cpu[1].Idle, w.cpu[1].Total = 9_000_000, 10_000_000 // 10 %
		w.cpu[2].Idle, w.cpu[2].Total = 5_000_000, 10_000_000 // 50 %
	})
	per := tstArr(t, doc, "cpu", "per_core")
	want := []float64{90, 10, 50}
	if len(per) != len(want) {
		t.Fatalf("per_core = %v, want %v", per, want)
	}
	for i, wv := range want {
		if f, _ := per[i].(float64); f < wv-0.001 || f > wv+0.001 {
			t.Errorf("per_core[%d] = %v, want %v", i, per[i], wv)
		}
	}
	tstWantNum(t, doc, 3, "cpu", "logical_cpu")
}

func TestSamplerCPUFullyIdleIsAMeasuredZero(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	doc := tstMustSample(t, w, clk, time.Second, func() { tstBumpCPUs(w, 10_000_000, 10_000_000) })
	tstWantNum(t, doc, 0, "cpu", "usage")
	tstWantNotNull(t, doc, "cpu", "per_core")
	for i, v := range tstArr(t, doc, "cpu", "per_core") {
		if f, ok := v.(float64); !ok || f != 0 {
			t.Errorf("per_core[%d] = %v, want 0", i, v)
		}
	}
}

func TestSamplerCPUUsageStaysWithinZeroToHundred(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	doc := tstMustSample(t, w, clk, time.Second, func() { tstBumpCPUs(w, 0, 10_000_000) })
	tstWantNum(t, doc, 100, "cpu", "usage")
	for i, v := range tstArr(t, doc, "cpu", "per_core") {
		if f, ok := v.(float64); !ok || f < 0 || f > 100 {
			t.Errorf("per_core[%d] = %v, want a value in 0..100", i, v)
		}
	}
}

func TestSamplerCPUUnavailableWhenTotalTimeDoesNotAdvance(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	doc := tstMustSample(t, w, clk, time.Second, func() {
		w.cpu[0].Idle += 5
		w.cpu[0].Total += 10
		// processor 1 did not advance at all
	})
	tstWantNull(t, doc, "cpu")
	tstWantNotNull(t, doc, "memory")
}

func TestSamplerCPUUnavailableWhenATimeDecreases(t *testing.T) {
	cases := map[string]func(w *fakeWorld){
		"total time decreases": func(w *fakeWorld) { w.cpu[1].Total -= 50 },
		"idle time decreases":  func(w *fakeWorld) { w.cpu[1].Idle -= 50 },
	}
	for name, change := range cases {
		change := change
		t.Run(name, func(t *testing.T) {
			clk := newFakeClock()
			w := newManualWorld(clk)
			w.cpu = []fakeCPU{{1000, 2000}, {1000, 2000}}
			doc := tstMustSample(t, w, clk, time.Second, func() {
				w.cpu[0].Idle += 5
				w.cpu[0].Total += 10
				w.cpu[1].Idle += 5
				w.cpu[1].Total += 10
				change(w)
			})
			tstWantNull(t, doc, "cpu")
		})
	}
}

func TestSamplerCPUWithoutPerProcessorValuesIsUnavailable(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.cpu = nil // the source reports no processors
	doc, _ := tstSampleAfter(t, w, clk, time.Second, nil)
	tstWantNull(t, doc, "cpu")
}

// ---------------------------------------------------------------------------
// ST-9: memory

func TestSamplerMemoryUsedIsTotalMinusAvailable(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	doc := tstMustSample(t, w, clk, time.Second, nil)
	tstWantNum(t, doc, 16*tstGiB, "memory", "total")
	tstWantNum(t, doc, 12*tstGiB, "memory", "available")
	tstWantNum(t, doc, 4294967296, "memory", "used")
	tstWantNum(t, doc, 25, "memory", "used_percent")
	tstWantNum(t, doc, tstGiB, "memory", "swap_used")
	tstWantNum(t, doc, 4*tstGiB, "memory", "swap_total")
}

func TestSamplerMemoryWithoutPageFileHasZeroSwap(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.swapUsed, w.swapTotal = 0, 0
	doc := tstMustSample(t, w, clk, time.Second, nil)
	tstWantNum(t, doc, 0, "memory", "swap_used")
	tstWantNum(t, doc, 0, "memory", "swap_total")
}

func TestSamplerMemoryWithUnreadablePageFileKeepsTheRest(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.swapErr = errFakeUnavailable
	doc, _ := tstSampleAfter(t, w, clk, time.Second, nil)
	tstWantNull(t, doc, "memory", "swap_used")
	tstWantNull(t, doc, "memory", "swap_total")
	tstWantNum(t, doc, 4294967296, "memory", "used")
	tstWantNum(t, doc, 25, "memory", "used_percent")
}

func TestSamplerMemoryUnavailableWhenTotalIsZero(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.memTotal, w.memAvail = 0, 0
	doc, _ := tstSampleAfter(t, w, clk, time.Second, nil)
	tstWantNull(t, doc, "memory")
}

func TestSamplerMemoryFractionalPercent(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.memTotal, w.memAvail = 8*tstGiB, 5*tstGiB
	doc := tstMustSample(t, w, clk, time.Second, nil)
	tstWantNum(t, doc, 37.5, "memory", "used_percent")
	tstWantNum(t, doc, 3*tstGiB, "memory", "used")
}

// ---------------------------------------------------------------------------
// ST-10: drives

func TestSamplerDrivesListSystemDriveFirstThenByName(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.drives = []fakeDrive{
		{Mount: `D:\`, Total: 64 * tstGiB, Free: 44 * tstGiB, FS: "exFAT", Removable: true},
		{Mount: `C:\`, Total: 100 * tstGiB, Free: 60 * tstGiB, FS: "NTFS"},
		{Mount: `E:\`, Total: 200 * tstGiB, Free: 100 * tstGiB, FS: "NTFS"},
	}
	doc := tstMustSample(t, w, clk, time.Second, nil)
	disks := tstArr(t, doc, "disks")
	var mounts []string
	var external []bool
	for _, d := range disks {
		m, _ := tstAt(d, "mount")
		e, _ := tstAt(d, "external")
		s, _ := m.(string)
		b, _ := e.(bool)
		mounts = append(mounts, s)
		external = append(external, b)
	}
	if !tstSameStrings(mounts, []string{`C:\`, `D:\`, `E:\`}) {
		t.Fatalf("mounts = %q, want C:\\, D:\\, E:\\", mounts)
	}
	if external[0] || !external[1] || external[2] {
		t.Errorf("external = %v, want only D:\\ to be external", external)
	}
}

func TestSamplerDriveUsedIsTotalMinusFreeSpace(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.drives = []fakeDrive{{Mount: `C:\`, Total: 100 * tstGiB, Free: 60 * tstGiB, FS: "NTFS"}}
	doc := tstMustSample(t, w, clk, time.Second, nil)
	d := tstArr(t, doc, "disks")
	if len(d) != 1 {
		t.Fatalf("disks has %d entries, want 1", len(d))
	}
	first := d[0]
	if v, _ := tstAt(first, "used"); v != float64(40*tstGiB) {
		t.Errorf("used = %v, want %d", v, 40*tstGiB)
	}
	if v, _ := tstAt(first, "total"); v != float64(100*tstGiB) {
		t.Errorf("total = %v, want %d", v, 100*tstGiB)
	}
	if v, _ := tstAt(first, "used_percent"); v != float64(40) {
		t.Errorf("used_percent = %v, want 40", v)
	}
	if v, _ := tstAt(first, "fstype"); v != "NTFS" {
		t.Errorf("fstype = %v, want NTFS", v)
	}
	if v, _ := tstAt(first, "external"); v != false {
		t.Errorf("external = %v, want false", v)
	}
}

func TestSamplerDriveWithUnreadableFileSystemHasNullFstype(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.drives = []fakeDrive{{Mount: `C:\`, Total: 100 * tstGiB, Free: 60 * tstGiB, FS: ""}}
	doc := tstMustSample(t, w, clk, time.Second, nil)
	d := tstArr(t, doc, "disks")
	if len(d) != 1 {
		t.Fatalf("disks has %d entries, want 1", len(d))
	}
	if v, ok := tstAt(d[0], "fstype"); !ok || v != nil {
		t.Errorf("fstype = %v (present %v), want null", v, ok)
	}
}

func TestSamplerSkipsDrivesWithoutReadableSize(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.drives = []fakeDrive{
		{Mount: `C:\`, Total: 100 * tstGiB, Free: 60 * tstGiB, FS: "NTFS"},
		{Mount: `D:\`, Total: 0, Free: 0, FS: ""},
	}
	doc := tstMustSample(t, w, clk, time.Second, nil)
	d := tstArr(t, doc, "disks")
	if len(d) != 1 {
		t.Errorf("disks has %d entries, want only C:\\", len(d))
	}
}

func TestSamplerDrivesUnavailableWhenNoDriveIsReadable(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.drives = nil
	doc, _ := tstSampleAfter(t, w, clk, time.Second, nil)
	tstWantNull(t, doc, "disks")

	clk = newFakeClock()
	w = newManualWorld(clk)
	w.drivesErr = errFakeUnavailable
	doc, _ = tstSampleAfter(t, w, clk, time.Second, nil)
	tstWantNull(t, doc, "disks")
}

// ---------------------------------------------------------------------------
// ST-11: disk I/O

func TestSamplerDiskIORatesInMegabytesPerSecond(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.diskRead, w.diskWrite = 100*tstMiB, 50*tstMiB
	doc := tstMustSample(t, w, clk, 2*time.Second, func() {
		w.diskRead += 20 * tstMiB
		w.diskWrite += 10 * tstMiB
	})
	tstWantNum(t, doc, 10, "disk_io", "read_rate")
	tstWantNum(t, doc, 5, "disk_io", "write_rate")
}

func TestSamplerDiskIOUnavailableWhenCountersAreUnreadable(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.diskErr = errFakeUnavailable
	doc, _ := tstSampleAfter(t, w, clk, time.Second, nil)
	tstWantNull(t, doc, "disk_io")
}

func TestSamplerCounterThatShrankGivesRateZeroForThatReadingOnly(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.diskRead, w.diskWrite = 5000*tstMiB, 100*tstMiB
	s := tstNewSampler(w, clk)

	clk.Advance(time.Second)
	w.set(func() { w.diskRead, w.diskWrite = 3000*tstMiB, 104*tstMiB })
	snap, _ := s.Sample()
	doc := tstSnapshotDoc(t, snap)
	tstWantNum(t, doc, 0, "disk_io", "read_rate")
	tstWantNum(t, doc, 4, "disk_io", "write_rate")

	clk.Advance(time.Second)
	w.set(func() { w.diskRead, w.diskWrite = 3006*tstMiB, 104*tstMiB })
	snap, _ = s.Sample()
	doc = tstSnapshotDoc(t, snap)
	tstWantNum(t, doc, 6, "disk_io", "read_rate")
	tstWantNum(t, doc, 0, "disk_io", "write_rate")
}

// ---------------------------------------------------------------------------
// ST-12: network

func tstNetWorld(clk *fakeClock, adapters []fakeAdapter) *fakeWorld {
	w := newManualWorld(clk)
	w.adapters = adapters
	w.nets = nil
	for _, a := range adapters {
		w.nets = append(w.nets, fakeNet{Name: a.Name})
	}
	return w
}

// tstTraffic sets the counters so that, after one second, each adapter shows
// the given rates in MiB/s (rx, tx).
func tstTraffic(w *fakeWorld, rates map[string][2]float64) {
	for i := range w.nets {
		r := rates[w.nets[i].Name]
		w.nets[i].Rx += uint64(r[0] * tstMiB)
		w.nets[i].Tx += uint64(r[1] * tstMiB)
	}
}

func TestSamplerNetworkListsAdaptersByTrafficAndSumsThem(t *testing.T) {
	clk := newFakeClock()
	w := tstNetWorld(clk, []fakeAdapter{
		{Name: "WLAN", IPv4: []string{"198.51.100.7"}},
		{Name: "Ethernet", IPv4: []string{"192.0.2.17"}, Default: true},
	})
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstTraffic(w, map[string][2]float64{"Ethernet": {3, 1}, "WLAN": {0.5, 0.25}})
	})
	net := tstArr(t, doc, "network")
	if names := tstNames(t, net); !tstSameStrings(names, []string{"Ethernet", "WLAN"}) {
		t.Fatalf("network = %q, want Ethernet then WLAN", names)
	}
	tstWantNum(t, map[string]any{"n": net[0]}, 3, "n", "rx_rate_mbs")
	tstWantNum(t, map[string]any{"n": net[0]}, 1, "n", "tx_rate_mbs")
	tstWantNum(t, map[string]any{"n": net[1]}, 0.5, "n", "rx_rate_mbs")
	tstWantNum(t, map[string]any{"n": net[1]}, 0.25, "n", "tx_rate_mbs")
	tstWantNum(t, doc, 3.5, "network_total", "rx_rate_mbs")
	tstWantNum(t, doc, 1.25, "network_total", "tx_rate_mbs")
}

func TestSamplerNetworkRateUsesTheMeasuredWindow(t *testing.T) {
	clk := newFakeClock()
	w := tstNetWorld(clk, []fakeAdapter{{Name: "Ethernet", Default: true}})
	doc := tstMustSample(t, w, clk, 2*time.Second, func() { w.nets[0].Rx += 10 * tstMiB; w.nets[0].Tx += 4 * tstMiB })
	tstWantNum(t, doc, 5, "network_total", "rx_rate_mbs")
	tstWantNum(t, doc, 2, "network_total", "tx_rate_mbs")
}

func TestSamplerNetworkTunnelOnTheDefaultRouteCountsAlone(t *testing.T) {
	clk := newFakeClock()
	w := tstNetWorld(clk, []fakeAdapter{
		{Name: "Ethernet", IPv4: []string{"192.0.2.17"}},
		{Name: "Contoso VPN", IPv4: []string{"198.51.100.2"}, Default: true, Tunnel: true},
	})
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstTraffic(w, map[string][2]float64{"Ethernet": {2.5, 1.5}, "Contoso VPN": {2, 1}})
	})
	net := tstArr(t, doc, "network")
	if len(net) == 0 {
		t.Fatal("network is empty")
	}
	if names := tstNames(t, net); names[0] != "Contoso VPN" {
		t.Errorf("network = %q, want the tunnel first", names)
	}
	tstWantNum(t, doc, 2, "network_total", "rx_rate_mbs")
	tstWantNum(t, doc, 1, "network_total", "tx_rate_mbs")
}

func TestSamplerNetworkTunnelWithoutDefaultRouteIsIgnored(t *testing.T) {
	clk := newFakeClock()
	w := tstNetWorld(clk, []fakeAdapter{
		{Name: "Ethernet", Default: true},
		{Name: "Contoso VPN", Tunnel: true},
	})
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstTraffic(w, map[string][2]float64{"Ethernet": {1, 0.5}, "Contoso VPN": {5, 5}})
	})
	for _, n := range tstNames(t, tstArr(t, doc, "network")) {
		if n == "Contoso VPN" {
			t.Errorf("a tunnel without the default route is listed")
		}
	}
	tstWantNum(t, doc, 1, "network_total", "rx_rate_mbs")
	tstWantNum(t, doc, 0.5, "network_total", "tx_rate_mbs")
}

func TestSamplerNetworkListsThreeAdaptersAndTotalsAllOfThem(t *testing.T) {
	clk := newFakeClock()
	w := tstNetWorld(clk, []fakeAdapter{
		{Name: "Alpha", Default: true},
		{Name: "Bravo"},
		{Name: "Charlie"},
		{Name: "Delta"},
	})
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstTraffic(w, map[string][2]float64{
			"Alpha": {0.5, 0.5}, "Bravo": {3, 1}, "Charlie": {0.5, 0.5}, "Delta": {1.5, 0.5},
		})
	})
	net := tstArr(t, doc, "network")
	if names := tstNames(t, net); !tstSameStrings(names, []string{"Bravo", "Delta", "Alpha"}) {
		t.Errorf("network = %q, want Bravo, Delta, Alpha (by traffic, ties by name, three at most)", names)
	}
	tstWantNum(t, doc, 5.5, "network_total", "rx_rate_mbs")
	tstWantNum(t, doc, 2.5, "network_total", "tx_rate_mbs")
}

func TestSamplerNetworkIgnoresCountersOfAdaptersThatAreNotListed(t *testing.T) {
	clk := newFakeClock()
	w := tstNetWorld(clk, []fakeAdapter{{Name: "Ethernet", Default: true}})
	w.nets = append(w.nets, fakeNet{Name: "Loopback Pseudo-Interface 1"})
	doc := tstMustSample(t, w, clk, time.Second, func() {
		w.nets[0].Rx += 2 * tstMiB
		w.nets[1].Rx += 900 * tstMiB
		w.nets[1].Tx += 900 * tstMiB
	})
	if names := tstNames(t, tstArr(t, doc, "network")); !tstSameStrings(names, []string{"Ethernet"}) {
		t.Errorf("network = %q, want only Ethernet", names)
	}
	tstWantNum(t, doc, 2, "network_total", "rx_rate_mbs")
	tstWantNum(t, doc, 0, "network_total", "tx_rate_mbs")
}

func TestSamplerNetworkAdapterThatAppearsLaterShowsUpInTheNextSample(t *testing.T) {
	clk := newFakeClock()
	w := tstNetWorld(clk, []fakeAdapter{{Name: "Ethernet", Default: true}})
	s := tstNewSampler(w, clk)

	clk.Advance(time.Second)
	w.set(func() {
		w.nets[0].Rx += 1 * tstMiB
		w.adapters = append(w.adapters, fakeAdapter{Name: "WLAN"})
		w.nets = append(w.nets, fakeNet{Name: "WLAN", Rx: 700 * tstMiB, Tx: 300 * tstMiB})
	})
	snap, _ := s.Sample()
	doc := tstSnapshotDoc(t, snap)
	if names := tstNames(t, tstArr(t, doc, "network")); !tstSameStrings(names, []string{"Ethernet"}) {
		t.Errorf("first sample lists %q, want only Ethernet (WLAN has no previous reading)", names)
	}
	tstWantNum(t, doc, 1, "network_total", "rx_rate_mbs")

	clk.Advance(time.Second)
	w.set(func() {
		w.nets[0].Rx += 1 * tstMiB
		w.nets[1].Rx += 2 * tstMiB
		w.nets[1].Tx += 1 * tstMiB
	})
	snap, _ = s.Sample()
	doc = tstSnapshotDoc(t, snap)
	if names := tstNames(t, tstArr(t, doc, "network")); !tstSameStrings(names, []string{"WLAN", "Ethernet"}) {
		t.Errorf("second sample lists %q, want WLAN then Ethernet", names)
	}
	tstWantNum(t, doc, 3, "network_total", "rx_rate_mbs")
	tstWantNum(t, doc, 1, "network_total", "tx_rate_mbs")
}

func TestSamplerNetworkCounterThatShrankGivesRateZero(t *testing.T) {
	clk := newFakeClock()
	w := tstNetWorld(clk, []fakeAdapter{{Name: "Ethernet", Default: true}, {Name: "WLAN"}})
	w.nets[0].Rx = 5000 * tstMiB
	doc := tstMustSample(t, w, clk, time.Second, func() {
		w.nets[0].Rx = 3000 * tstMiB
		w.nets[1].Rx += 2 * tstMiB
	})
	net := tstArr(t, doc, "network")
	for i, n := range net {
		name, _ := tstAt(n, "name")
		if name == "Ethernet" {
			tstWantNum(t, map[string]any{"n": net[i]}, 0, "n", "rx_rate_mbs")
		}
	}
	tstWantNum(t, doc, 2, "network_total", "rx_rate_mbs")
}

func TestSamplerNetworkRatesAreNeverNegative(t *testing.T) {
	clk := newFakeClock()
	w := tstNetWorld(clk, []fakeAdapter{{Name: "Ethernet", Default: true}})
	w.nets[0].Rx, w.nets[0].Tx = 1<<40, 1<<40
	doc := tstMustSample(t, w, clk, time.Second, func() { w.nets[0].Rx, w.nets[0].Tx = 10, 10 })
	tstWantNum(t, doc, 0, "network_total", "rx_rate_mbs")
	tstWantNum(t, doc, 0, "network_total", "tx_rate_mbs")
}

// ---------------------------------------------------------------------------
// ST-13: processes

func tstProcessMap(doc map[string]any, pid int) map[string]any {
	list, _ := tstAt(doc, "top_processes")
	a, _ := list.([]any)
	for _, p := range a {
		if v, _ := tstAt(p, "pid"); v == float64(pid) {
			return map[string]any{"p": p}
		}
	}
	return nil
}

func tstPIDs(doc map[string]any) []int {
	list, _ := tstAt(doc, "top_processes")
	a, _ := list.([]any)
	var out []int
	for _, p := range a {
		v, _ := tstAt(p, "pid")
		f, _ := v.(float64)
		out = append(out, int(f))
	}
	return out
}

func tstSameInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestSamplerProcessCPUIsPercentOfTheWholeMachine(t *testing.T) {
	clk := newFakeClock()
	w := tstFourCPUWorld(clk)
	w.procs = []fakeProc{{PID: 100, Name: "chrome.exe", Start: 7, CPU: 1_000_000, PrivateWS: 100 * tstMiB}}
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstBumpCPUs(w, 5_000_000, 10_000_000)
		w.procs[0].CPU += 5_000_000 // 0.5 s of processor time in 1 s on 4 processors
	})
	p := tstProcessMap(doc, 100)
	if p == nil {
		t.Fatalf("process 100 missing: %v", doc["top_processes"])
	}
	tstWantNum(t, p, 12.5, "p", "cpu")
	tstWantNum(t, p, 100*tstMiB, "p", "memory_bytes")
	tstWantStr(t, p, "chrome", "p", "name")
}

func TestSamplerProcessCPUIsCappedAtOneHundred(t *testing.T) {
	clk := newFakeClock()
	w := tstFourCPUWorld(clk)
	w.procs = []fakeProc{{PID: 100, Name: "spin.exe", Start: 7}}
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstBumpCPUs(w, 0, 10_000_000)
		w.procs[0].CPU += 100_000_000 // ten seconds of processor time in one second
	})
	p := tstProcessMap(doc, 100)
	if p == nil {
		t.Fatal("process 100 missing")
	}
	tstWantNum(t, p, 100, "p", "cpu")
}

func TestSamplerProcessCPUUsesTheMeasuredWindow(t *testing.T) {
	clk := newFakeClock()
	w := tstFourCPUWorld(clk)
	w.procs = []fakeProc{{PID: 100, Name: "a.exe", Start: 7}}
	doc := tstMustSample(t, w, clk, 2*time.Second, func() {
		tstBumpCPUs(w, 5_000_000, 10_000_000)
		w.procs[0].CPU += 10_000_000 // 1 s in 2 s on 4 processors
	})
	tstWantNum(t, tstProcessMap(doc, 100), 12.5, "p", "cpu")
}

func TestSamplerProcessOrderIsCPUThenMemoryThenPID(t *testing.T) {
	clk := newFakeClock()
	w := tstFourCPUWorld(clk)
	w.procs = []fakeProc{
		{PID: 10, Name: "a.exe", Start: 1, PrivateWS: 100 * tstMiB},
		{PID: 11, Name: "b.exe", Start: 1, PrivateWS: 300 * tstMiB},
		{PID: 12, Name: "c.exe", Start: 1, PrivateWS: 300 * tstMiB},
		{PID: 13, Name: "d.exe", Start: 1, PrivateWS: 10 * tstMiB},
		{PID: 14, Name: "e.exe", Start: 1, PrivateWS: 10 * tstMiB},
		{PID: 15, Name: "f.exe", Start: 1, PrivateWS: 10 * tstMiB},
		{PID: 16, Name: "g.exe", Start: 1, PrivateWS: tstMiB},
	}
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstBumpCPUs(w, 5_000_000, 10_000_000)
		w.procs[0].CPU += 1_000_000 // a
		w.procs[1].CPU += 1_000_000 // b
		w.procs[2].CPU += 1_000_000 // c
		w.procs[3].CPU += 2_000_000 // d
		w.procs[4].CPU += 0         // e
		w.procs[5].CPU += 3_000_000 // f
		w.procs[6].CPU += 0         // g
	})
	if got, want := tstPIDs(doc), []int{15, 13, 11, 12, 10}; !tstSameInts(got, want) {
		t.Errorf("top_processes pids = %v, want %v (five at most, cpu desc, memory desc, pid asc)", got, want)
	}
	tstWantNum(t, doc, 7, "procs")
}

func TestSamplerProcessWithEqualValuesSortsByAscendingPID(t *testing.T) {
	clk := newFakeClock()
	w := tstFourCPUWorld(clk)
	w.procs = []fakeProc{
		{PID: 30, Name: "z.exe", Start: 1, PrivateWS: tstMiB},
		{PID: 20, Name: "y.exe", Start: 1, PrivateWS: tstMiB},
		{PID: 25, Name: "x.exe", Start: 1, PrivateWS: tstMiB},
	}
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstBumpCPUs(w, 5_000_000, 10_000_000)
		for i := range w.procs {
			w.procs[i].CPU += 1_000_000
		}
	})
	if got, want := tstPIDs(doc), []int{20, 25, 30}; !tstSameInts(got, want) {
		t.Errorf("top_processes pids = %v, want %v", got, want)
	}
}

func TestSamplerProcessCountExcludesTheIdleProcess(t *testing.T) {
	clk := newFakeClock()
	w := tstFourCPUWorld(clk)
	w.procs = []fakeProc{
		{PID: 0, Name: "", Start: 0},
		{PID: 4, Name: "", Start: 1},
		{PID: 100, Name: "a.exe", Start: 1},
	}
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstBumpCPUs(w, 5_000_000, 10_000_000)
		w.procs[0].CPU += 30_000_000 // idle time must never rank
		w.procs[1].CPU += 1_000_000
		w.procs[2].CPU += 2_000_000
	})
	tstWantNum(t, doc, 2, "procs")
	for _, pid := range tstPIDs(doc) {
		if pid == 0 {
			t.Errorf("the idle process (PID 0) is ranked")
		}
	}
}

func TestSamplerProcessWithoutPreviousReadingIsNotRankedButCounted(t *testing.T) {
	clk := newFakeClock()
	w := tstFourCPUWorld(clk)
	w.procs = []fakeProc{
		{PID: 100, Name: "old.exe", Start: 1},
		{PID: 7, Name: "reused.exe", Start: 111},
	}
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstBumpCPUs(w, 5_000_000, 10_000_000)
		w.procs[0].CPU += 1_000_000
		w.procs[1] = fakeProc{PID: 7, Name: "reused.exe", Start: 222, CPU: 90_000_000} // same PID, other start time
		w.procs = append(w.procs, fakeProc{PID: 8, Name: "new.exe", Start: 333, CPU: 90_000_000})
	})
	if got, want := tstPIDs(doc), []int{100}; !tstSameInts(got, want) {
		t.Errorf("top_processes pids = %v, want %v (no ranking without a measurement window)", got, want)
	}
	tstWantNum(t, doc, 3, "procs")
}

func TestSamplerProcessListIsEmptyNotNullWhenNoProcessHasAWindow(t *testing.T) {
	clk := newFakeClock()
	w := tstFourCPUWorld(clk)
	w.procs = nil // readable but empty at creation
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstBumpCPUs(w, 5_000_000, 10_000_000)
		w.procs = []fakeProc{{PID: 100, Name: "a.exe", Start: 1}, {PID: 101, Name: "b.exe", Start: 1}}
	})
	if a := tstArr(t, doc, "top_processes"); len(a) != 0 {
		t.Errorf("top_processes = %v, want []", a)
	}
	tstWantNum(t, doc, 2, "procs")
}

func TestSamplerProcessTableUnreadableGivesNulls(t *testing.T) {
	clk := newFakeClock()
	w := tstFourCPUWorld(clk)
	w.procsErr = errFakeUnavailable
	doc, _ := tstSampleAfter(t, w, clk, time.Second, func() { tstBumpCPUs(w, 5, 10) })
	tstWantNull(t, doc, "procs")
	tstWantNull(t, doc, "top_processes")
	tstWantNotNull(t, doc, "cpu")
	tstWantNotNull(t, doc, "memory")
}

func TestSamplerProcessCounterThatShrankGivesCPUZero(t *testing.T) {
	clk := newFakeClock()
	w := tstFourCPUWorld(clk)
	w.procs = []fakeProc{{PID: 100, Name: "a.exe", Start: 1, CPU: 50_000_000}}
	doc := tstMustSample(t, w, clk, time.Second, func() {
		tstBumpCPUs(w, 5_000_000, 10_000_000)
		w.procs[0].CPU = 10_000_000
	})
	p := tstProcessMap(doc, 100)
	if p == nil {
		t.Fatal("process 100 missing")
	}
	tstWantNum(t, p, 0, "p", "cpu")
}

func TestSamplerProcessNames(t *testing.T) {
	cases := []struct {
		pid         int
		raw, want   string
		description string
	}{
		{100, "chrome.exe", "chrome", "extension removed"},
		{100, "Docker Desktop.exe", "Docker Desktop", "spaces kept"},
		{100, "My.App.exe", "My.App", "only the final extension is removed"},
		{100, "NoExtension", "NoExtension", "no extension"},
		{100, "SmartScreen.exe", "SmartScreen", "case kept"},
		{100, `C:\Users\Example\bin\tool.exe`, "tool", "no path"},
		{4, "", "System", "empty name of PID 4"},
		{99, "", "", "empty name of another process"},
	}
	for _, c := range cases {
		c := c
		t.Run(c.description, func(t *testing.T) {
			clk := newFakeClock()
			w := tstFourCPUWorld(clk)
			w.procs = []fakeProc{{PID: c.pid, Name: c.raw, Start: 1}}
			doc := tstMustSample(t, w, clk, time.Second, func() {
				tstBumpCPUs(w, 5_000_000, 10_000_000)
				w.procs[0].CPU += 1_000_000
			})
			p := tstProcessMap(doc, c.pid)
			if p == nil {
				t.Fatalf("process %d missing: %v", c.pid, doc["top_processes"])
			}
			tstWantStr(t, p, c.want, "p", "name")
		})
	}
}

// ---------------------------------------------------------------------------
// ST-14: uptime and platform

func TestSamplerUptimeInWholeSeconds(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.uptime = 93784 * time.Second
	doc := tstMustSample(t, w, clk, time.Second, nil)
	tstWantNum(t, doc, 93784, "uptime_seconds")
}

func TestSamplerUptimeAndPlatformAreNullWhenUnreadable(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.uptimeErr, w.platformErr = errFakeUnavailable, errFakeUnavailable
	doc, _ := tstSampleAfter(t, w, clk, time.Second, nil)
	tstWantNull(t, doc, "uptime_seconds")
	tstWantNull(t, doc, "platform")
}

func TestSamplerPlatformTextComesFromTheSource(t *testing.T) {
	clk := newFakeClock()
	w := newManualWorld(clk)
	w.platform = "windows 10.0.26100"
	doc := tstMustSample(t, w, clk, time.Second, nil)
	tstWantStr(t, doc, "windows 10.0.26100", "platform")
}

func containsString(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
