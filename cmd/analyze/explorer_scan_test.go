package main

// Measurement requests of the display: identity, cancellation, late results,
// error view. The scanner is replaced by a controllable fake.

import (
	"sort"
	"strings"
	"testing"
)

func tstListingOf(root string, items ...Item) Listing {
	l := Listing{Root: root, State: Complete}
	sorted := append([]Item(nil), items...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Size > sorted[j].Size })
	for _, it := range sorted {
		l.Items = append(l.Items, it)
		l.TotalSize += it.Size
		if it.State != Complete {
			l.State = Partial
		}
		if !it.IsDir && !it.IsLink {
			l.TotalFiles++
		}
	}
	return l
}

func (r *tstRig) waitScans(n int) {
	r.t.Helper()
	if !r.p.settle(func() bool { return len(r.sc.all()) >= n }) {
		r.t.Fatalf("%d scans started after 15 s, want %d", len(r.sc.all()), n)
	}
}

func (r *tstRig) waitCanceled(c *scanCall) {
	r.t.Helper()
	if !r.p.settle(c.canceled) {
		r.t.Fatalf("the measurement of %s was not canceled", c.root)
	}
}

func (r *tstRig) assertScans(n int) {
	r.t.Helper()
	r.untilIdle()
	if got := len(r.sc.all()); got != n {
		r.t.Errorf("%d scans were started, want %d", got, n)
	}
}

func tstScanRig(t *testing.T, target string) *tstRig {
	t.Helper()
	return tstNewRig(t, target, tstRigOpts{scanner: &fakeScanner{}})
}

func TestExplorerStartsTheMeasurementOfTheTargetAtOnce(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	c := r.sc.all()[0]
	if tstKey(c.root) != `c:\data` {
		t.Errorf("the first measurement is for %q, want C:\\Data", c.root)
	}
	if c.counters == nil {
		t.Errorf("the scanner got no counters to fill")
	}
	if c.canceled() {
		t.Errorf("the first measurement is already canceled")
	}
	r.assertScans(1)
}

func TestExplorerShowsTheListingOfTheCurrentRequest(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	c := r.sc.all()[0]
	c.final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\dirB`, tstGiB), tstDirItem(`C:\Data\dirA`, 3*tstGiB)))
	r.until("the listing", func(v string) bool { return strings.Contains(v, "3.0GB") && strings.Contains(v, "1.0GB") })
	if got := tstRowNames(r.view(), []string{"dirA", "dirB"}); !tstSameStrings(got, []string{"dirA", "dirB"}) {
		t.Errorf("rows = %v, want dirA then dirB", got)
	}
}

func TestExplorerShowsFinishedChildrenBeforeTheFinalResult(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	c := r.sc.all()[0]
	c.child(tstDirItem(`C:\Data\dirA`, 3*tstGiB))
	r.until("the first child", func(v string) bool { return strings.Contains(v, "dirA") && strings.Contains(v, "3.0GB") })
	if strings.Contains(r.view(), "%") {
		t.Errorf("a percentage is shown before the measurement is complete:\n%s", r.view())
	}
}

func TestExplorerRCancelsTheRunningMeasurementAndStartsANewOne(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	r.press("r")
	r.waitScans(2)
	first, second := r.sc.all()[0], r.sc.all()[1]
	r.waitCanceled(first)
	if second.canceled() {
		t.Errorf("the new measurement is canceled")
	}
	if tstKey(second.root) != `c:\data` {
		t.Errorf("the new measurement is for %q", second.root)
	}
}

func TestExplorerDiscardsEveryResultOfAnOlderRequestAfterRescanning(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	r.press("r")
	r.waitScans(2)
	r.press("r")
	r.waitScans(3)
	calls := r.sc.all()
	r.waitCanceled(calls[0])
	r.waitCanceled(calls[1])
	if calls[2].canceled() {
		t.Fatalf("the current measurement is canceled")
	}
	// results of the first and second request arrive late
	calls[1].child(tstDirItem(`C:\Data\ghost`, 9*tstGiB))
	calls[1].final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\ghost`, 9*tstGiB)))
	r.untilIdle()
	if strings.Contains(r.view(), "ghost") {
		t.Fatalf("the result of an older request changed the display:\n%s", r.view())
	}
	calls[2].final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\real`, 2*tstGiB)))
	r.until("the current result", func(v string) bool { return strings.Contains(v, "real") })
	calls[0].child(tstDirItem(`C:\Data\ghost2`, tstGiB))
	r.untilIdle()
	if strings.Contains(r.view(), "ghost") {
		t.Errorf("a late child of the first request was taken over:\n%s", r.view())
	}
}

func TestExplorerDiscardsLateResultsOfAFolderThatWasLeftEvenForTheSamePath(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	root := r.sc.all()[0]
	root.final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\dirA`, 2*tstGiB), tstDirItem(`C:\Data\dirB`, tstGiB)))
	r.until("the listing", func(v string) bool { return strings.Contains(v, "2.0GB") && strings.Contains(v, "1.0GB") })

	r.press("home", "enter") // dirA
	r.waitScans(2)
	a1 := r.sc.all()[1]
	if tstKey(a1.root) != `c:\data\dira` {
		t.Fatalf("the second measurement is for %q, want C:\\Data\\dirA", a1.root)
	}
	r.press("esc") // back: the snapshot is restored, the running measurement is canceled
	r.waitCanceled(a1)
	r.until("the parent again", func(v string) bool { return strings.Contains(v, "dirB") && !strings.Contains(v, `C:\Data\dirA`) })
	r.assertScans(2)

	r.press("home", "enter") // dirA again: a new request for the same path
	r.waitScans(3)
	a2 := r.sc.all()[2]
	if tstKey(a2.root) != `c:\data\dira` || a2.canceled() {
		t.Fatalf("the third measurement: root %q, canceled %v", a2.root, a2.canceled())
	}
	a1.child(tstFileItem(`C:\Data\dirA\ghost.bin`, 5*tstGiB))
	a1.final(tstListingOf(`C:\Data\dirA`, tstFileItem(`C:\Data\dirA\ghost.bin`, 5*tstGiB)))
	r.untilIdle()
	if strings.Contains(r.view(), "ghost") {
		t.Fatalf("a result of the left folder (an older request for the same path) was taken over:\n%s", r.view())
	}
	a2.final(tstListingOf(`C:\Data\dirA`, tstFileItem(`C:\Data\dirA\real.bin`, 7*tstMiB)))
	r.until("the current folder", func(v string) bool { return strings.Contains(v, "real.bin") && strings.Contains(v, `C:\Data\dirA`) })
	if strings.Contains(r.view(), "ghost") {
		t.Errorf("the stale result appears after the current one:\n%s", r.view())
	}
}

