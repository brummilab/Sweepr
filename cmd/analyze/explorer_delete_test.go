package main

// Deleting through the display: trigger, pre-check, dialog, execution in the
// background, results, snapshots, dry run, quitting while moving.

import (
	"errors"
	"math/rand"
	"regexp"
	"strings"
	"testing"
	"time"
)

func (r *tstRig) logRecords() []tstLogLine {
	r.t.Helper()
	recs, _ := tstParseLog(r.t, tstReadLog(r.t, r.logFile))
	return recs
}

func (r *tstRig) waitRecords(n int) {
	r.t.Helper()
	if !r.p.settle(func() bool { return len(r.logRecords()) >= n }) {
		r.t.Fatalf("%d log records after 15 s, want %d; the view is:\n%s", len(r.logRecords()), n, r.view())
	}
}

// waitRemeasure waits until the folder was read again and the display settled.
func (r *tstRig) waitRemeasure(path string, readsBefore int) {
	r.t.Helper()
	if !r.p.settle(func() bool { return r.fs.readCount(path) > readsBefore }) {
		r.t.Fatalf("the folder %s was not measured again; the view is:\n%s", path, r.view())
	}
	r.untilIdle()
}

func (r *tstRig) assertNothingRecycled(what string) {
	r.t.Helper()
	r.untilIdle()
	if calls := r.rec.recorded(); len(calls) != 0 {
		r.t.Errorf("%s: the recycler was called: %q", what, calls)
	}
	if got := tstReadLog(r.t, r.logFile); got != "" {
		r.t.Errorf("%s: the log was written: %q", what, got)
	}
}

func tstMixedTree(f *fakeFS) {
	tstSimpleTree(f)
	f.link(`C:\Data\link1`, `C:\Elsewhere`)
	f.fileLink(`C:\Data\symfile`)
	f.cloudFile(`C:\Data\cloud1\o.bin`, tstGiB, true)
	f.file(`C:\Data\project\.ssh\id`, 1)
	f.file(`C:\Data\project\src\f`, 10)
	f.failDir(`C:\Data\locked1`, errTstAccess)
}

var tstMixedNames = []string{"alpha", "beta", "gamma", "notes.txt", "link1", "symfile", "cloud1", "project", "locked1"}

func tstOpenMixed(t *testing.T) *tstRig {
	t.Helper()
	r := tstNewRig(t, `C:\Data`, tstRigOpts{setup: tstMixedTree})
	r.until("all rows", func(v string) bool {
		return strings.Contains(v, "[link]") && strings.Contains(v, "not measured") && strings.Contains(v, "online]") && !strings.Contains(v, "scanning")
	})
	r.untilIdle()
	r.press("home")
	return r
}

// ---------------------------------------------------------------------------
// Dialog

func TestExplorerDeleteOpensADialogAndMovesNothingBeforeEnter(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.goTo("notes.txt", tstSimpleNames)
	before := r.view()
	r.press("delete")
	r.untilIdle()
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Fatalf("the recycler was called before the confirmation: %q", calls)
	}
	after := r.view()
	if after == before {
		t.Errorf("Delete changed nothing on the screen: no dialog")
	}
	if !strings.Contains(after, "notes.txt") || !strings.Contains(after, "4.0KB") {
		t.Errorf("the dialog does not show the name and the size of the entry:\n%s", after)
	}
	if got := tstReadLog(t, r.logFile); got != "" {
		t.Errorf("the log was written before the confirmation: %q", got)
	}
}

func TestExplorerDialogShowsCountAndSumOfSeveralEntries(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.goTo("beta", tstSimpleNames)
	r.press("space")
	r.goTo("gamma", tstSimpleNames)
	r.press("space")
	r.press("delete")
	r.untilIdle()
	view := r.view()
	if !strings.Contains(view, "2.5GB") {
		t.Errorf("the dialog does not show the sum 2.5GB of both entries:\n%s", view)
	}
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Errorf("the recycler was called before the confirmation: %q", calls)
	}
}

