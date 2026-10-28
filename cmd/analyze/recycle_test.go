package main

// Moving entries to the recycle bin (the per-entry steps, rejection after the
// confirmation, changes between the checks, cancellation, dry run) and the log
// lines that result.

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

type tstRecRig struct {
	t       *testing.T
	f       *fakeFS
	clk     *fakeClock
	rec     *fakeRecycler
	env     map[string]string
	logFile string
	log     *OpLog
}

func newRecRig(t *testing.T) *tstRecRig {
	t.Helper()
	f := newFakeFS()
	clk := newFakeClock()
	tstWinTree(f)
	env, logFile := tstLogEnv(t, tstWinEnv())
	return &tstRecRig{t: t, f: f, clk: clk, rec: newFakeRecycler(f, clk), env: env, logFile: logFile, log: tstNewOpLog(env, clk, nil)}
}

func (r *tstRecRig) deps() Deps { return Deps{FS: r.f, Recycler: r.rec, Clock: r.clk} }

func (r *tstRecRig) run(root string, items ...Item) []Result {
	r.t.Helper()
	return r.runCtx(context.Background(), root, items...)
}

func (r *tstRecRig) runCtx(ctx context.Context, root string, items ...Item) []Result {
	r.t.Helper()
	done := make(chan []Result, 1)
	go func() { done <- RecycleItems(ctx, r.deps(), r.env, root, items, r.log) }()
	select {
	case res := <-done:
		return res
	case <-time.After(20 * time.Second):
		r.t.Fatal("RecycleItems did not return within 20 s")
		return nil
	}
}

func (r *tstRecRig) records() ([]tstLogLine, []string) {
	r.t.Helper()
	return tstParseLog(r.t, tstReadLog(r.t, r.logFile))
}

func tstOutcomes(res []Result) []Outcome {
	out := make([]Outcome, len(res))
	for i, x := range res {
		out[i] = x.Outcome
	}
	return out
}

func tstWantOutcomes(t *testing.T, res []Result, want ...Outcome) {
	t.Helper()
	got := tstOutcomes(res)
	if len(got) != len(want) {
		t.Fatalf("%d results, want %d: %v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("result %d = %v, want %v", i, got[i], want[i])
		}
	}
}

func (r *tstRecRig) assertNoRecycle() {
	r.t.Helper()
	if calls := r.rec.recorded(); len(calls) != 0 {
		r.t.Errorf("the recycler was called: %q", calls)
	}
}

func (r *tstRecRig) assertNoLogFile() {
	r.t.Helper()
	if _, err := os.Stat(r.logFile); err == nil {
		r.t.Errorf("the log file %s exists", r.logFile)
	}
}

// ---------------------------------------------------------------------------
// Success

func TestRecycleItemsMovesEveryEntryInTheOrderOfTheListAndLogsOneLineEach(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\a\f`, 1)
	r.f.file(`C:\Data\b.txt`, 1500)
	r.f.file(`C:\Data\c\g`, 1)
	r.rec.step = 5 * time.Second
	items := []Item{tstDirItem(`C:\Data\a`, 3*tstGiB), tstFileItem(`C:\Data\b.txt`, 1500), tstDirItem(`C:\Data\c`, 12*tstMiB)}
	res := r.run(`C:\Data`, items...)
	tstWantOutcomes(t, res, Recycled, Recycled, Recycled)
	if got := r.rec.recorded(); !tstSameStrings(got, []string{`C:\Data\a`, `C:\Data\b.txt`, `C:\Data\c`}) {
		t.Errorf("recycler calls = %q, want exactly the paths of the list in order", got)
	}
	if r.rec.maxConcurrent() != 1 {
		t.Errorf("%d simultaneous recycler calls, want one after the other", r.rec.maxConcurrent())
	}
	recs, markers := r.records()
	if len(recs) != 3 || len(markers) != 1 {
		t.Fatalf("%d records and %d markers, want 3 and 1", len(recs), len(markers))
	}
	wantDetail := []string{"3.0GB", "1.5KB", "12.0MB"}
	wantPath := []string{`C:\Data\a`, `C:\Data\b.txt`, `C:\Data\c`}
	for i, rec := range recs {
		if rec.action != "RECYCLED" || rec.path != wantPath[i] || rec.detail != wantDetail[i] || rec.command != "analyze" || rec.run != "" {
			t.Errorf("record %d = %+v, want RECYCLED %s (%s) of the command analyze", i, rec, wantPath[i], wantDetail[i])
		}
	}
	// every line takes the clock at the time of its own writing
	t0, _ := time.ParseInLocation("2006-01-02 15:04:05", recs[0].time, time.Local)
	t1, _ := time.ParseInLocation("2006-01-02 15:04:05", recs[1].time, time.Local)
	t2, _ := time.ParseInLocation("2006-01-02 15:04:05", recs[2].time, time.Local)
	if t1.Sub(t0) != 5*time.Second || t2.Sub(t1) != 5*time.Second {
		t.Errorf("times %s, %s, %s: want steps of 5 s", recs[0].time, recs[1].time, recs[2].time)
	}
}

func TestRecycleItemsAddsAPlusToThePartiallyMeasuredSize(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\p\f`, 1)
	it := tstDirItem(`C:\Data\p`, 2048)
	it.State = Partial
	tstWantOutcomes(t, r.run(`C:\Data`, it), Recycled)
	recs, _ := r.records()
	if len(recs) != 1 || recs[0].detail != "2.0KB+" {
		t.Errorf("records = %+v, want the detail 2.0KB+", recs)
	}
}

