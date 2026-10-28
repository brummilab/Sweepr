package main

// What the display shows: rows, size texts, percentages, markers, the
// overview, the layout limits and colour. Everything is read from View().

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func tstSeqTree(f *fakeFS) {
	f.file(`C:\Seq\x1\f`, 10*tstKiB)
	f.file(`C:\Seq\x2\f`, 50*tstKiB)
	f.file(`C:\Seq\x3\f`, 30*tstKiB)
	f.file(`C:\Seq\x4\f`, 5*tstKiB)
}

var tstSeqNames = []string{"x1", "x2", "x3", "x4"}

// tstManyTree has 60 folders item000 to item059 with falling sizes.
func tstManyTree(f *fakeFS) []string {
	var names []string
	for i := 0; i < 60; i++ {
		n := fmt.Sprintf("item%03d", i)
		names = append(names, n)
		f.file(fmt.Sprintf(`C:\Many\%s\f`, n), int64(60-i)*10*tstKiB)
	}
	return names
}

func tstAssertFits(t *testing.T, view string, w, h int) {
	t.Helper()
	lines := strings.Split(view, "\n")
	if len(lines) > h {
		t.Errorf("%dx%d: the view has %d lines, want at most %d", w, h, len(lines), h)
	}
	for i, l := range lines {
		if got := ansi.StringWidth(l); got > w {
			t.Errorf("%dx%d: line %d is %d cells wide: %q", w, h, i, got, l)
		}
	}
}

// ---------------------------------------------------------------------------
// Rows

func TestExplorerShowsNameSizeAndPercentOfEveryRowInSizeOrder(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	view := r.view()
	want := map[string][2]string{
		"alpha":     {"5.0GB", tstPct(5*tstGiB, tstSimpleTotal)},
		"beta":      {"2.0GB", tstPct(2*tstGiB, tstSimpleTotal)},
		"gamma":     {"512.0MB", tstPct(512*tstMiB, tstSimpleTotal)},
		"notes.txt": {"4.0KB", tstPct(4*tstKiB, tstSimpleTotal)},
	}
	for name, w := range want {
		row := tstRowOf(view, name)
		if row == "" {
			t.Errorf("no row for %s:\n%s", name, view)
			continue
		}
		if !strings.Contains(row, w[0]) || !strings.Contains(row, w[1]) {
			t.Errorf("row of %s = %q, want the size %s and the percent %s", name, row, w[0], w[1])
		}
	}
	if got := tstRowNames(view, tstSimpleNames); !tstSameStrings(got, tstSimpleNames) {
		t.Errorf("rows in the order %v, want %v", got, tstSimpleNames)
	}
}