func TestExplorerDialogSumGetsAPlusForPartiallyMeasuredEntries(t *testing.T) {
	r := tstNewRig(t, `C:\M`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		f.file(`C:\M\big\f`, 3*tstMiB)
		f.file(`C:\M\part\f`, 2*tstMiB)
		f.failDir(`C:\M\part\locked`, errTstAccess)
	}})
	names := []string{"big", "part"}
	r.until("the rows", func(v string) bool { return strings.Contains(v, "2.0MB+") && !strings.Contains(v, "scanning") })
	r.untilIdle()
	r.goTo("big", names)
	r.press("space", "down", "space")
	r.press("delete")
	r.untilIdle()
	if strings.Count(r.view(), "5.0MB+") < 1 {
		t.Errorf("the dialog does not show the sum 5.0MB+:\n%s", r.view())
	}
}

func TestExplorerOnlyEnterConfirmsTheDialog(t *testing.T) {
	for _, k := range []string{"space", "y", "Y", "n", "d", "x", "delete", "down", "up", "left", "right", "pgdown", "pgup", "home", "end", "t", "r", "backspace", "j", "f9"} {
		r := tstOpenSimple(t, tstRigOpts{})
		r.goTo("notes.txt", tstSimpleNames)
		r.press("delete")
		r.press(k)
		r.untilIdle()
		if calls := r.rec.recorded(); len(calls) != 0 {
			t.Errorf("key %q in the dialog confirmed it: %q", k, calls)
			continue
		}
		r.press("enter")
		r.rec.waitCalls(t, 1)
		r.untilIdle()
		if calls := r.rec.recorded(); !tstSameStrings(calls, []string{`C:\Data\notes.txt`}) {
			t.Errorf("after key %q and Enter the recycler calls are %q, want only the entry the dialog was opened for", k, calls)
		}
	}
}

func TestExplorerEscAndQCancelTheDialogWithoutQuitting(t *testing.T) {
	for _, k := range []string{"esc", "q"} {
		r := tstOpenSimple(t, tstRigOpts{})
		r.goTo("notes.txt", tstSimpleNames)
		r.press("delete")
		r.press(k)
		r.untilIdle()
		if r.p.quit {
			t.Errorf("key %q in the dialog ended the program", k)
		}
		if !regexp.MustCompile(`(?i)cancel`).MatchString(r.view()) {
			t.Errorf("key %q: the message line does not say that the action was canceled:\n%s", k, r.view())
		}
		r.press("enter") // the dialog is closed: Enter on a file does nothing
		r.assertNothingRecycled("after cancel with " + k)
		if !r.fs.exists(`C:\Data\notes.txt`) {
			t.Errorf("key %q: the file is gone", k)
		}
	}
}

func TestExplorerCtrlCInTheDialogEndsTheProgramWithoutDeleting(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.goTo("notes.txt", tstSimpleNames)
	r.press("delete", "ctrl+c")
	if !r.waitQuit() {
		t.Errorf("Ctrl+C in the dialog did not end the program")
	}
	r.assertNothingRecycled("after Ctrl+C in the dialog")
}

// ---------------------------------------------------------------------------
// Pre-check