func TestRecycleItemsKeepsParenthesesAndBackslashesOfThePath(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\App (x86)\f`, 1)
	tstWantOutcomes(t, r.run(`C:\Data`, tstDirItem(`C:\Data\App (x86)`, tstKiB)), Recycled)
	recs, _ := r.records()
	if len(recs) != 1 || recs[0].path != `C:\Data\App (x86)` || recs[0].detail != "1.0KB" {
		t.Errorf("records = %+v", recs)
	}
}

func TestRecycleItemsWritesOneMarkerForSeveralCalls(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\a`, 1)
	r.f.file(`C:\Data\b`, 1)
	r.run(`C:\Data`, tstFileItem(`C:\Data\a`, 1))
	r.run(`C:\Data`, tstFileItem(`C:\Data\b`, 1))
	recs, markers := r.records()
	if len(recs) != 2 || len(markers) != 1 {
		t.Errorf("%d records and %d markers, want 2 and 1", len(recs), len(markers))
	}
}

func TestRecycleItemsReturnsOneResultPerEntryInOrder(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\a`, 1)
	r.f.file(`C:\Data\b`, 1)
	res := r.run(`C:\Data`, tstFileItem(`C:\Data\a`, 1), tstFileItem(`C:\Data\gone`, 1), tstFileItem(`C:\Data\b`, 1))
	tstWantOutcomes(t, res, Recycled, Gone, Recycled)
}

// ---------------------------------------------------------------------------
// Step 2: already gone

func TestRecycleItemsTreatsAVanishedEntryAsAlreadyGoneWithoutCallOrLogLine(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\x`, 1)
	r.f.file(`C:\Data\y`, 1)
	res := r.run(`C:\Data`, tstFileItem(`C:\Data\x`, 1), tstFileItem(`C:\Data\gone`, 1), tstFileItem(`C:\Data\y`, 1))
	tstWantOutcomes(t, res, Recycled, Gone, Recycled)
	if got := r.rec.recorded(); !tstSameStrings(got, []string{`C:\Data\x`, `C:\Data\y`}) {
		t.Errorf("recycler calls = %q, want the two existing entries", got)
	}
	recs, _ := r.records()
	if len(recs) != 2 {
		t.Errorf("%d log lines, want 2: a vanished entry gets none", len(recs))
	}
}

// ---------------------------------------------------------------------------
// Step 1: path check

func TestRecycleItemsSkipsInvalidPathsWithoutTouchingTheFileSystem(t *testing.T) {
	cases := []struct{ name, path, logged string }{
		{"relative", `a\b`, `a\b`},
		{"NUL", "C:\\Data\\a\x00b", `C:\Data\a\x00b`},
		{"dot-dot", `C:\Data\a\..\b`, `C:\Data\a\..\b`},
	}
	for _, c := range cases {
		r := newRecRig(t)
		r.f.file(`C:\Data\a\f`, 1)
		r.f.file(`C:\Data\b\f`, 1)
		res := r.run(`C:\Data`, Item{Name: "x", Path: c.path, Size: 1, State: Complete})
		tstWantOutcomes(t, res, Skipped)
		r.assertNoRecycle()
		if n := r.f.identityTotal() + r.f.readTotal(); n != 0 {
			t.Errorf("%s: the file system was used %d times for an invalid path", c.name, n)
		}
		recs, _ := r.records()
		if len(recs) != 1 || recs[0].action != "SKIPPED" || recs[0].path != c.logged || !strings.HasPrefix(recs[0].detail, "refused: ") {
			t.Errorf("%s: records = %+v, want one SKIPPED line with `refused: ` and the path %q", c.name, recs, c.logged)
		}
		if res[0].Reason == "" {
			t.Errorf("%s: the result has no reason", c.name)
		}
	}
}