func TestExplorerDiscardsPartialResultsOfAnotherFolderAfterNavigation(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	root := r.sc.all()[0]
	root.final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\dirA`, 2*tstGiB), tstDirItem(`C:\Data\dirB`, tstGiB)))
	r.until("the listing", func(v string) bool { return strings.Contains(v, "2.0GB") && strings.Contains(v, "1.0GB") })
	r.press("home", "enter") // dirA
	r.waitScans(2)
	a := r.sc.all()[1]
	r.press("esc")
	r.waitCanceled(a)
	r.until("the parent again", func(v string) bool { return strings.Contains(v, "dirB") && !strings.Contains(v, `C:\Data\dirA`) })
	r.press("home", "down", "enter") // dirB
	r.waitScans(3)
	b := r.sc.all()[2]
	if tstKey(b.root) != `c:\data\dirb` {
		t.Fatalf("the third measurement is for %q", b.root)
	}
	a.child(tstFileItem(`C:\Data\dirA\ghost.bin`, 4*tstGiB))
	a.final(tstListingOf(`C:\Data\dirA`, tstFileItem(`C:\Data\dirA\ghost.bin`, 4*tstGiB)))
	r.untilIdle()
	if strings.Contains(r.view(), "ghost") {
		t.Fatalf("a result of folder A appeared in the view of folder B:\n%s", r.view())
	}
	b.final(tstListingOf(`C:\Data\dirB`, tstFileItem(`C:\Data\dirB\real3.bin`, 7*tstMiB)))
	r.until("folder B", func(v string) bool { return strings.Contains(v, "real3.bin") && strings.Contains(v, `C:\Data\dirB`) })
}

func TestExplorerBackCancelsTheRunningMeasurementWithoutStartingAnother(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	root := r.sc.all()[0]
	root.final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\dirA`, 2*tstGiB)))
	r.untilContains("2.0GB")
	r.press("home", "enter")
	r.waitScans(2)
	r.press("left")
	r.waitCanceled(r.sc.all()[1])
	r.assertScans(2)
}

func TestExplorerGoingToTheOverviewCancelsTheRunningMeasurement(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	first := r.sc.all()[0]
	r.press("esc") // empty history: the overview
	r.waitCanceled(first)
	r.until("the overview", func(v string) bool { return strings.Contains(v, "40.0GB") })
	r.waitScans(2)
	if tstKey(r.sc.all()[1].root) != tstKey(`C:\Users\Example`) {
		t.Errorf("the overview measures %q, want the Home folder", r.sc.all()[1].root)
	}
}

func TestExplorerQuitCancelsTheRunningMeasurement(t *testing.T) {
	for _, key := range []string{"q", "ctrl+c"} {
		r := tstScanRig(t, `C:\Data`)
		r.waitScans(1)
		first := r.sc.all()[0]
		r.press(key)
		r.waitCanceled(first)
		if !r.waitQuit() {
			t.Errorf("%s did not end the program", key)
		}
	}
}

func TestExplorerMeasuresAgainWithANewRequestAfterAMove(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	first := r.sc.all()[0]
	r.fs.file(`C:\Data\dirA\f`, 10)
	first.final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\dirA`, 10)))
	r.untilContains("10B")
	r.press("home", "delete", "enter")
	r.rec.waitCalls(t, 1)
	r.waitScans(2)
	second := r.sc.all()[1]
	if tstKey(second.root) != `c:\data` || second.canceled() {
		t.Errorf("the measurement after the move: root %q, canceled %v", second.root, second.canceled())
	}
	second.final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\dirB`, 20)))
	r.until("the new listing", func(v string) bool { return strings.Contains(v, "20B") })
}