func TestExplorerRefusesBeforeTheDialogAndMovesNothing(t *testing.T) {
	for _, kind := range []string{"link1", "symfile", "cloud1", "project", "locked1"} {
		r := tstOpenMixed(t)
		r.goTo(kind, tstMixedNames)
		r.press("delete")
		r.press("enter") // would confirm a dialog; otherwise it opens the folder or does nothing
		r.assertNothingRecycled("single " + kind)
		if !r.fs.exists(`C:\Data\` + kind) {
			t.Errorf("%s: the entry is gone", kind)
		}
	}
}

func TestExplorerRefusesAllWhenOneMarkedEntryIsRefusedAndKeepsTheMarks(t *testing.T) {
	for _, kind := range []string{"link1", "symfile", "cloud1", "project"} {
		r := tstOpenMixed(t)
		r.goTo("beta", tstMixedNames)
		r.press("space")
		r.goTo(kind, tstMixedNames)
		r.press("space")
		r.press("delete")
		r.untilIdle()
		if calls := r.rec.recorded(); len(calls) != 0 {
			t.Errorf("%s: the recycler was called: %q", kind, calls)
		}
		if sp := tstSpecial(r.view(), tstMixedNames); len(sp) != 2 {
			t.Errorf("%s: rows with a mark or the cursor: %v, want the two marks to stay", kind, sp)
		}
		r.press("enter")
		r.assertNothingRecycled("marked beta and " + kind)
		if !r.fs.exists(`C:\Data\beta`) {
			t.Errorf("%s: the acceptable entry beta was moved although another marked entry is refused", kind)
		}
	}
}

func TestExplorerRefusesProtectedEntriesOnTheDriveRoot(t *testing.T) {
	names := []string{"Windows", "Data", "Users", "Program Files (x86)", "Program Files", "ProgramData"}
	r := tstNewRig(t, `C:\`, tstRigOpts{})
	r.until("the rows", func(v string) bool {
		return strings.Contains(v, "Windows") && strings.Contains(v, "%") && !strings.Contains(v, "scanning")
	})
	r.untilIdle()
	for _, n := range []string{"Windows", "Users", "Program Files", "ProgramData"} {
		r.goTo(n, names)
		r.press("delete")
		r.press("enter") // would confirm a dialog; otherwise it opens the folder
		r.assertNothingRecycled("protected " + n)
		r.press("esc") // back to the drive
		r.untilContains("ProgramData")
		r.untilIdle()
	}
	r.goTo("Data", names)
	r.press("space")
	r.goTo("Windows", names)
	r.press("space")
	r.press("delete", "enter")
	r.assertNothingRecycled("Data and Windows marked")
	if !r.fs.exists(`C:\Data`) {
		t.Errorf("C:\\Data was moved although C:\\Windows was marked with it")
	}
}

func TestExplorerRefusesTheSweeprDataFolder(t *testing.T) {
	r := tstNewRig(t, `C:\`, tstRigOpts{env: map[string]string{"SWEEPR_DATA_DIR": `C:\Sweepr-State`, "SWEEPR_NO_OPLOG": "1"}, setup: func(f *fakeFS) {
		f.file(`C:\Sweepr-State\config\operations.log`, 10)
	}})
	names := []string{"Sweepr-State", "Data", "Windows"}
	r.until("the rows", func(v string) bool { return strings.Contains(v, "Sweepr-State") && strings.Contains(v, "%") })
	r.untilIdle()
	r.goTo("Sweepr-State", names)
	r.press("delete", "enter")
	r.untilIdle()
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Errorf("the data folder of Sweepr was handed to the recycler: %q", calls)
	}
}

// ---------------------------------------------------------------------------
// Execution

func TestExplorerRecyclesTheConfirmedEntryAndLogsIt(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.goTo("gamma", tstSimpleNames)
	reads := r.fs.readCount(`C:\Data`)
	r.press("delete", "enter")
	r.rec.waitCalls(t, 1)
	r.waitRecords(1)
	if calls := r.rec.recorded(); !tstSameStrings(calls, []string{`C:\Data\gamma`}) {
		t.Errorf("recycler calls = %q, want only C:\\Data\\gamma", calls)
	}
	recs := r.logRecords()
	if len(recs) != 1 || recs[0].action != "RECYCLED" || recs[0].path != `C:\Data\gamma` || recs[0].detail != "512.0MB" {
		t.Errorf("log records = %+v, want RECYCLED C:\\Data\\gamma (512.0MB)", recs)
	}
	r.waitRemeasure(`C:\Data`, reads)
	r.untilContains(tstPct(5*tstGiB, 7*tstGiB+4*tstKiB))
	if r.fs.exists(`C:\Data\gamma`) {
		t.Errorf("gamma still exists")
	}
	if got := r.cursor(tstSimpleNames); got != "notes.txt" {
		t.Errorf("the cursor is on %q, want the next valid row notes.txt", got)
	}
}

func TestExplorerCursorMovesToTheNextValidRowAfterDeleting(t *testing.T) {
	cases := []struct{ del, want string }{
		{"alpha", "beta"},
		{"beta", "gamma"},
		{"notes.txt", "gamma"}, // the last row: the previous one
	}
	for _, c := range cases {
		r := tstOpenSimple(t, tstRigOpts{})
		r.goTo(c.del, tstSimpleNames)
		reads := r.fs.readCount(`C:\Data`)
		r.press("delete", "enter")
		r.waitRecords(1)
		r.waitRemeasure(`C:\Data`, reads)
		if got := r.cursor(tstSimpleNames); got != c.want {
			t.Errorf("after deleting %s the cursor is on %q, want %s", c.del, got, c.want)
		}
	}
}

func TestExplorerRecyclesInTheOrderOfTheListAndClearsTheMarks(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.goTo("gamma", tstSimpleNames)
	r.press("space")
	r.goTo("alpha", tstSimpleNames)
	r.press("space")
	r.press("delete", "enter")
	r.rec.waitCalls(t, 2)
	r.waitRecords(2)
	if calls := r.rec.recorded(); !tstSameStrings(calls, []string{`C:\Data\alpha`, `C:\Data\gamma`}) {
		t.Errorf("recycler calls = %q, want the order of the list", calls)
	}
	recs := r.logRecords()
	if len(recs) != 2 || recs[0].path != `C:\Data\alpha` || recs[1].path != `C:\Data\gamma` {
		t.Errorf("log records = %+v", recs)
	}
	r.untilIdle()
	if sp := tstSpecial(r.view(), []string{"beta", "notes.txt"}); len(sp) > 1 {
		t.Errorf("rows that differ after the run: %v, want the marks cleared", sp)
	}
}

func TestExplorerShowsTheReasonOfAFailureKeepsTheEntryAndDoesNotMeasureAgain(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.rec.failPath(`C:\Data\alpha`, errors.New("disk on fire"))
	plain := tstPrefixes(r.view(), tstSimpleNames)["alpha"]
	r.press("space") // mark alpha
	reads := r.fs.readCount(`C:\Data`)
	r.press("delete", "enter")
	r.rec.waitCalls(t, 1)
	r.waitRecords(1)
	r.untilContains("disk on fire")
	recs := r.logRecords()
	if len(recs) != 1 || recs[0].action != "FAILED" || recs[0].path != `C:\Data\alpha` || !strings.HasPrefix(recs[0].detail, "5.0GB; ") {
		t.Errorf("log records = %+v, want FAILED C:\\Data\\alpha (5.0GB; <reason>)", recs)
	}
	r.untilIdle()
	if got := r.fs.readCount(`C:\Data`); got != reads {
		t.Errorf("the folder was measured again after a run that moved nothing (%d reads, was %d)", got, reads)
	}
	if !r.fs.exists(`C:\Data\alpha`) {
		t.Errorf("the entry is gone although the move failed")
	}
	if got := tstPrefixes(r.view(), tstSimpleNames)["alpha"]; got != plain {
		t.Errorf("the mark was not cleared (prefix %q, want %q)", got, plain)
	}
}

func TestExplorerLogsASkipAfterTheConfirmationWhenTheTreeChangedInTheMeantime(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.goTo("beta", tstSimpleNames)
	r.press("delete") // the dialog is open and the pre-check passed
	r.fs.dir(`C:\Data\beta\.ssh`)
	reads := r.fs.readCount(`C:\Data`)
	r.press("enter")
	r.waitRecords(1)
	recs := r.logRecords()
	if len(recs) != 1 || recs[0].action != "SKIPPED" || recs[0].path != `C:\Data\beta` || !strings.HasPrefix(recs[0].detail, "refused: ") {
		t.Errorf("log records = %+v, want SKIPPED C:\\Data\\beta (refused: …)", recs)
	}
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Errorf("the recycler was called: %q", calls)
	}
	r.untilIdle()
	if got := r.fs.readCount(`C:\Data`); got != reads {
		t.Errorf("the folder was measured again after a run that moved nothing")
	}
}

func TestExplorerTreatsAnEntryThatVanishedAsAlreadyGone(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.goTo("gamma", tstSimpleNames)
	r.press("delete")
	r.fs.remove(`C:\Data\gamma`) // removed by someone else while the dialog is open
	reads := r.fs.readCount(`C:\Data`)
	r.press("enter")
	r.untilIdle()
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Errorf("the recycler was called for an entry that no longer exists: %q", calls)
	}
	if got := tstReadLog(t, r.logFile); got != "" {
		t.Errorf("the log was written for an entry that was already gone: %q", got)
	}
	r.waitRemeasure(`C:\Data`, reads)
	r.untilContains(tstPct(5*tstGiB, 7*tstGiB+4*tstKiB))
}

func TestExplorerSnapshotsExpireAfterADeletion(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.press("enter") // alpha
	r.until("alpha", func(v string) bool { return strings.Contains(v, `C:\Data\alpha`) && strings.Contains(v, "60.0%") })
	names := []string{"deep", "a1.bin"}
	r.goTo("a1.bin", names)
	r.press("delete", "enter")
	r.waitRecords(1)
	r.until("alpha measured again", func(v string) bool { return strings.Contains(v, "100.0%") })
	r.untilIdle()
	parentReads := r.fs.readCount(`C:\Data`)
	r.press("esc")
	r.until("the parent", func(v string) bool { return strings.Contains(v, "gamma") && !strings.Contains(v, `C:\Data\alpha`) })
	r.untilIdle()
	if got := r.fs.readCount(`C:\Data`); got <= parentReads {
		t.Errorf("the parent was shown from an old snapshot after a deletion (%d reads, was %d)", got, parentReads)
	}
	if row := tstRowOf(r.view(), "alpha"); !strings.Contains(row, "3.0GB") {
		t.Errorf("row of alpha = %q, want the new size 3.0GB", row)
	}
}

func TestExplorerRecyclesFilesChosenInTheLargestFilesViewAndKeepsMarksApart(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	plain := tstPrefixes(r.view(), tstSimpleNames)["alpha"]
	r.press("space") // marks alpha in the folder view
	r.press("t")
	r.untilContains(`C:\Data\alpha\deep\d1.bin`)
	paths := []string{`C:\Data\alpha\deep\d1.bin`, `C:\Data\alpha\a1.bin`, `C:\Data\beta\b1.bin`, `C:\Data\gamma\g1.bin`}
	if sp := tstSpecial(r.view(), paths); len(sp) != 1 {
		t.Errorf("rows that differ in the file list: %v, want only the cursor (the marks of the folder view do not carry over)", sp)
	}
	r.press("t")
	r.until("the folder view", func(v string) bool { return strings.Contains(v, "notes.txt") })
	if got := tstPrefixes(r.view(), tstSimpleNames)["alpha"]; got != plain {
		t.Errorf("the mark of the folder view survived the change of view (prefix %q, want %q)", got, plain)
	}
	r.press("t")
	r.untilContains(`C:\Data\alpha\deep\d1.bin`)
	r.press("space", "delete", "enter")
	r.rec.waitCalls(t, 1)
	r.waitRecords(1)
	if calls := r.rec.recorded(); !tstSameStrings(calls, []string{`C:\Data\alpha\deep\d1.bin`}) {
		t.Errorf("recycler calls = %q, want the file", calls)
	}
	if recs := r.logRecords(); len(recs) != 1 || recs[0].action != "RECYCLED" || recs[0].path != `C:\Data\alpha\deep\d1.bin` || recs[0].detail != "3.0GB" {
		t.Errorf("log records = %+v", recs)
	}
}

// ---------------------------------------------------------------------------
// Dry run

func TestExplorerDryRunMovesNothingLogsNothingAndMeasuresNothingAgain(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{env: map[string]string{"SWEEPR_DRY_RUN": "1"}})
	r.press("space", "down", "space") // alpha and beta
	reads := r.fs.readCount(`C:\Data`)
	r.press("delete")
	r.untilIdle()
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Fatalf("the recycler was called before the confirmation: %q", calls)
	}
	r.press("enter")
	r.untilIdle()
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Errorf("the recycler was called in the dry run: %q", calls)
	}
	if got := tstReadLog(t, r.logFile); got != "" {
		t.Errorf("the log was written in the dry run: %q", got)
	}
	if got := r.fs.readCount(`C:\Data`); got != reads {
		t.Errorf("the folder was measured again in the dry run (%d reads, was %d)", got, reads)
	}
	if !regexp.MustCompile(`(?i)dry[ -]?run`).MatchString(r.view()) {
		t.Errorf("the message line does not say that this was a dry run:\n%s", r.view())
	}
	if !strings.Contains(r.view(), "2") {
		t.Errorf("the message line does not give the number of entries that would be moved")
	}
	if !r.fs.exists(`C:\Data\alpha`) || !r.fs.exists(`C:\Data\beta`) {
		t.Errorf("an entry vanished in the dry run")
	}
}

func TestExplorerDryRunClearsTheMarks(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{env: map[string]string{"SWEEPR_DRY_RUN": "1"}})
	r.press("space", "down", "space", "delete", "enter")
	r.untilIdle()
	r.press("home")
	if sp := tstSpecial(r.view(), tstSimpleNames); len(sp) != 1 {
		t.Errorf("rows that differ after the dry run: %v, want only the cursor", sp)
	}
}

func TestExplorerOnlyTheValueOneMakesADryRun(t *testing.T) {
	for _, v := range []string{"0", "true", "", "yes"} {
		r := tstOpenSimple(t, tstRigOpts{env: map[string]string{"SWEEPR_DRY_RUN": v}})
		r.goTo("notes.txt", tstSimpleNames)
		r.press("delete", "enter")
		r.rec.waitCalls(t, 1)
		if calls := r.rec.recorded(); !tstSameStrings(calls, []string{`C:\Data\notes.txt`}) {
			t.Errorf("SWEEPR_DRY_RUN=%q: recycler calls = %q, want the entry to be moved", v, calls)
		}
	}
}

func TestExplorerDryRunStillRefusesBeforeTheDialog(t *testing.T) {
	r := tstOpenMixed(t)
	r.env["SWEEPR_DRY_RUN"] = "1"
	r.goTo("link1", tstMixedNames)
	r.press("delete")
	r.untilIdle()
	r.press("enter")
	r.assertNothingRecycled("dry run with a link")
}

// ---------------------------------------------------------------------------
// While moving

func TestExplorerIgnoresEveryKeyExceptQuitWhileEntriesAreMoved(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.rec.block()
	r.goTo("notes.txt", tstSimpleNames)
	r.press("delete", "enter")
	r.rec.waitCalls(t, 1)
	reads := r.fs.readTotal()
	for _, k := range []string{"esc", "down", "up", "r", "enter", "space", "delete", "t", "left", "backspace", "right", "home", "end", "x"} {
		r.press(k)
	}
	r.untilIdle()
	if got := r.fs.readTotal(); got != reads {
		t.Errorf("keys during the move caused %d reads", got-reads)
	}
	if r.p.quit {
		t.Errorf("a key other than q and Ctrl+C ended the program during the move")
	}
	if calls := r.rec.recorded(); len(calls) != 1 {
		t.Errorf("recycler calls = %q, want only the one that is running", calls)
	}
	r.rec.unblock()
	r.waitRecords(1)
}

func TestExplorerStaysResponsiveWhileTheRecyclerIsBlocked(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.rec.block()
	r.goTo("notes.txt", tstSimpleNames)
	r.press("delete", "enter")
	r.rec.waitCalls(t, 1)
	r.resize(40, 12) // fails the test when Update does not return
	tstAssertFits(t, r.view(), 40, 12)
	r.resize(120, 30)
	tstAssertFits(t, r.view(), 120, 30)
	r.rec.unblock()
	r.waitRecords(1)
}

func TestExplorerQuitWhileMovingStopsTheRestAndLogsNothingWithoutAResult(t *testing.T) {
	for _, key := range []string{"q", "ctrl+c"} {
		r := tstOpenSimple(t, tstRigOpts{})
		r.rec.block()
		r.press("space", "down", "space", "down", "space") // alpha, beta, gamma
		r.press("delete", "enter")
		r.rec.waitCalls(t, 1)
		r.press(key)
		if !r.waitQuit() {
			t.Fatalf("%s did not end the program during the move", key)
		}
		r.rec.unblock()
		time.Sleep(100 * time.Millisecond)
		if calls := r.rec.recorded(); len(calls) != 1 {
			t.Errorf("%s: recycler calls = %q, want only the call that had begun", key, calls)
		}
		if recs := r.logRecords(); len(recs) != 0 {
			t.Errorf("%s: log records = %+v, want none for an interrupted run", key, recs)
		}
	}
}

// ---------------------------------------------------------------------------
// Random key sequences

func TestExplorerNoSequenceOfKeysMovesAnythingOutsideTheAllowedFolder(t *testing.T) {
	keys := []string{"up", "down", "enter", "esc", "space", "delete", "t", "r", "left", "right", "home", "end", "pgdown", "pgup", "backspace", "y", "q"}
	for seed := int64(1); seed <= 3; seed++ {
		rng := rand.New(rand.NewSource(seed))
		r := tstNewRig(t, `C:\`, tstRigOpts{setup: func(f *fakeFS) {
			f.file(`C:\Users\Example\.ssh\id`, tstMiB)
			f.file(`C:\Windows\System32\big.dll`, 3*tstMiB)
		}})
		r.until("the rows", func(v string) bool { return strings.Contains(v, "Windows") && strings.Contains(v, "%") })
		r.untilIdle()
		for i := 0; i < 250; i++ {
			k := keys[rng.Intn(len(keys))]
			if k == "q" { // keep the sequence going: q ends the program
				k = "down"
			}
			r.press(k)
			if i%50 == 49 {
				r.untilIdle()
			}
		}
		r.untilIdle()
		for _, p := range r.rec.recorded() {
			if k := tstKey(p); k != `c:\data` && !strings.HasPrefix(k, `c:\data\`) {
				t.Errorf("seed %d: the recycler was called for %s, which is outside the folder that may be moved", seed, p)
			}
		}
	}
}

func TestExplorerNoKeyOtherThanEnterEverMovesAnything(t *testing.T) {
	keys := []string{"up", "down", "esc", "space", "delete", "t", "r", "left", "right", "home", "end", "pgdown", "pgup", "backspace", "y", "n", "x", "delete", "space", "right"}
	for seed := int64(11); seed <= 13; seed++ {
		rng := rand.New(rand.NewSource(seed))
		r := tstOpenSimple(t, tstRigOpts{})
		for i := 0; i < 250; i++ {
			r.press(keys[rng.Intn(len(keys))])
			if i%50 == 49 {
				r.untilIdle()
			}
		}
		r.untilIdle()
		if calls := r.rec.recorded(); len(calls) != 0 {
			t.Errorf("seed %d: the recycler was called without Enter: %q", seed, calls)
		}
		if got := tstReadLog(t, r.logFile); got != "" {
			t.Errorf("seed %d: the log was written without Enter: %q", seed, got)
		}
	}
}