// ---------------------------------------------------------------------------
// Steps 3 to 5: refusals after the confirmation

func TestRecycleItemsSkipsAndLogsEveryRefusalAfterTheConfirmation(t *testing.T) {
	type tc struct {
		name  string
		root  string
		path  string
		setup func(r *tstRecRig)
		tweak func(it *Item)
	}
	cases := []tc{
		{"protected", `C:\`, `C:\Windows`, func(r *tstRecRig) {}, nil},
		{"outside root", `C:\Data`, `C:\Other\x`, func(r *tstRecRig) { r.f.file(`C:\Other\x\f`, 1) }, nil},
		{"the root itself", `C:\Data`, `C:\Data`, func(r *tstRecRig) { r.f.dir(`C:\Data\a`) }, nil},
		{"link item", `C:\Data`, `C:\Data\lnk`, func(r *tstRecRig) { r.f.link(`C:\Data\lnk`, `D:\t`) }, func(it *Item) { it.IsLink = true }},
		{"cloud item", `C:\Data`, `C:\Data\od`, func(r *tstRecRig) { r.f.file(`C:\Data\od\f`, 1) }, func(it *Item) { it.Cloud = true }},
		{"unmeasured", `C:\Data`, `C:\Data\locked`, func(r *tstRecRig) { r.f.dir(`C:\Data\locked`) }, func(it *Item) { it.State = Unavailable }},
		{"data folder", `C:\`, `C:\SweeprData`, func(r *tstRecRig) {
			r.env["SWEEPR_DATA_DIR"] = `C:\SweeprData`
			r.log = tstNewOpLog(tstEnvWith(r.env, "SWEEPR_DATA_DIR", filepathDir(r.logFile)), r.clk, nil)
			r.f.dir(`C:\SweeprData\config`)
		}, nil},
		{"protected descendant", `C:\Data`, `C:\Data\proj`, func(r *tstRecRig) { r.f.file(`C:\Data\proj\x\.ssh\id`, 1) }, nil},
		{"link descendant", `C:\Data`, `C:\Data\proj`, func(r *tstRecRig) { r.f.link(`C:\Data\proj\lnk`, `D:\t`) }, nil},
		{"cloud descendant", `C:\Data`, `C:\Data\proj`, func(r *tstRecRig) { r.f.cloudFile(`C:\Data\proj\ph`, 5, false) }, nil},
		{"unreadable descendant", `C:\Data`, `C:\Data\proj`, func(r *tstRecRig) {
			r.f.file(`C:\Data\proj\sub\f`, 1)
			r.f.failDir(`C:\Data\proj\sub`, errTstAccess)
		}, nil},
		{"linked ancestor", `C:\Data`, `C:\Data\via\x`, func(r *tstRecRig) {
			r.f.file(`C:\Data\real\x\f`, 1)
			r.f.link(`C:\Data\via`, `C:\Data\real`)
		}, nil},
	}
	for _, c := range cases {
		r := newRecRig(t)
		r.f.dir(c.path)
		c.setup(r)
		it := tstDirItem(c.path, 1)
		if c.tweak != nil {
			c.tweak(&it)
		}
		res := r.run(c.root, it)
		if len(res) != 1 || res[0].Outcome != Skipped {
			t.Errorf("%s: results = %+v, want Skipped", c.name, res)
			continue
		}
		if res[0].Reason == "" {
			t.Errorf("%s: no reason", c.name)
		}
		r.assertNoRecycle()
		recs, _ := r.records()
		if len(recs) != 1 || recs[0].action != "SKIPPED" || recs[0].path != c.path || !strings.HasPrefix(recs[0].detail, "refused: ") {
			t.Errorf("%s: records = %+v, want one SKIPPED line `refused: …`", c.name, recs)
		}
		r.f.assertNoLinkFollowed(t)
	}
}

func filepathDir(p string) string {
	// the data folder of a log file <data>/config/operations.log
	return strings.TrimSuffix(strings.TrimSuffix(p, string(os.PathSeparator)+"operations.log"), string(os.PathSeparator)+"config")
}

func TestRecycleItemsContinuesWithTheRestAfterARefusal(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\ok1\f`, 1)
	r.f.file(`C:\Data\bad\.ssh\id`, 1)
	r.f.file(`C:\Data\ok2\f`, 1)
	res := r.run(`C:\Data`, tstDirItem(`C:\Data\ok1`, 1), tstDirItem(`C:\Data\bad`, 1), tstDirItem(`C:\Data\ok2`, 1))
	tstWantOutcomes(t, res, Recycled, Skipped, Recycled)
	if got := r.rec.recorded(); !tstSameStrings(got, []string{`C:\Data\ok1`, `C:\Data\ok2`}) {
		t.Errorf("recycler calls = %q", got)
	}
	recs, _ := r.records()
	var actions []string
	for _, rec := range recs {
		actions = append(actions, rec.action)
	}
	if !tstSameStrings(actions, []string{"RECYCLED", "SKIPPED", "RECYCLED"}) {
		t.Errorf("log actions = %v", actions)
	}
}

func TestRecycleItemsNeverMovesTheRootItsAncestorsOrSiblings(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\sub\a\f`, 1)
	r.f.file(`C:\Data\sub2\f`, 1)
	root := `C:\Data\sub`
	res := r.run(root, tstDirItem(`C:\Data\sub`, 1), tstDirItem(`C:\Data`, 1), tstDirItem(`C:\Data\sub2`, 1), tstDirItem(`C:\`, 1))
	tstWantOutcomes(t, res, Skipped, Skipped, Skipped, Skipped)
	r.assertNoRecycle()
}

func TestRecycleItemsRefusesAnEntryBelowALinkedAncestor(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\real\x\f`, 1)
	r.f.link(`C:\Data\via`, `C:\Data\real`)
	res := r.run(`C:\Data`, tstDirItem(`C:\Data\via\x`, 1))
	tstWantOutcomes(t, res, Skipped)
	r.assertNoRecycle()
}

