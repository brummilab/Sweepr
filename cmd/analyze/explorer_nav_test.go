package main

// Navigation, history, the largest-files view, rescanning, selection and the
// quit keys of the display.

import (
	"reflect"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Entering and going back

func TestExplorerEnterAndRightOpenAFolderAndMeasureIt(t *testing.T) {
	for _, key := range []string{"enter", "right"} {
		r := tstOpenSimple(t, tstRigOpts{})
		r.press(key)
		r.until("the folder alpha", func(v string) bool {
			return strings.Contains(v, `C:\Data\alpha`) && strings.Contains(v, tstPct(3*tstGiB, 5*tstGiB))
		})
		view := r.view()
		if row := tstRowOf(view, "deep"); !strings.Contains(row, "3.0GB") {
			t.Errorf("%s: row of deep = %q, want 3.0GB", key, row)
		}
		if row := tstRowOf(view, "a1.bin"); !strings.Contains(row, "2.0GB") {
			t.Errorf("%s: row of a1.bin = %q, want 2.0GB", key, row)
		}
		if r.fs.readCount(`C:\Data\alpha`) == 0 {
			t.Errorf("%s: the folder was not read", key)
		}
	}
}

func TestExplorerEnterOnAFileOrALinkDoesNothing(t *testing.T) {
	r := tstNewRig(t, `C:\Data`, tstRigOpts{setup: func(f *fakeFS) {
		f.link(`C:\Data\lnk`, `D:\target`)
		f.fileLink(`C:\Data\fsym`)
	}})
	names := append([]string{"lnk", "fsym"}, tstSimpleNames...)
	r.until("all rows", func(v string) bool { return strings.Contains(v, "[link]") && !strings.Contains(v, "scanning") })
	r.untilIdle()
	for _, n := range []string{"notes.txt", "lnk", "fsym"} {
		r.goTo(n, names)
		before := r.fs.readTotal()
		r.press("enter")
		r.press("right")
		r.untilIdle()
		if got := r.fs.readTotal(); got != before {
			t.Errorf("enter on %s read %d more directories", n, got-before)
		}
		if !strings.Contains(r.view(), `C:\Data`) || strings.Contains(r.view(), `C:\Data\`+n) {
			t.Errorf("enter on %s changed the view:\n%s", n, r.view())
		}
	}
	r.fs.assertNoLinkFollowed(t)
}

func TestExplorerBackRestoresTheListWithoutMeasuringAgainAndRestoresTheCursor(t *testing.T) {
	for _, key := range []string{"esc", "left", "backspace"} {
		r := tstOpenSimple(t, tstRigOpts{})
		r.goTo("beta", tstSimpleNames)
		r.press("enter")
		r.until("the folder beta", func(v string) bool { return strings.Contains(v, `C:\Data\beta`) && strings.Contains(v, "100.0%") })
		reads := r.fs.readCount(`C:\Data`)
		r.press(key)
		r.until("the parent again", func(v string) bool { return strings.Contains(v, "gamma") && !strings.Contains(v, `C:\Data\beta`) })
		r.untilIdle()
		if got := r.fs.readCount(`C:\Data`); got != reads {
			t.Errorf("%s: the parent was measured again (%d reads, was %d)", key, got, reads)
		}
		if got := r.cursor(tstSimpleNames); got != "beta" {
			t.Errorf("%s: the cursor is on %q, want beta (the entry that was entered)", key, got)
		}
		if row := tstRowOf(r.view(), "alpha"); !strings.Contains(row, "5.0GB") || !strings.Contains(row, tstPct(5*tstGiB, tstSimpleTotal)) {
			t.Errorf("%s: the restored list lost its values: %q", key, row)
		}
	}
}

func TestExplorerBackWithAnEmptyHistoryLeadsToTheOverviewAndThenQuits(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.press("esc")
	r.until("the overview", func(v string) bool { return strings.Contains(v, `D:\`) || strings.Contains(v, `C:\Users\Example`) })
	if r.p.quit {
		t.Fatalf("the program ended on the first Esc")
	}
	r.press("esc")
	if !r.waitQuit() {
		t.Errorf("Esc in the overview did not end the program")
	}
}

func TestExplorerEscInAFolderViewDoesNotQuit(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.press("enter")
	r.until("alpha", func(v string) bool { return strings.Contains(v, `C:\Data\alpha`) })
	r.press("esc")
	r.untilIdle()
	if r.p.quit {
		t.Errorf("Esc in a folder view ended the program")
	}
}

func TestExplorerOverviewEnterOpensHomeAndDrives(t *testing.T) {
	r := tstNewRig(t, "", tstOverviewOpts(nil))
	r.untilContains("40.0%")
	r.press("down")
	r.press("enter")
	r.until("the drive C:", func(v string) bool {
		return strings.Contains(v, "Data") && strings.Contains(v, "Users") && !strings.Contains(v, "400.0GB")
	})
	if r.fs.readCount(`C:\`) == 0 {
		t.Errorf("the drive root was not measured after Enter")
	}
	r.press("esc")
	r.until("the overview again", func(v string) bool { return strings.Contains(v, "400.0GB") })
	r.press("home")
	r.press("enter")
	r.until("Home", func(v string) bool { return strings.Contains(v, `Downloads`) })
}

// ---------------------------------------------------------------------------
// Largest files

func TestExplorerLargestFilesViewShowsSizeAndFullPathInOrder(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.press("t")
	paths := []string{`C:\Data\alpha\deep\d1.bin`, `C:\Data\alpha\a1.bin`, `C:\Data\beta\b1.bin`, `C:\Data\gamma\g1.bin`}
	r.until("the file list", func(v string) bool { return strings.Contains(v, paths[3]) })
	view := r.view()
	if got := tstRowNames(view, paths); !tstSameStrings(got, paths) {
		t.Errorf("files in the order %v, want %v", got, paths)
	}
	for i, size := range []string{"3.0GB", "2.0GB", "2.0GB", "512.0MB"} {
		if row := tstRowOf(view, paths[i]); !strings.Contains(row, size) {
			t.Errorf("row of %s = %q, want %s", paths[i], row, size)
		}
	}
	if strings.Contains(view, "notes.txt") {
		t.Errorf("a file below 1 MiB is listed")
	}
}

func TestExplorerTAndBackReturnToTheFolderViewNotToTheParent(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.press("enter")
	r.until("alpha", func(v string) bool { return strings.Contains(v, `C:\Data\alpha`) && strings.Contains(v, "60.0%") })
	r.press("t")
	r.until("the file list", func(v string) bool { return strings.Contains(v, `C:\Data\alpha\deep\d1.bin`) })
	r.press("t")
	r.until("the folder view again", func(v string) bool {
		return strings.Contains(v, "deep") && strings.Contains(v, `C:\Data\alpha`) && !strings.Contains(v, `alpha\deep\d1.bin`)
	})
	r.press("t")
	r.until("the file list again", func(v string) bool { return strings.Contains(v, `alpha\deep\d1.bin`) })
	r.press("esc")
	r.until("the folder view of alpha", func(v string) bool {
		return strings.Contains(v, `C:\Data\alpha`) && !strings.Contains(v, `alpha\deep\d1.bin`)
	})
	if strings.Contains(r.view(), "gamma") {
		t.Errorf("Esc in the file list went to the parent folder:\n%s", r.view())
	}
	r.press("esc")
	r.until("the parent", func(v string) bool { return strings.Contains(v, "gamma") })
}

func TestExplorerLargestFilesViewCannotBeEntered(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.press("t")
	r.untilContains(`C:\Data\alpha\deep\d1.bin`)
	before := r.fs.readTotal()
	r.press("enter", "right")
	r.untilIdle()
	if got := r.fs.readTotal(); got != before {
		t.Errorf("Enter in the file list measured %d more folders", got-before)
	}
	if !strings.Contains(r.view(), `C:\Data\alpha\deep\d1.bin`) {
		t.Errorf("the file list was left:\n%s", r.view())
	}
}

func TestExplorerRescanInTheFileListStaysInTheFileList(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.press("t")
	r.untilContains(`C:\Data\alpha\deep\d1.bin`)
	before := r.fs.readCount(`C:\Data`)
	r.fs.setSize(`C:\Data\alpha\deep\d1.bin`, 3*tstGiB+tstGiB/2)
	r.press("r")
	r.until("the new size in the file list", func(v string) bool {
		return strings.Contains(v, "3.5GB") && strings.Contains(v, `C:\Data\alpha\deep\d1.bin`)
	})
	if got := r.fs.readCount(`C:\Data`); got <= before {
		t.Errorf("r did not measure the folder again (%d reads, was %d)", got, before)
	}
}

func TestExplorerTIsIgnoredAndExplainedWhileTheMeasurementRuns(t *testing.T) {
	r := tstNewRig(t, `C:\Seq`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		tstSeqTree(f)
		f.hold(`C:\Seq\x4`)
	}})
	r.untilContains("50.0KB")
	r.press("t")
	r.untilIdle()
	if !strings.Contains(r.view(), "x1") || strings.Contains(r.view(), `x2\f`) {
		t.Errorf("t switched the view while the measurement runs:\n%s", r.view())
	}
	if !strings.Contains(r.view(), "scanning") {
		t.Errorf("the folder view was left while the measurement runs")
	}
}

// ---------------------------------------------------------------------------
// Rescan

func TestExplorerRMeasuresAgainAndShowsNewValues(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.press("space") // marks alpha
	before := r.fs.readCount(`C:\Data`)
	r.fs.setSize(`C:\Data\alpha\a1.bin`, tstGiB)
	r.press("r")
	r.until("the new total", func(v string) bool {
		return strings.Contains(v, tstPct(4*tstGiB, 4*tstGiB+2*tstGiB+512*tstMiB+4*tstKiB))
	})
	r.untilIdle()
	if got := r.fs.readCount(`C:\Data`); got <= before {
		t.Errorf("r did not measure again (%d reads, was %d)", got, before)
	}
	if row := tstRowOf(r.view(), "alpha"); !strings.Contains(row, "4.0GB") {
		t.Errorf("row of alpha = %q, want the new size 4.0GB", row)
	}
	if sp := tstSpecial(r.view(), tstSimpleNames); len(sp) != 1 {
		t.Errorf("after r the rows %v differ from the rest, want only the cursor row: the mark was not cleared", sp)
	}
}

func TestExplorerRInTheOverviewReadsTheDrivesAndMeasuresHomeAgain(t *testing.T) {
	r := tstNewRig(t, "", tstOverviewOpts(nil))
	r.untilContains("40.0%")
	drives, home := r.fs.driveReads(), r.fs.readCount(`C:\Users\Example`)
	r.fs.drives[1].Free = 50 * tstGiB
	r.press("r")
	r.until("the new drive size", func(v string) bool { return strings.Contains(v, "50.0GB") })
	r.untilIdle()
	if got := r.fs.driveReads(); got <= drives {
		t.Errorf("the drives were not read again (%d reads, was %d)", got, drives)
	}
	if got := r.fs.readCount(`C:\Users\Example`); got <= home {
		t.Errorf("Home was not measured again (%d reads, was %d)", got, home)
	}
}

// ---------------------------------------------------------------------------
// Selection

func TestExplorerSpaceMarksAndUnmarksTheRowUnderTheCursor(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	plain := tstPrefixes(r.view(), tstSimpleNames)
	r.press("space")
	marked := tstPrefixes(r.view(), tstSimpleNames)
	if marked["alpha"] == plain["alpha"] {
		t.Fatalf("the marked row looks like the unmarked one (prefix %q)", marked["alpha"])
	}
	r.press("down")
	if sp := tstSpecial(r.view(), tstSimpleNames); !tstSameStrings(sp, []string{"alpha", "beta"}) {
		t.Errorf("rows that differ from the rest: %v, want the marked alpha and the cursor on beta", sp)
	}
	r.press("up", "space")
	if got := tstPrefixes(r.view(), tstSimpleNames)["alpha"]; got != plain["alpha"] {
		t.Errorf("after the second Space the prefix is %q, want the unmarked %q", got, plain["alpha"])
	}
}

func TestExplorerNavigationClearsTheMarks(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	plain := tstPrefixes(r.view(), tstSimpleNames)["beta"]
	r.goTo("beta", tstSimpleNames)
	r.press("space")
	r.press("home", "enter") // into alpha
	r.until("alpha", func(v string) bool { return strings.Contains(v, `C:\Data\alpha`) && strings.Contains(v, "60.0%") })
	r.press("esc")
	r.until("the parent", func(v string) bool { return strings.Contains(v, "gamma") && !strings.Contains(v, `C:\Data\alpha`) })
	r.press("home", "down") // the cursor on beta
	if got := tstPrefixes(r.view(), tstSimpleNames)["beta"]; got == "" || strings.Contains(got, "*") {
		t.Errorf("the mark of beta survived the navigation (prefix %q, plain row %q)", got, plain)
	}
	if sp := tstSpecial(r.view(), tstSimpleNames); len(sp) != 1 {
		t.Errorf("rows that differ: %v, want only the cursor", sp)
	}
}

func TestExplorerSpaceReportsCountAndSumOfTheMarkedRows(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.press("space", "down", "space") // alpha 5 GiB + beta 2 GiB
	view := r.view()
	if !strings.Contains(view, "7.0GB") {
		t.Errorf("the sum of the marked rows (7.0GB) is not shown:\n%s", view)
	}
	if !strings.Contains(view, "2") {
		t.Errorf("the number of marked rows is not shown")
	}
}

func TestExplorerSumOfMarkedRowsGetsAPlusWhenNotAllAreComplete(t *testing.T) {
	r := tstNewRig(t, `C:\M`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		f.file(`C:\M\big\f`, 3*tstKiB)
		f.file(`C:\M\part\f`, 2048)
		f.failDir(`C:\M\part\locked`, errTstAccess)
	}})
	names := []string{"big", "part"}
	r.until("the rows", func(v string) bool { return strings.Contains(v, "2.0KB+") && !strings.Contains(v, "scanning") })
	r.untilIdle()
	r.goTo("big", names)
	r.press("space", "down", "space") // 3.0KB + 2.0KB+
	if !strings.Contains(r.view(), "5.0KB+") {
		t.Errorf("the sum 5.0KB+ is not shown:\n%s", r.view())
	}
}

func TestExplorerUnavailableRowsCannotBeMarked(t *testing.T) {
	r := tstNewRig(t, `C:\M`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		f.file(`C:\M\ok\f`, tstKiB)
		f.failDir(`C:\M\locked`, errTstAccess)
	}})
	names := []string{"ok", "locked"}
	r.until("the rows", func(v string) bool { return strings.Contains(v, "not measured") && !strings.Contains(v, "scanning") })
	r.untilIdle()
	r.goTo("locked", names)
	before := tstPrefixes(r.view(), names)["locked"]
	r.press("space")
	if got := tstPrefixes(r.view(), names)["locked"]; got != before {
		t.Errorf("an unavailable row was marked (prefix %q, was %q)", got, before)
	}
}

func TestExplorerSpaceDeleteAndTHaveNoEffectWhileTheMeasurementRuns(t *testing.T) {
	r := tstNewRig(t, `C:\Seq`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		tstSeqTree(f)
		f.hold(`C:\Seq\x2`)
		f.hold(`C:\Seq\x3`)
		f.hold(`C:\Seq\x4`)
	}})
	r.until("x1 measured and the others listed", func(v string) bool {
		return tstRowHas(v, "x1", "10.0KB") && strings.Contains(v, "x4")
	})
	r.press("home")
	before := tstPrefixes(r.view(), tstSeqNames)
	r.press("space")
	if got := tstPrefixes(r.view(), tstSeqNames); !reflect.DeepEqual(got, before) {
		t.Errorf("Space marked a row during the measurement (prefixes %q, were %q)", got, before)
	}
	r.press("t")
	r.press("delete")
	r.untilIdle()
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Errorf("the recycler was called during the measurement: %q", calls)
	}
	if !strings.Contains(r.view(), "scanning") {
		t.Errorf("t switched the view during the measurement")
	}
	// Enter still works: it opens x1 (if Delete had opened a dialog, Enter would have confirmed it)
	r.press("enter")
	r.until("the folder x1", func(v string) bool { return strings.Contains(v, `C:\Seq\x1`) })
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Errorf("the recycler was called: %q", calls)
	}
}

func TestExplorerSpaceAndDeleteHaveNoEffectInTheOverview(t *testing.T) {
	r := tstNewRig(t, "", tstOverviewOpts(nil))
	r.untilContains("40.0%")
	r.press("down", "space", "delete", "enter")
	r.untilIdle()
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Errorf("something was recycled from the overview: %q", calls)
	}
	if got := tstReadLog(t, r.logFile); got != "" {
		t.Errorf("the overview wrote to the log: %q", got)
	}
}

// ---------------------------------------------------------------------------
// Quit and ignored keys

func TestExplorerQuitKeysEndTheProgramInEveryState(t *testing.T) {
	states := map[string]func(t *testing.T) *tstRig{
		"folder view": func(t *testing.T) *tstRig { return tstOpenSimple(t, tstRigOpts{}) },
		"largest files": func(t *testing.T) *tstRig {
			r := tstOpenSimple(t, tstRigOpts{})
			r.press("t")
			r.untilContains(`d1.bin`)
			return r
		},
		"overview": func(t *testing.T) *tstRig {
			r := tstNewRig(t, "", tstOverviewOpts(nil))
			r.untilContains("40.0%")
			return r
		},
		"measuring": func(t *testing.T) *tstRig {
			r := tstNewRig(t, `C:\Seq`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
				tstSeqTree(f)
				f.hold(`C:\Seq\x4`)
			}})
			r.untilContains("50.0KB")
			return r
		},
		"read error": func(t *testing.T) *tstRig {
			r := tstNewRig(t, `C:\Bad`, tstRigOpts{noTree: true, setup: func(f *fakeFS) { f.failDir(`C:\Bad`, errTstBoom) }})
			r.untilContains(errTstBoom.Error())
			return r
		},
		"marked": func(t *testing.T) *tstRig {
			r := tstOpenSimple(t, tstRigOpts{})
			r.press("space")
			return r
		},
	}
	for name, open := range states {
		for _, key := range []string{"q", "Q", "ctrl+c"} {
			r := open(t)
			r.press(key)
			if !r.waitQuit() {
				t.Errorf("%s: the key %s did not end the program", name, key)
			}
		}
	}
}

func TestExplorerIgnoresKeysThatAreNotBound(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	before := tstSpecial(r.view(), tstSimpleNames)
	reads := r.fs.readTotal()
	for _, k := range []string{"h", "j", "k", "l", "o", "f", "p", "/", "s", "x", "y", "n", "1", "f9"} {
		r.press(k)
	}
	r.untilIdle()
	if r.p.quit {
		t.Errorf("an unbound key ended the program")
	}
	if got := tstSpecial(r.view(), tstSimpleNames); !tstSameStrings(got, before) {
		t.Errorf("unbound keys moved the cursor or marked a row: %v, was %v", got, before)
	}
	if got := r.fs.readTotal(); got != reads {
		t.Errorf("unbound keys caused %d reads", got-reads)
	}
	if calls := r.rec.recorded(); len(calls) != 0 {
		t.Errorf("unbound keys recycled: %q", calls)
	}
}

func TestExplorerLettersWorkInUpperCaseToo(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.press("T")
	r.until("the file list", func(v string) bool { return strings.Contains(v, `C:\Data\alpha\deep\d1.bin`) })
	r.press("T")
	r.until("the folder view", func(v string) bool { return strings.Contains(v, "notes.txt") })
	before := r.fs.readCount(`C:\Data`)
	r.press("R")
	r.until("a new measurement", func(v string) bool { return r.fs.readCount(`C:\Data`) > before })
}