func TestExplorerAtMostOneFolderMeasurementRunsAtOnce(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	for i := 0; i < 4; i++ {
		r.press("r")
		r.waitScans(2 + i)
	}
	running := 0
	for _, c := range r.sc.all() {
		if !c.canceled() {
			running++
		}
	}
	if running != 1 {
		t.Errorf("%d measurements are running, want exactly the current one", running)
	}
}

func TestExplorerRInTheOverviewCancelsAndRestartsTheHomeMeasurement(t *testing.T) {
	r := tstScanRig(t, "")
	r.waitScans(1)
	first := r.sc.all()[0]
	r.press("r")
	r.waitScans(2)
	r.waitCanceled(first)
	if r.sc.all()[1].canceled() {
		t.Errorf("the new Home measurement is canceled")
	}
}

func TestExplorerOverviewShowsTheDrivesAtOnceAndMeasuresHomeInTheBackground(t *testing.T) {
	r := tstScanRig(t, "")
	r.waitScans(1)
	home := r.sc.all()[0]
	if tstKey(home.root) != tstKey(`C:\Users\Example`) {
		t.Fatalf("the first measurement is for %q, want the Home folder", home.root)
	}
	r.until("the drives", func(v string) bool { return strings.Contains(v, "40.0GB") })
	view := r.view()
	if row := tstRowOf(view, `C:\Users\Example`); !strings.Contains(row, "scanning") {
		t.Errorf("Home row = %q, want scanning", row)
	}
	if strings.Contains(view, "%") {
		t.Errorf("a percentage is shown before Home is measured:\n%s", view)
	}
	home.final(tstListingOf(`C:\Users\Example`, tstFileItem(`C:\Users\Example\f.bin`, 5*tstMiB)))
	r.until("Home measured", func(v string) bool {
		return strings.Contains(tstRowOf(v, `C:\Users\Example`), "5.0MB") && strings.Contains(v, "40.0%")
	})
}

// ---------------------------------------------------------------------------
// Error view

func TestExplorerShowsAnErrorInsteadOfTheListAndKeepsBackRescanAndQuit(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	r.sc.all()[0].fail(errTstBoom)
	r.untilContains(errTstBoom.Error())
	if strings.Contains(r.view(), "scanning") {
		t.Errorf("the error view still shows rows as scanning:\n%s", r.view())
	}

	r.press("r")
	r.waitScans(2)
	r.sc.all()[1].final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\dirA`, tstGiB)))
	r.untilContains("1.0GB")
	if strings.Contains(r.view(), errTstBoom.Error()) {
		t.Errorf("the error is still shown after a successful measurement")
	}

	r2 := tstScanRig(t, `C:\Data`)
	r2.waitScans(1)
	r2.sc.all()[0].fail(errTstBoom)
	r2.untilContains(errTstBoom.Error())
	r2.press("esc")
	r2.until("the overview", func(v string) bool { return strings.Contains(v, "40.0GB") })

	r3 := tstScanRig(t, `C:\Data`)
	r3.waitScans(1)
	r3.sc.all()[0].fail(errTstBoom)
	r3.untilContains(errTstBoom.Error())
	r3.press("q")
	if !r3.waitQuit() {
		t.Errorf("q did not end the program in the error view")
	}
}

func TestExplorerShowsTheErrorOfAnUnreadableRootMeasuredWithTheRealScanner(t *testing.T) {
	r := tstNewRig(t, `C:\Bad`, tstRigOpts{noTree: true, setup: func(f *fakeFS) { f.failDir(`C:\Bad`, errTstBoom) }})
	r.untilContains(errTstBoom.Error())
	r.press("r")
	r.untilIdle()
	r.press("esc")
	r.until("the overview", func(v string) bool { return strings.Contains(v, "40.0GB") })
}

func TestExplorerRecoversFromAnErrorAfterRescanning(t *testing.T) {
	r := tstNewRig(t, `C:\Bad`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		f.file(`C:\Bad\ok\f`, 3*tstMiB)
		f.failDir(`C:\Bad`, errTstBoom)
	}})
	r.untilContains(errTstBoom.Error())
	r.fs.clearFailures(`C:\Bad`)
	r.press("r")
	r.untilContains("3.0MB")
	if strings.Contains(r.view(), errTstBoom.Error()) {
		t.Errorf("the error is still shown:\n%s", r.view())
	}
}

func TestExplorerIgnoresTheErrorOfAnOlderRequest(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	r.press("r")
	r.waitScans(2)
	r.sc.all()[0].fail(errTstBoom) // the canceled first request reports a failure late
	r.untilIdle()
	if strings.Contains(r.view(), errTstBoom.Error()) {
		t.Errorf("the error of an older request is shown:\n%s", r.view())
	}
	r.sc.all()[1].final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\dirA`, tstGiB)))
	r.untilContains("1.0GB")
}