func TestRecycleItemsReadsTheEnvironmentAgainForEveryEntry(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\first\f`, 1)
	r.f.file(`C:\Data\second\f`, 1)
	// while the first entry is moved, ProgramData changes to the second entry's folder
	r.rec.onCall = func(path string) { r.env["ProgramData"] = `C:\Data\second` }
	res := r.run(`C:\Data`, tstDirItem(`C:\Data\first`, 1), tstDirItem(`C:\Data\second`, 1))
	tstWantOutcomes(t, res, Recycled, Skipped)
	if got := r.rec.recorded(); !tstSameStrings(got, []string{`C:\Data\first`}) {
		t.Errorf("recycler calls = %q, want only the first entry", got)
	}
}

// ---------------------------------------------------------------------------
// Changes between the first check and the call

func tstBaselineReads(t *testing.T, build func(r *tstRecRig), root string, it Item) (reads map[string]int) {
	t.Helper()
	r := newRecRig(t)
	build(r)
	res := r.run(root, it)
	tstWantOutcomes(t, res, Recycled)
	reads = map[string]int{}
	for _, p := range []string{it.Path, tstParent(it.Path), root} {
		reads["read:"+p] = r.f.readCount(p)
		reads["id:"+p] = r.f.identityCount(p)
	}
	return reads
}

func TestRecycleItemsChecksTheTreeAgainRightBeforeTheCall(t *testing.T) {
	build := func(r *tstRecRig) {
		r.f.file(`C:\Data\proj\a\f`, 1)
		r.f.file(`C:\Data\proj\b\f`, 1)
	}
	it := tstDirItem(`C:\Data\proj`, 2)
	reads := tstBaselineReads(t, build, `C:\Data`, it)["read:"+it.Path]
	if reads < 2 {
		t.Fatalf("the tree was read %d times for a successful move, want a check before the dialog follow-up and one right before the call", reads)
	}
	mutations := map[string]func(r *tstRecRig){
		"a protected folder appears": func(r *tstRecRig) { r.f.dir(`C:\Data\proj\a\.ssh`) },
		"a junction appears":         func(r *tstRecRig) { r.f.link(`C:\Data\proj\b\lnk`, `D:\t`) },
		"a cloud placeholder appears": func(r *tstRecRig) {
			r.f.cloudFile(`C:\Data\proj\b\ph.txt`, 3, false)
		},
		"a folder becomes unreadable": func(r *tstRecRig) { r.f.failDir(`C:\Data\proj\a`, errTstAccess) },
	}
	for name, mutate := range mutations {
		r := newRecRig(t)
		build(r)
		key := tstKey(it.Path)
		r.f.onRead = func(k string, nth int) {
			if k == key && nth == reads {
				mutate(r)
			}
		}
		res := r.run(`C:\Data`, it)
		tstWantOutcomes(t, res, Skipped)
		r.assertNoRecycle()
		recs, _ := r.records()
		if len(recs) != 1 || recs[0].action != "SKIPPED" {
			t.Errorf("%s: records = %+v, want one SKIPPED line", name, recs)
		}
		r.f.assertNoLinkFollowed(t)
	}
}

func TestRecycleItemsChecksTheIdentitiesAgainRightBeforeTheCall(t *testing.T) {
	cases := []struct {
		name  string
		build func(r *tstRecRig)
		item  Item
	}{
		{"folder", func(r *tstRecRig) { r.f.file(`C:\Data\proj\a\f`, 1) }, tstDirItem(`C:\Data\proj`, 1)},
		{"file", func(r *tstRecRig) { r.f.file(`C:\Data\proj\a\f.bin`, 1) }, tstFileItem(`C:\Data\proj\a\f.bin`, 1)},
	}
	for _, c := range cases {
		base := tstBaselineReads(t, c.build, `C:\Data`, c.item)
		targets := []string{c.item.Path, tstParent(c.item.Path), `C:\Data`}
		for _, target := range targets {
			n := base["id:"+target]
			if n < 2 {
				t.Errorf("%s: the identity of %s was read %d times, want it bound once and compared again", c.name, target, n)
				continue
			}
			r := newRecRig(t)
			c.build(r)
			key := tstKey(target)
			r.f.onIdentity = func(k string, nth int) {
				if k == key && nth == n {
					r.f.bumpIdentity(target)
				}
			}
			res := r.run(`C:\Data`, c.item)
			tstWantOutcomes(t, res, Skipped)
			r.assertNoRecycle()
			recs, _ := r.records()
			if len(recs) != 1 || recs[0].action != "SKIPPED" {
				t.Errorf("%s, identity of %s changed: records = %+v, want one SKIPPED line", c.name, target, recs)
			}
		}
	}
}

func TestRecycleItemsBindsTheIdentitiesBeforeTheFirstTreeCheck(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\proj\a\f`, 1)
	it := tstDirItem(`C:\Data\proj`, 1)
	firstRead := -1
	r.f.onRead = func(k string, nth int) {
		if k == tstKey(it.Path) && nth == 1 {
			firstRead = r.f.identityCount(it.Path)
		}
	}
	tstWantOutcomes(t, r.run(`C:\Data`, it), Recycled)
	if firstRead < 1 {
		t.Errorf("the identity of the target had been read %d times when its tree was first read, want it bound before", firstRead)
	}
}