func TestExplorerHeaderShowsTheFullPathAndTheTotal(t *testing.T) {
	long := `C:\Data\` + strings.Repeat("deeper-folder-", 3) + `end`
	r := tstNewRig(t, long, tstRigOpts{width: 120, setup: func(f *fakeFS) { f.file(long+`\f.bin`, 3*tstGiB) }})
	r.untilContains("3.0GB")
	r.untilIdle()
	view := r.view()
	if !strings.Contains(view, long) {
		t.Errorf("the full path %s is not in the view:\n%s", long, view)
	}
	if !strings.Contains(view, "3.0GB") {
		t.Errorf("the total is not in the view")
	}
}

func TestExplorerHeaderTotalGetsAPlusWhenTheMeasurementIsPartial(t *testing.T) {
	r := tstNewRig(t, `C:\Part`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		f.file(`C:\Part\a\f`, 3*tstMiB)
		f.failDir(`C:\Part\a\locked`, errTstAccess)
	}})
	r.untilContains("3.0MB+")
}

func TestExplorerShowsCountersWhileTheMeasurementRuns(t *testing.T) {
	r := tstNewRig(t, `C:\Live`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		for i := 0; i < 137; i++ {
			f.file(fmt.Sprintf(`C:\Live\a\f%03d`, i), tstKiB)
		}
		f.file(`C:\Live\b\slow`, 1)
		f.hold(`C:\Live\b`)
	}})
	r.until("the counters of the finished part", func(v string) bool {
		return strings.Contains(v, "137.0KB") && regexp.MustCompile(`\b137\b`).MatchString(v)
	})
	if strings.Contains(r.view(), "%") {
		t.Errorf("a percentage is shown while the measurement runs:\n%s", r.view())
	}
	r.fs.releaseAll()
	r.until("the end of the measurement", func(v string) bool { return strings.Contains(v, "%") })
}

func TestExplorerShowsFinishedChildrenInArrivalOrderAndTheOthersAsScanning(t *testing.T) {
	r := tstNewRig(t, `C:\Seq`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		tstSeqTree(f)
		f.hold(`C:\Seq\x2`)
		f.hold(`C:\Seq\x3`)
		f.hold(`C:\Seq\x4`)
	}})
	r.until("x1 measured and the others listed", func(v string) bool {
		return tstRowHas(v, "x1", "10.0KB") && strings.Contains(v, "x4")
	})
	view := r.view()
	for _, n := range []string{"x2", "x3", "x4"} {
		if row := tstRowOf(view, n); !strings.Contains(row, "scanning") {
			t.Errorf("row of %s = %q, want the text scanning", n, row)
		}
	}
	if strings.Contains(tstRowOf(view, "x1"), "scanning") {
		t.Errorf("the finished child x1 is shown as scanning")
	}
	if got := tstRowNames(view, tstSeqNames); len(got) == 0 || got[0] != "x1" {
		t.Errorf("rows = %v, want the finished child first", got)
	}

	r.fs.release(`C:\Seq\x2`)
	r.until("x2 measured", func(v string) bool { return tstRowHas(v, "x2", "50.0KB") })
	if got := tstRowNames(r.view(), tstSeqNames); len(got) < 2 || !tstSameStrings(got[:2], []string{"x1", "x2"}) {
		t.Errorf("rows = %v, want x1 then x2 (arrival order, unsorted)", got)
	}
	r.fs.release(`C:\Seq\x3`)
	r.until("x3 measured", func(v string) bool { return tstRowHas(v, "x3", "30.0KB") })
	view = r.view()
	if got := tstRowNames(view, tstSeqNames); !tstSameStrings(got, []string{"x1", "x2", "x3", "x4"}) {
		t.Errorf("rows = %v, want arrival order x1 x2 x3 and the unfinished x4 last", got)
	}
	if !strings.Contains(tstRowOf(view, "x4"), "scanning") {
		t.Errorf("x4 is not shown as scanning")
	}
	for _, n := range tstSeqNames {
		if strings.Contains(tstRowOf(view, n), "%") {
			t.Errorf("row of %s shows a percentage before the measurement is complete", n)
		}
	}
	r.press("home", "down") // the cursor goes to the second row, x2, while x4 is still running
	if got := r.cursor(tstSeqNames); got != "x2" {
		t.Fatalf("cursor on %q, want x2", got)
	}

	r.fs.release(`C:\Seq\x4`)
	r.untilContains(tstPct(50*tstKiB, 95*tstKiB))
	r.untilIdle()
	view = r.view()
	if got := tstRowNames(view, tstSeqNames); !tstSameStrings(got, []string{"x2", "x3", "x1", "x4"}) {
		t.Errorf("rows = %v, want the sorted order x2 x3 x1 x4 after the measurement", got)
	}
	if got := r.cursor(tstSeqNames); got != "x2" {
		t.Errorf("cursor on %q after sorting, want it to stay on x2 (by path)", got)
	}
}

func TestExplorerNeverShowsNotMeasuredAsZero(t *testing.T) {
	r := tstNewRig(t, `C:\M`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		f.file(`C:\M\ok\f`, tstKiB)
		f.file(`C:\M\part\f`, 2048)
		f.failDir(`C:\M\part\locked`, errTstAccess)
		f.dir(`C:\M\onlyfail`)
		f.failDir(`C:\M\onlyfail\locked`, errTstAccess)
		f.failDir(`C:\M\gone`, errTstAccess)
	}})
	names := []string{"ok", "part", "onlyfail", "gone"}
	r.until("all rows measured", func(v string) bool {
		return strings.Contains(v, "2.0KB+") && !strings.Contains(v, "scanning")
	})
	r.untilIdle()
	view := r.view()
	if row := tstRowOf(view, "gone"); !strings.Contains(row, "not measured") {
		t.Errorf("unavailable row = %q, want not measured", row)
	}
	if row := tstRowOf(view, "onlyfail"); !strings.Contains(row, "not measured") {
		t.Errorf("partial row of size 0 = %q, want not measured", row)
	}
	if row := tstRowOf(view, "part"); !strings.Contains(row, "2.0KB+") {
		t.Errorf("partial row = %q, want 2.0KB+", row)
	}
	if row := tstRowOf(view, "ok"); !strings.Contains(row, "1.0KB") || strings.Contains(row, "+") {
		t.Errorf("complete row = %q, want 1.0KB without a plus", row)
	}
	for _, n := range names {
		row := tstRowOf(view, n)
		if regexp.MustCompile(`\b0B\b`).MatchString(row) || strings.Contains(row, "%") {
			t.Errorf("row of %s = %q shows a zero or a percentage although a part is not measured", n, row)
		}
	}
}

func TestExplorerShowsAReadableEmptyFolderAsZeroBytesAndPercentages(t *testing.T) {
	r := tstNewRig(t, `C:\Z`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		f.dir(`C:\Z\empty1`)
		f.file(`C:\Z\file.bin`, tstKiB)
	}})
	r.untilContains("100.0%")
	view := r.view()
	if row := tstRowOf(view, "empty1"); !strings.Contains(row, "0B") || !strings.Contains(row, "0.0%") {
		t.Errorf("row of the empty folder = %q, want 0B and 0.0%%", row)
	}
}

func TestExplorerShowsNoPercentagesWhenTheTotalIsZero(t *testing.T) {
	r := tstNewRig(t, `C:\Z0`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		f.dir(`C:\Z0\e1`)
		f.dir(`C:\Z0\e2`)
	}})
	r.until("rows", func(v string) bool {
		return strings.Contains(v, "e1") && strings.Contains(v, "e2") && !strings.Contains(v, "scanning")
	})
	r.untilIdle()
	for _, n := range []string{"e1", "e2"} {
		row := tstRowOf(r.view(), n)
		if !strings.Contains(row, "0B") || strings.Contains(row, "%") {
			t.Errorf("row of %s = %q, want 0B without a percentage", n, row)
		}
	}
}

func TestExplorerMarksLinksAndCloudEntries(t *testing.T) {
	r := tstNewRig(t, `C:\K`, tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		f.file(`C:\K\plain\f`, tstKiB)
		f.link(`C:\K\lnk`, `D:\target`)
		f.fileLink(`C:\K\fsym`)
		f.file(`C:\K\cd\local.bin`, 100)
		f.cloudFile(`C:\K\cd\online.bin`, tstGiB, true)
		f.cloudFile(`C:\K\ph\kept.bin`, 5*tstMiB, false)
	}})
	r.until("all rows", func(v string) bool {
		return strings.Contains(v, "[cloud 1.0GB online]") && !strings.Contains(v, "scanning")
	})
	r.untilIdle()
	view := r.view()
	for _, n := range []string{"lnk", "fsym"} {
		if row := tstRowOf(view, n); !strings.Contains(row, "[link]") {
			t.Errorf("row of %s = %q, want [link]", n, row)
		}
	}
	if row := tstRowOf(view, "cd"); !strings.Contains(row, "100B") || !strings.Contains(row, "[cloud 1.0GB online]") {
		t.Errorf("row of cd = %q, want 100B and [cloud 1.0GB online]", row)
	}
	if row := tstRowOf(view, "ph"); !strings.Contains(row, "[cloud]") || strings.Contains(row, "online]") || !strings.Contains(row, "5.0MB") {
		t.Errorf("row of ph = %q, want 5.0MB and [cloud] without an online size", row)
	}
	if row := tstRowOf(view, "plain"); strings.Contains(row, "[link]") || strings.Contains(row, "[cloud") {
		t.Errorf("row of plain = %q, want no marker", row)
	}
}

func TestExplorerShowsAHintForAnEmptyFolder(t *testing.T) {
	r := tstNewRig(t, `C:\Vacant`, tstRigOpts{noTree: true, setup: func(f *fakeFS) { f.dir(`C:\Vacant`) }})
	r.until("the hint", func(v string) bool { return regexp.MustCompile(`(?i)\bempty\b`).MatchString(v) })
}

func TestExplorerShowsAHintWhenThereAreNoLargeFiles(t *testing.T) {
	r := tstNewRig(t, `C:\Small`, tstRigOpts{noTree: true, setup: func(f *fakeFS) { f.file(`C:\Small\a.txt`, 10) }})
	r.untilContains("a.txt")
	r.until("the end of the measurement", func(v string) bool { return strings.Contains(v, "%") })
	r.press("t")
	r.until("the hint", func(v string) bool { return regexp.MustCompile(`(?i)\b(no|none|nothing|empty)\b`).MatchString(v) })
	if strings.Contains(r.view(), "a.txt") {
		t.Errorf("the small file is listed as a large file")
	}
}

func TestExplorerFooterNamesTheKeys(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	lower := strings.ToLower(r.view())
	for _, k := range []string{"enter", "space", "del", "esc"} {
		if !strings.Contains(lower, k) {
			t.Errorf("the view does not name the key %q:\n%s", k, r.view())
		}
	}
}

func TestExplorerShowsNoEmoji(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	check := func(label string) {
		for _, c := range r.view() {
			if (c >= 0x1F000 && c <= 0x1FAFF) || (c >= 0x2600 && c <= 0x27BF) || c == 0xFE0F {
				t.Errorf("%s: the view contains the emoji-range character %U", label, c)
			}
		}
	}
	check("folder view")
	r.press("t")
	check("largest files view")
}

// ---------------------------------------------------------------------------
// Overview

func tstOverviewOpts(setup func(f *fakeFS)) tstRigOpts {
	return tstRigOpts{noTree: true, setup: func(f *fakeFS) {
		f.file(`C:\Users\Example\Downloads\f.bin`, tstKiB)
		f.drives = []Drive{
			{Root: `D:\`, Label: "Data", Total: 500 * tstGiB, Free: 100 * tstGiB},
			{Root: `C:\`, Label: "System", Total: 100 * tstGiB, Free: 60 * tstGiB},
		}
		if setup != nil {
			setup(f)
		}
	}}
}

func tstDriveRow(view, root string) string {
	for _, l := range strings.Split(view, "\n") {
		if strings.Contains(l, root) && !strings.Contains(l, `Users\Example`) {
			return l
		}
	}
	return ""
}

func TestExplorerOverviewShowsHomeAndDrivesWithVolumeSizes(t *testing.T) {
	r := tstNewRig(t, "", tstOverviewOpts(nil))
	r.untilContains("40.0%")
	view := r.view()
	if row := tstRowOf(view, `C:\Users\Example`); !strings.Contains(row, "1.0KB") {
		t.Errorf("Home row = %q, want the measured 1.0KB", row)
	}
	c, d := tstDriveRow(view, `C:\`), tstDriveRow(view, `D:\`)
	for _, w := range []string{"40.0GB", "100.0GB", "60.0GB", "40.0%"} {
		if !strings.Contains(c, w) {
			t.Errorf("row of C:\\ = %q, want %s", c, w)
		}
	}
	for _, w := range []string{"400.0GB", "500.0GB", "100.0GB", "80.0%"} {
		if !strings.Contains(d, w) {
			t.Errorf("row of D:\\ = %q, want %s", d, w)
		}
	}
	hi, ci, di := strings.Index(view, `C:\Users\Example`), strings.Index(view, c), strings.Index(view, d)
	if !(hi < ci && ci < di) {
		t.Errorf("the rows are not in the order Home, C:\\, D:\\:\n%s", view)
	}
}

func TestExplorerOverviewShowsHomeAsScanningAndNoPercentUntilItIsMeasured(t *testing.T) {
	r := tstNewRig(t, "", tstOverviewOpts(func(f *fakeFS) { f.hold(`C:\Users\Example`) }))
	r.until("the drives", func(v string) bool { return strings.Contains(v, "40.0GB") })
	view := r.view()
	if row := tstRowOf(view, `C:\Users\Example`); !strings.Contains(row, "scanning") {
		t.Errorf("Home row = %q, want the text scanning", row)
	}
	if strings.Contains(tstDriveRow(view, `C:\`), "%") || strings.Contains(tstDriveRow(view, `D:\`), "%") {
		t.Errorf("a percentage is shown before every row is finished:\n%s", view)
	}
	r.fs.releaseAll()
	r.untilContains("40.0%")
}

func TestExplorerOverviewDriveThatCannotBeReadIsNotMeasured(t *testing.T) {
	r := tstNewRig(t, "", tstOverviewOpts(func(f *fakeFS) { f.drives[0].Err = errTstBoom }))
	r.until("the home row", func(v string) bool { return strings.Contains(v, "1.0KB") })
	r.untilIdle()
	view := r.view()
	if row := tstDriveRow(view, `D:\`); !strings.Contains(row, "not measured") {
		t.Errorf("row of D:\\ = %q, want not measured", row)
	}
	if strings.Contains(view, "%") {
		t.Errorf("a percentage is shown although a row is not measured:\n%s", view)
	}
}

func TestExplorerOverviewHasNoRowForAMissingHomeFolder(t *testing.T) {
	o := tstOverviewOpts(nil)
	o.env = map[string]string{"USERPROFILE": `C:\Users\Nobody`}
	r := tstNewRig(t, "", o)
	r.until("the drives", func(v string) bool { return strings.Contains(v, "40.0GB") })
	r.untilIdle()
	if strings.Contains(r.view(), `Users\Nobody`) || strings.Contains(r.view(), `Users\Example`) {
		t.Errorf("a row for a Home folder that does not exist:\n%s", r.view())
	}
}

func TestExplorerOverviewDoesNotStartWithAFolderMeasurementOfADrive(t *testing.T) {
	r := tstNewRig(t, "", tstOverviewOpts(nil))
	r.untilContains("40.0%")
	if n := r.fs.readCount(`C:\`) + r.fs.readCount(`D:\`); n != 0 {
		t.Errorf("the drive roots were read %d times for the overview", n)
	}
}

// ---------------------------------------------------------------------------
// Layout

func tstWideTree(f *fakeFS) []string {
	names := []string{
		strings.Repeat("n", 60),
		strings.Repeat("长", 30),
		"短い名前と長い名前のフォルダ",
		"Übung-ñandú-" + strings.Repeat("é", 20),
		"a\u0301" + strings.Repeat("b\u0301", 20), // combining marks
	}
	for i, n := range names {
		f.file(`C:\Wide\`+n+`\f`, int64(10-i)*tstGiB)
	}
	for i := 0; i < 30; i++ {
		f.file(fmt.Sprintf(`C:\Wide\row%02d\f`, i), int64(i+1)*tstKiB)
	}
	return names
}

func TestExplorerNeverExceedsTheWindowInWidthOrHeight(t *testing.T) {
	r := tstNewRig(t, `C:\Wide`, tstRigOpts{noTree: true, width: 80, height: 24, setup: func(f *fakeFS) { tstWideTree(f) }})
	r.until("the end of the measurement", func(v string) bool { return strings.Contains(v, "%") })
	r.untilIdle()
	for _, sz := range [][2]int{{80, 24}, {40, 12}, {120, 40}, {20, 8}, {80, 6}, {10, 4}, {200, 5}} {
		r.resize(sz[0], sz[1])
		tstAssertFits(t, r.view(), sz[0], sz[1])
		r.press("t")
		tstAssertFits(t, r.view(), sz[0], sz[1])
		r.press("t")
	}
}

func TestExplorerFallsBackTo80By24WhenTheSizeIsUnknown(t *testing.T) {
	r := tstNewRig(t, `C:\Wide`, tstRigOpts{noTree: true, width: -1, setup: func(f *fakeFS) { tstWideTree(f) }})
	r.until("the first rows", func(v string) bool { return strings.Contains(v, "row29") || strings.Contains(v, "%") })
	tstAssertFits(t, r.view(), 80, 24)
	r.resize(0, 0)
	tstAssertFits(t, r.view(), 80, 24)
}

func TestExplorerShortensLongNamesWithAnEllipsisAndKeepsTheSizeReadable(t *testing.T) {
	name := strings.Repeat("n", 60)
	r := tstNewRig(t, `C:\Wide`, tstRigOpts{noTree: true, width: 40, height: 20, setup: func(f *fakeFS) {
		f.file(`C:\Wide\`+name+`\f`, 2*tstGiB)
	}})
	r.untilContains("2.0GB")
	r.untilIdle()
	view := r.view()
	row := ""
	for _, l := range strings.Split(view, "\n") {
		if strings.Contains(l, "nnnnnnnn") {
			row = l
		}
	}
	if row == "" {
		t.Fatalf("no row for the long name:\n%s", view)
	}
	if !strings.Contains(row, "…") || !strings.Contains(row, "2.0GB") {
		t.Errorf("row = %q, want the name cut with … and the size 2.0GB complete", row)
	}
	tstAssertFits(t, view, 40, 20)
}

func TestExplorerMeasuresWideCharactersInCells(t *testing.T) {
	name := strings.Repeat("长", 30) // 60 cells
	r := tstNewRig(t, `C:\Wide`, tstRigOpts{noTree: true, width: 40, height: 20, setup: func(f *fakeFS) {
		f.file(`C:\Wide\`+name+`\f`, 2*tstGiB)
	}})
	r.untilContains("2.0GB")
	r.untilIdle()
	tstAssertFits(t, r.view(), 40, 20)
	if !strings.Contains(r.view(), "2.0GB") {
		t.Errorf("the size is cut off the row of a wide-character name:\n%s", r.view())
	}
}

func TestExplorerKeepsTheCursorVisibleWhileMovingAndResizing(t *testing.T) {
	var names []string
	r := tstNewRig(t, `C:\Many`, tstRigOpts{noTree: true, width: 100, height: 10, setup: func(f *fakeFS) { names = tstManyTree(f) }})
	r.until("the end of the measurement", func(v string) bool { return strings.Contains(v, "%") })
	r.untilIdle()
	r.press("home")
	shown := len(r.rows(names))
	if shown < 1 || shown >= len(names) {
		t.Fatalf("%d rows shown of %d: the list must scroll", shown, len(names))
	}
	if got := r.cursor(names); got != names[0] {
		t.Fatalf("cursor on %q, want %s", got, names[0])
	}
	for i := 0; i < 30; i++ {
		r.press("down")
	}
	if got := r.cursor(names); got != names[30] {
		t.Errorf("after 30 steps down the cursor is on %q (visible rows %v), want %s", got, r.rows(names), names[30])
	}
	r.press("end")
	if got := r.cursor(names); got != names[59] {
		t.Errorf("after End the cursor is on %q, want %s", got, names[59])
	}
	r.press("home")
	if got := r.cursor(names); got != names[0] {
		t.Errorf("after Home the cursor is on %q, want %s", got, names[0])
	}
	r.press("pgdown")
	if got := r.cursor(names); got != names[shown] {
		t.Errorf("after PgDn the cursor is on %q, want %s (one page of %d rows)", got, names[shown], shown)
	}
	r.press("pgup")
	if got := r.cursor(names); got != names[0] {
		t.Errorf("after PgUp the cursor is on %q, want %s", got, names[0])
	}
	r.press("home")
	for i := 0; i < 40; i++ {
		r.press("down")
	}
	r.resize(100, 6)
	if got := r.cursor(names); got != names[40] {
		t.Errorf("after shrinking the window the cursor is on %q (visible %v), want %s", got, r.rows(names), names[40])
	}
	r.resize(60, 30)
	if got := r.cursor(names); got != names[40] {
		t.Errorf("after growing the window the cursor is on %q, want %s", got, names[40])
	}
}

// ---------------------------------------------------------------------------
// Colour

var tstSGRRe = regexp.MustCompile("\x1b\\[([0-9;:]*)m")

func tstColorParams(raw string) []string {
	var bad []string
	for _, m := range tstSGRRe.FindAllStringSubmatch(raw, -1) {
		for _, p := range strings.FieldsFunc(m[1], func(r rune) bool { return r == ';' || r == ':' }) {
			n, err := strconv.Atoi(p)
			if err != nil {
				continue
			}
			if (n >= 30 && n <= 38) || (n >= 40 && n <= 48) || (n >= 90 && n <= 97) || (n >= 100 && n <= 107) {
				bad = append(bad, m[0])
				break
			}
		}
	}
	return bad
}

func TestExplorerEmitsNoColourWhenNoColorIsSet(t *testing.T) {
	r := tstNewRig(t, `C:\Data`, tstRigOpts{env: map[string]string{"NO_COLOR": "1"}})
	r.untilContains(tstPct(5*tstGiB, tstSimpleTotal))
	r.untilIdle()
	check := func(label string) {
		if bad := tstColorParams(r.rawView()); len(bad) > 0 {
			t.Errorf("%s: colour instructions with NO_COLOR set: %q", label, bad)
		}
	}
	check("folder view")
	r.press("down", "space")
	check("marked row")
	r.press("t")
	check("largest files view")
	r.press("t", "delete")
	check("dialog")
}

func TestExplorerCursorAndMarksNeedNoColour(t *testing.T) {
	r := tstNewRig(t, `C:\Data`, tstRigOpts{env: map[string]string{"NO_COLOR": "1"}})
	r.untilContains(tstPct(5*tstGiB, tstSimpleTotal))
	r.untilIdle()
	r.press("home")
	if got := r.cursor(tstSimpleNames); got != "alpha" {
		t.Errorf("without colour the cursor row is not recognisable by a character: special rows %v", tstSpecial(r.view(), tstSimpleNames))
	}
	before := tstPrefixes(r.view(), tstSimpleNames)["alpha"]
	r.press("space")
	after := tstPrefixes(r.view(), tstSimpleNames)["alpha"]
	if before == after {
		t.Errorf("a marked row looks like an unmarked one without colour (prefix %q)", after)
	}
}