// ---------------------------------------------------------------------------
// Failure of the call

func TestRecycleItemsLogsAFailedCallWithSizeAndReasonAndContinues(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\a\f`, 1)
	r.f.file(`C:\Data\b\f`, 1)
	r.f.file(`C:\Data\c\f`, 1)
	r.rec.failPath(`C:\Data\b`, fmt.Errorf("the shell reported an error (0x80004005)\nsecond line"))
	res := r.run(`C:\Data`, tstDirItem(`C:\Data\a`, tstKiB), tstDirItem(`C:\Data\b`, 12*tstMiB), tstDirItem(`C:\Data\c`, tstKiB))
	tstWantOutcomes(t, res, Recycled, Failed, Recycled)
	if !strings.Contains(res[1].Reason, "the shell reported an error") {
		t.Errorf("reason = %q, want the error text", res[1].Reason)
	}
	if !r.f.exists(`C:\Data\b`) {
		t.Errorf("the entry vanished although its move failed")
	}
	recs, _ := r.records()
	if len(recs) != 3 {
		t.Fatalf("%d records, want 3: %+v", len(recs), recs)
	}
	if recs[1].action != "FAILED" || recs[1].path != `C:\Data\b` {
		t.Errorf("record 1 = %+v, want FAILED C:\\Data\\b", recs[1])
	}
	if !strings.HasPrefix(recs[1].detail, "12.0MB; ") || !strings.Contains(recs[1].detail, "the shell reported an error [0x80004005]") {
		t.Errorf("detail = %q, want `12.0MB; <reason>` with the parentheses replaced", recs[1].detail)
	}
	if strings.Contains(recs[1].detail, "\n") || !strings.Contains(recs[1].detail, `\n`) {
		t.Errorf("detail = %q, want the line break written out as \\n", recs[1].detail)
	}
}

func TestRecycleItemsFailureIsNotRetriedAndNeverFallsBack(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\a\f`, 1)
	r.rec.failAll = errTstBoom
	res := r.run(`C:\Data`, tstDirItem(`C:\Data\a`, 1))
	tstWantOutcomes(t, res, Failed)
	if got := r.rec.recorded(); len(got) != 1 {
		t.Errorf("%d recycler calls, want exactly one", len(got))
	}
	if !r.f.exists(`C:\Data\a`) {
		t.Errorf("the entry is gone")
	}
}

// ---------------------------------------------------------------------------
// Log switches

func TestRecycleItemsWritesNoLogLineWhenTheLogIsSwitchedOff(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\a`, 1)
	r.env["SWEEPR_NO_OPLOG"] = "1"
	r.log = tstNewOpLog(r.env, r.clk, nil)
	tstWantOutcomes(t, r.run(`C:\Data`, tstFileItem(`C:\Data\a`, 1)), Recycled)
	r.assertNoLogFile()
}

func TestRecycleItemsResultIsTheSameWhenTheLogCannotBeWritten(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\a`, 1)
	r.f.file(`C:\Data\b\.ssh\id`, 1)
	r.f.file(`C:\Data\c`, 1)
	r.rec.failPath(`C:\Data\c`, errTstBoom)
	r.log = tstNewOpLog(r.env, r.clk, func(string, []byte) error { return errTstBoom })
	res := r.run(`C:\Data`, tstFileItem(`C:\Data\a`, 1), tstDirItem(`C:\Data\b`, 1), tstFileItem(`C:\Data\c`, 1))
	tstWantOutcomes(t, res, Recycled, Skipped, Failed)
	r.assertNoLogFile()
}

// ---------------------------------------------------------------------------
// Dry run

func TestRecycleItemsDryRunChangesNothingAndLogsNothing(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\a\f`, 1)
	r.f.file(`C:\Data\b`, 1)
	r.env["SWEEPR_DRY_RUN"] = "1"
	r.run(`C:\Data`, tstDirItem(`C:\Data\a`, 1), tstFileItem(`C:\Data\b`, 1))
	r.assertNoRecycle()
	r.assertNoLogFile()
	if !r.f.exists(`C:\Data\a`) || !r.f.exists(`C:\Data\b`) {
		t.Errorf("an entry vanished in the dry run")
	}
}

func TestRecycleItemsOnlyTheValueOneMakesADryRun(t *testing.T) {
	for _, v := range []string{"0", "true", "", "yes", " 1", "11"} {
		r := newRecRig(t)
		r.f.file(`C:\Data\a`, 1)
		r.env["SWEEPR_DRY_RUN"] = v
		res := r.run(`C:\Data`, tstFileItem(`C:\Data\a`, 1))
		tstWantOutcomes(t, res, Recycled)
		if got := r.rec.recorded(); len(got) != 1 {
			t.Errorf("SWEEPR_DRY_RUN=%q: %d recycler calls, want 1", v, len(got))
		}
	}
}

// ---------------------------------------------------------------------------
// Cancellation

func TestRecycleItemsDoesNothingWhenCanceledBeforeTheStart(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\a`, 1)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r.runCtx(ctx, `C:\Data`, tstFileItem(`C:\Data\a`, 1))
	r.assertNoRecycle()
	r.assertNoLogFile()
}

func TestRecycleItemsStopsAfterTheRunningCallWhenCanceledAndLogsNoLineWithoutResult(t *testing.T) {
	r := newRecRig(t)
	r.f.file(`C:\Data\a`, 1)
	r.f.file(`C:\Data\b`, 1)
	r.f.file(`C:\Data\c`, 1)
	r.rec.block()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan []Result, 1)
	go func() {
		done <- RecycleItems(ctx, r.deps(), r.env, `C:\Data`,
			[]Item{tstFileItem(`C:\Data\a`, 1), tstFileItem(`C:\Data\b`, 1), tstFileItem(`C:\Data\c`, 1)}, r.log)
	}()
	r.rec.waitCalls(t, 1)
	cancel()
	r.rec.unblock()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("RecycleItems did not return after the cancellation")
	}
	time.Sleep(30 * time.Millisecond)
	if got := r.rec.recorded(); len(got) != 1 {
		t.Errorf("recycler calls = %q, want only the call that had begun", got)
	}
	recs, _ := r.records()
	if len(recs) != 0 {
		t.Errorf("log lines = %+v, want none: the interrupted call has no result and the others never began", recs)
	}
}
