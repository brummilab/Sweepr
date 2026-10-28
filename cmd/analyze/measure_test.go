package main

// The measurement (sizes, links, states, order, largest files, concurrency,
// cancellation, counters, cloud placeholders) over the artificial file system.

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Sizes

func TestMeasureSumsLogicalFileSizesOverTheWholeTree(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\f1`, 100)
	f.file(`C:\R\a\sub\f2`, 50)
	l := tstMeasure(t, f, `C:\R`)
	a := tstMustItem(t, l, "a")
	if a.Size != 150 {
		t.Errorf("a.Size = %d, want 150", a.Size)
	}
	if l.TotalSize != 150 {
		t.Errorf("TotalSize = %d, want 150", l.TotalSize)
	}
	if a.State != Complete {
		t.Errorf("a.State = %s, want complete", tstStateText(a.State))
	}
}

func TestMeasureFolderWithoutFilesHasSizeZeroAndIsComplete(t *testing.T) {
	f := newFakeFS()
	f.dir(`C:\R\empty\inner`)
	f.file(`C:\R\x`, 1)
	l := tstMeasure(t, f, `C:\R`)
	e := tstMustItem(t, l, "empty")
	if e.Size != 0 || e.State != Complete {
		t.Errorf("empty = {size %d, state %s}, want size 0, complete", e.Size, tstStateText(e.State))
	}
	if !e.IsDir {
		t.Errorf("empty.IsDir = false")
	}
}

func TestMeasureDoesNotSkipByFolderNameOrExtension(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\node_modules\p\index.js`, 10)
	f.file(`C:\R\.git\objects\pack.bin`, 20)
	f.file(`C:\R\build\out.bin`, 30)
	f.file(`C:\R\x.json`, 40)
	f.file(`C:\R\y.db`, 50)
	f.file(`C:\R\z.txt`, 60)
	f.file(`C:\R\System Volume Information\s.bin`, 70)
	l := tstMeasure(t, f, `C:\R`)
	want := map[string]int64{"node_modules": 10, ".git": 20, "build": 30, "x.json": 40, "y.db": 50, "z.txt": 60, "System Volume Information": 70}
	for name, size := range want {
		it, ok := tstItemByName(l, name)
		if !ok {
			t.Errorf("%s is not listed", name)
			continue
		}
		if it.Size != size {
			t.Errorf("%s.Size = %d, want %d", name, it.Size, size)
		}
	}
	if l.TotalSize != 280 {
		t.Errorf("TotalSize = %d, want 280", l.TotalSize)
	}
}

func TestMeasureCountsEveryNameOfASize(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\d\one`, 1000)
	f.file(`C:\R\d\two`, 1000) // a second name of the same data counts again
	l := tstMeasure(t, f, `C:\R`)
	if got := tstMustItem(t, l, "d").Size; got != 2000 {
		t.Errorf("d.Size = %d, want 2000", got)
	}
}

func TestMeasureListsOnlyTheDirectChildren(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\deep\f`, 1)
	f.file(`C:\R\b`, 2)
	l := tstMeasure(t, f, `C:\R`)
	names := tstItemNames(l.Items)
	if len(names) != 2 {
		t.Fatalf("items = %v, want only a and b", names)
	}
	for _, n := range names {
		if n != "a" && n != "b" {
			t.Errorf("unexpected item %q", n)
		}
	}
}

func TestMeasureItemsCarryNamePathAndKind(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\Data\sub\f`, 5)
	f.file(`C:\Data\file.txt`, 7)
	l := tstMeasure(t, f, `C:\Data`)
	sub, file := tstMustItem(t, l, "sub"), tstMustItem(t, l, "file.txt")
	if sub.Path != `C:\Data\sub` || !sub.IsDir || sub.IsLink {
		t.Errorf("sub = %+v", sub)
	}
	if file.Path != `C:\Data\file.txt` || file.IsDir || file.IsLink {
		t.Errorf("file = %+v", file)
	}
	if l.Root != `C:\Data` {
		t.Errorf("Root = %q, want C:\\Data", l.Root)
	}
}

func TestMeasureItemPathsOfADriveRootHaveNoDoubledBackslash(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\Data\f`, 5)
	l := tstMeasure(t, f, `C:\`)
	it := tstMustItem(t, l, "Data")
	if it.Path != `C:\Data` {
		t.Errorf("Path = %q, want C:\\Data", it.Path)
	}
}

func TestMeasureTotalFilesCountsFilesOnly(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a`, 1)
	f.file(`C:\R\sub\b`, 2)
	f.file(`C:\R\sub\c`, 3)
	f.dir(`C:\R\emptydir`)
	f.link(`C:\R\lnk`, `C:\Elsewhere`)
	f.file(`C:\Elsewhere\big`, 999)
	f.fileLink(`C:\R\symfile`)
	f.cloudFile(`C:\R\online.bin`, 4*tstMiB, true)
	l := tstMeasure(t, f, `C:\R`)
	if l.TotalFiles != 4 {
		t.Errorf("TotalFiles = %d, want 4 (links and folders do not count, online files do)", l.TotalFiles)
	}
	if l.TotalSize != 6 {
		t.Errorf("TotalSize = %d, want 6", l.TotalSize)
	}
}

// ---------------------------------------------------------------------------
// Links

func TestMeasureLinkIsListedWithSizeZeroAndNeverEntered(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\own.txt`, 5)
	f.link(`C:\R\link`, `D:\big`)
	f.file(`D:\big\huge.bin`, 50*tstGiB)
	l := tstMeasure(t, f, `C:\R`)
	lk := tstMustItem(t, l, "link")
	if !lk.IsLink || lk.Size != 0 || lk.OnlineSize != 0 || lk.Cloud {
		t.Errorf("link = %+v, want a link of size 0 without cloud content", lk)
	}
	if lk.State != Complete {
		t.Errorf("link.State = %s, want complete", tstStateText(lk.State))
	}
	if l.TotalSize != 5 || l.TotalFiles != 1 {
		t.Errorf("totals = %d bytes, %d files, want 5 and 1", l.TotalSize, l.TotalFiles)
	}
	if n := f.readCount(`D:\big`); n != 0 {
		t.Errorf("the link target was read %d times", n)
	}
	if n := f.readCount(`C:\R\link`); n != 0 {
		t.Errorf("the link itself was read %d times", n)
	}
	f.assertNoLinkFollowed(t)
}

func TestMeasureFileLinkIsAListedLinkOfSizeZero(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\own.txt`, 5)
	f.fileLink(`C:\R\sym`)
	f.setSize(`C:\R\sym`, 12345)
	l := tstMeasure(t, f, `C:\R`)
	sym := tstMustItem(t, l, "sym")
	if !sym.IsLink || sym.Size != 0 {
		t.Errorf("sym = %+v, want a link of size 0", sym)
	}
	if l.TotalSize != 5 || l.TotalFiles != 1 {
		t.Errorf("totals = %d bytes, %d files, want 5 and 1", l.TotalSize, l.TotalFiles)
	}
}

func TestMeasureLinkInsideASubfolderIsNotEnteredEither(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\f`, 10)
	f.link(`C:\R\a\inner`, `D:\elsewhere`)
	f.file(`D:\elsewhere\g`, 999)
	l := tstMeasure(t, f, `C:\R`)
	if got := tstMustItem(t, l, "a").Size; got != 10 {
		t.Errorf("a.Size = %d, want 10", got)
	}
	if n := f.readCount(`D:\elsewhere`); n != 0 {
		t.Errorf("the link target was read %d times", n)
	}
	f.assertNoLinkFollowed(t)
}

// ---------------------------------------------------------------------------
// States

func TestMeasureUnreadableSubfolderMakesTheParentPartialWithTheKnownSize(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\readable`, 10)
	f.failDir(`C:\R\a\locked`, errTstAccess)
	l := tstMeasure(t, f, `C:\R`)
	a := tstMustItem(t, l, "a")
	if a.State != Partial || a.Size != 10 {
		t.Errorf("a = {state %s, size %d}, want partial with 10", tstStateText(a.State), a.Size)
	}
}

func TestMeasureUnreadableChildFolderIsUnavailable(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\ok`, 1)
	f.failDir(`C:\R\b`, errTstAccess)
	l := tstMeasure(t, f, `C:\R`)
	if got := tstMustItem(t, l, "b").State; got != Unavailable {
		t.Errorf("b.State = %s, want unavailable", tstStateText(got))
	}
	if got := tstMustItem(t, l, "ok").State; got != Complete {
		t.Errorf("ok.State = %s, want complete", tstStateText(got))
	}
}

func TestMeasurePartialComesFromAnyDepth(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\b\c\f`, 7)
	f.failDir(`C:\R\a\b\c\d`, errTstBoom)
	l := tstMeasure(t, f, `C:\R`)
	a := tstMustItem(t, l, "a")
	if a.State != Partial || a.Size != 7 {
		t.Errorf("a = {state %s, size %d}, want partial with 7", tstStateText(a.State), a.Size)
	}
}

func TestMeasureAllReadErrorsCountTheSame(t *testing.T) {
	errs := map[string]error{
		"access denied":   errTstAccess,
		"vanished":        tstNotExist(`C:\R\locked`),
		"i/o error":       errors.New("the request could not be performed because of an I/O device error"),
		"timeout":         fmt.Errorf("read: %w", context.DeadlineExceeded),
		"plain error":     errTstBoom,
		"sharing problem": errors.New("the process cannot access the file because it is being used by another process"),
	}
	for name, e := range errs {
		f := newFakeFS()
		f.file(`C:\R\good\f`, 1)
		f.failDir(`C:\R\locked`, e)
		l := tstMeasure(t, f, `C:\R`)
		if got := tstMustItem(t, l, "locked").State; got != Unavailable {
			t.Errorf("%s: locked.State = %s, want unavailable", name, tstStateText(got))
		}
		if l.State != Partial {
			t.Errorf("%s: Listing.State = %s, want partial", name, tstStateText(l.State))
		}
	}
}

func TestMeasureListingStateIsCompleteWhenEveryEntryIsComplete(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\f`, 1)
	f.dir(`C:\R\empty`)
	f.link(`C:\R\l`, `D:\x`)
	l := tstMeasure(t, f, `C:\R`)
	if l.State != Complete {
		t.Errorf("Listing.State = %s, want complete", tstStateText(l.State))
	}
}

func TestMeasureListingStateIsPartialWhenOneEntryIsNotComplete(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\f`, 1)
	f.file(`C:\R\b\g`, 2)
	f.failDir(`C:\R\b\h`, errTstAccess)
	l := tstMeasure(t, f, `C:\R`)
	if l.State != Partial {
		t.Errorf("Listing.State = %s, want partial", tstStateText(l.State))
	}
	if l.TotalSize != 3 {
		t.Errorf("TotalSize = %d, want the known lower bound 3", l.TotalSize)
	}
}

func TestMeasureStateTextsAreTheNamesOfTheSpec(t *testing.T) {
	if tstStateText(Complete) != "complete" || tstStateText(Partial) != "partial" || tstStateText(Unavailable) != "unavailable" {
		t.Errorf("state texts: %q %q %q", tstStateText(Complete), tstStateText(Partial), tstStateText(Unavailable))
	}
}

func TestMeasureUnreadableRootIsAnError(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a`, 1)
	f.failDir(`C:\R`, errTstAccess)
	_, err := tstMeasureCtx(context.Background(), f, `C:\R`)
	if err == nil {
		t.Fatal("Measure returned no error for an unreadable root")
	}
	if !errors.Is(err, errTstAccess) {
		t.Errorf("err = %v, want it to wrap the read error", err)
	}
}

func TestMeasureMissingRootIsAnError(t *testing.T) {
	f := newFakeFS()
	f.dir(`C:\Other`)
	_, err := tstMeasureCtx(context.Background(), f, `C:\Nope`)
	if err == nil {
		t.Fatal("Measure returned no error for a missing root")
	}
}

func TestMeasureFailureOfOneSubfolderDoesNotStopItsSiblings(t *testing.T) {
	f := newFakeFS()
	for i := 0; i < 20; i++ {
		f.file(fmt.Sprintf(`C:\R\d%02d\f`, i), 10)
	}
	f.failDir(`C:\R\d07`, errTstBoom)
	f.failDir(`C:\R\d03`, errTstAccess)
	l := tstMeasure(t, f, `C:\R`)
	good := 0
	for _, it := range l.Items {
		if it.State == Complete && it.Size == 10 {
			good++
		}
	}
	if good != 18 {
		t.Errorf("%d siblings measured completely, want 18", good)
	}
}

// ---------------------------------------------------------------------------
// Reach

func TestMeasureNeverReadsOutsideTheRoot(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\Data\a\f`, 1)
	f.file(`C:\Data\b\sub\g`, 2)
	f.file(`C:\Data2\x`, 3)
	f.file(`C:\other\y`, 4)
	tstMeasure(t, f, `C:\Data`)
	for _, k := range f.readOrder() {
		if k != `c:\data` && !strings.HasPrefix(k, `c:\data\`) {
			t.Errorf("read %q, which is outside the root", k)
		}
	}
	if f.readCount(`C:\`) != 0 || f.readCount(`C:\Data2`) != 0 {
		t.Errorf("the parent or a sibling of the root was read")
	}
}

// ---------------------------------------------------------------------------
// Order

func TestMeasureOrdersBySizeThenByNameIgnoringCase(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\c`, 5)
	f.file(`C:\R\B`, 10)
	f.file(`C:\R\a`, 10)
	l := tstMeasure(t, f, `C:\R`)
	if got := tstItemNames(l.Items); !tstSameStrings(got, []string{"a", "B", "c"}) {
		t.Errorf("order = %v, want [a B c]", got)
	}
}

func TestMeasureBreaksRemainingTiesByTheNameAsString(t *testing.T) {
	f := newFakeFS()
	f.fileExact(`C:\R`, "a", 10)
	f.fileExact(`C:\R`, "b", 10)
	f.fileExact(`C:\R`, "A", 10)
	l := tstMeasure(t, f, `C:\R`)
	if got := tstItemNames(l.Items); !tstSameStrings(got, []string{"A", "a", "b"}) {
		t.Errorf("order = %v, want [A a b]", got)
	}
}

func TestMeasurePutsUnmeasuredEntriesLast(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\w`, 7000)
	f.file(`C:\R\x`, 5000)
	f.dir(`C:\R\e`) // readable and empty: measured, size 0
	f.failDir(`C:\R\y`, errTstAccess)
	f.dir(`C:\R\z`)
	f.failDir(`C:\R\z\inner`, errTstBoom) // partial with size 0: not measured
	l := tstMeasure(t, f, `C:\R`)
	if got := tstItemNames(l.Items); !tstSameStrings(got, []string{"w", "x", "e", "y", "z"}) {
		t.Errorf("order = %v, want [w x e y z]", got)
	}
}

func TestMeasureOrderDoesNotDependOnParallelism(t *testing.T) {
	sizes := []int64{5, 5, 5, 9, 9, 1, 1, 1, 7, 7, 3, 3}
	names := []string{"m", "k", "z", "a", "b", "q", "t", "s", "u", "h", "n", "e"}
	type pair struct {
		name string
		size int64
	}
	var want []pair
	for i := range names {
		want = append(want, pair{names[i], sizes[i] * 1000})
	}
	sort.Slice(want, func(i, j int) bool {
		if want[i].size != want[j].size {
			return want[i].size > want[j].size
		}
		return want[i].name < want[j].name
	})
	var wantNames []string
	for _, w := range want {
		wantNames = append(wantNames, w.name)
	}
	for run := 0; run < 8; run++ {
		f := newFakeFS()
		for i, n := range names {
			f.file(`C:\R\`+n+`\sub\payload`, sizes[i]*1000)
		}
		f.onRead = func(key string, nth int) {
			h := fnv.New32a()
			h.Write([]byte(key))
			time.Sleep(time.Duration((int(h.Sum32())+run*7)%6) * 300 * time.Microsecond)
		}
		l := tstMeasure(t, f, `C:\R`)
		if got := tstItemNames(l.Items); !tstSameStrings(got, wantNames) {
			t.Fatalf("run %d: order = %v, want %v", run, got, wantNames)
		}
	}
}

// ---------------------------------------------------------------------------
// Largest files

func TestMeasureLargestFilesAreCappedAtTwentyAndSorted(t *testing.T) {
	f := newFakeFS()
	for i := 1; i <= 25; i++ {
		f.file(fmt.Sprintf(`C:\R\f%02d.bin`, i), 2*tstMiB)
	}
	f.file(`C:\R\big.bin`, 10*tstMiB)
	l := tstMeasure(t, f, `C:\R`)
	if len(l.TopFiles) != 20 {
		t.Fatalf("%d large files, want 20", len(l.TopFiles))
	}
	if l.TopFiles[0].Name != "big.bin" || l.TopFiles[0].Size != 10*tstMiB {
		t.Errorf("first = %+v, want big.bin with 10 MiB", l.TopFiles[0])
	}
}

func TestMeasureLargestFilesOfEqualSizeKeepTheEarliestPaths(t *testing.T) {
	f := newFakeFS()
	for i := 1; i <= 25; i++ {
		f.file(fmt.Sprintf(`C:\R\f%02d.bin`, i), 2*tstMiB)
	}
	f.file(`C:\R\big.bin`, 10*tstMiB)
	l := tstMeasure(t, f, `C:\R`)
	var got []string
	for _, tf := range l.TopFiles {
		got = append(got, tf.Name)
	}
	want := []string{"big.bin"}
	for i := 1; i <= 19; i++ {
		want = append(want, fmt.Sprintf("f%02d.bin", i))
	}
	if !tstSameStrings(got, want) {
		t.Errorf("large files = %v, want %v", got, want)
	}
}

func TestMeasureLargestFilesNeedAtLeastOneMiB(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\small.bin`, 900*tstKiB)
	f.file(`C:\R\justunder.bin`, tstMiB-1)
	f.file(`C:\R\exact.bin`, tstMiB)
	l := tstMeasure(t, f, `C:\R`)
	if len(l.TopFiles) != 1 || l.TopFiles[0].Name != "exact.bin" {
		t.Errorf("large files = %+v, want only exact.bin", l.TopFiles)
	}
}

func TestMeasureLargestFilesAreRecursiveWithFullPaths(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\b\c\deep.bin`, 5*tstMiB)
	f.file(`C:\R\top.bin`, 3*tstMiB)
	l := tstMeasure(t, f, `C:\R`)
	if len(l.TopFiles) != 2 {
		t.Fatalf("large files = %+v", l.TopFiles)
	}
	if l.TopFiles[0].Path != `C:\R\a\b\c\deep.bin` || l.TopFiles[0].Name != "deep.bin" || l.TopFiles[0].Size != 5*tstMiB {
		t.Errorf("first = %+v", l.TopFiles[0])
	}
	if l.TopFiles[1].Path != `C:\R\top.bin` {
		t.Errorf("second = %+v", l.TopFiles[1])
	}
}

func TestMeasureLargestFilesOfEqualSizeAreOrderedByPathIgnoringCase(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\b\x.bin`, 2*tstMiB)
	f.file(`C:\R\A\y.bin`, 2*tstMiB)
	f.file(`C:\R\c.bin`, 2*tstMiB)
	l := tstMeasure(t, f, `C:\R`)
	var got []string
	for _, tf := range l.TopFiles {
		got = append(got, tf.Path)
	}
	want := []string{`C:\R\A\y.bin`, `C:\R\b\x.bin`, `C:\R\c.bin`}
	if !tstSameStrings(got, want) {
		t.Errorf("paths = %v, want %v", got, want)
	}
}

func TestMeasureLargestFilesKeepEveryExtensionAndFolderName(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\data.db`, 5*tstGiB)
	f.file(`C:\R\x.json`, 2*tstMiB)
	f.file(`C:\R\notes.txt`, 3*tstMiB)
	f.file(`C:\R\node_modules\pkg\big.bin`, 4*tstMiB)
	l := tstMeasure(t, f, `C:\R`)
	if len(l.TopFiles) != 4 {
		t.Errorf("large files = %+v, want all four", l.TopFiles)
	}
}

func TestMeasureLargestFilesExcludeLinksAndOnlineFiles(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\local.bin`, 2*tstMiB)
	f.link(`C:\R\lnk`, `D:\elsewhere`)
	f.file(`D:\elsewhere\huge1.bin`, 9*tstGiB)
	f.fileLink(`C:\R\sym.bin`)
	f.setSize(`C:\R\sym.bin`, 8*tstGiB)
	f.cloudFile(`C:\R\cloud\online.bin`, tstGiB, true)
	l := tstMeasure(t, f, `C:\R`)
	if len(l.TopFiles) != 1 || l.TopFiles[0].Name != "local.bin" {
		t.Errorf("large files = %+v, want only local.bin", l.TopFiles)
	}
}

func TestMeasureLargestFilesIncludeLocalPlaceholders(t *testing.T) {
	f := newFakeFS()
	f.cloudFile(`C:\R\cloud\kept.bin`, 5*tstMiB, false)
	l := tstMeasure(t, f, `C:\R`)
	if len(l.TopFiles) != 1 || l.TopFiles[0].Size != 5*tstMiB {
		t.Errorf("large files = %+v, want the local placeholder", l.TopFiles)
	}
}

func TestMeasureLargestFilesAreEmptyWithoutLargeFiles(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a`, 10)
	l := tstMeasure(t, f, `C:\R`)
	if len(l.TopFiles) != 0 {
		t.Errorf("large files = %+v, want none", l.TopFiles)
	}
}

// ---------------------------------------------------------------------------
// Concurrency and cancellation

func TestMeasureReadsAtMostSixteenDirectoriesAtTheSameTime(t *testing.T) {
	f := newFakeFS()
	for i := 0; i < 300; i++ {
		f.file(fmt.Sprintf(`C:\R\d%03d\sub\f`, i), 1)
	}
	f.delay = 2 * time.Millisecond
	l := tstMeasure(t, f, `C:\R`)
	if got := f.maxConcurrent(); got > 16 {
		t.Errorf("%d simultaneous reads, want at most 16", got)
	}
	if l.TotalFiles != 300 {
		t.Errorf("TotalFiles = %d, want 300", l.TotalFiles)
	}
}

func TestMeasureDeepTreeWithManyLevelsDoesNotExceedTheLimit(t *testing.T) {
	f := newFakeFS()
	for i := 0; i < 40; i++ {
		f.file(fmt.Sprintf(`C:\R\a%02d\b\c\d\f`, i), 1)
		f.file(fmt.Sprintf(`C:\R\a%02d\b2\c2\f`, i), 1)
	}
	f.delay = time.Millisecond
	tstMeasure(t, f, `C:\R`)
	if got := f.maxConcurrent(); got > 16 {
		t.Errorf("%d simultaneous reads, want at most 16", got)
	}
}

func TestMeasureStopsStartingReadsAfterCancellation(t *testing.T) {
	f := newFakeFS()
	for i := 0; i < 60; i++ {
		f.file(fmt.Sprintf(`C:\R\d%02d\sub\f`, i), 1)
		f.hold(fmt.Sprintf(`C:\R\d%02d`, i))
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	type out struct {
		l   Listing
		err error
	}
	done := make(chan out, 1)
	go func() {
		l, err := Measure(ctx, f, `C:\R`, tstNewCounters(), func(Item) {})
		done <- out{l, err}
	}()
	// wait until the number of reads has been stable for a while: every read
	// that can start is blocked
	last, stableSince := -1, time.Now()
	for time.Since(stableSince) < 150*time.Millisecond {
		if n := f.readTotal(); n != last {
			last, stableSince = n, time.Now()
		}
		if time.Since(stableSince) > 10*time.Second {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if last < 2 {
		t.Fatalf("the measurement did not start reading (%d reads)", last)
	}
	cancel()
	before := f.readTotal()
	f.releaseAll()
	select {
	case r := <-done:
		if !errors.Is(r.err, context.Canceled) {
			t.Errorf("err = %v, want context.Canceled", r.err)
		}
		if len(r.l.Items) != 0 {
			t.Errorf("the result of a canceled measurement has %d items, want it discarded", len(r.l.Items))
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Measure did not return after the cancellation")
	}
	if after := f.readTotal(); after != before {
		t.Errorf("%d reads began after the cancellation", after-before)
	}
}

func TestMeasureCanceledBeforeTheStartReadsNothing(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\f`, 1)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := tstMeasureCtx(ctx, f, `C:\R`)
	if err == nil {
		t.Error("Measure returned no error for a canceled context")
	}
	if n := f.readTotal(); n != 0 {
		t.Errorf("%d reads began although the context was canceled", n)
	}
}

// ---------------------------------------------------------------------------
// Counters and the callback

func TestMeasureCountersMatchTheResult(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\f1`, 100)
	f.file(`C:\R\a\s\f2`, 50)
	f.file(`C:\R\b\f3`, 25)
	f.file(`C:\R\f4`, 5)
	f.cloudFile(`C:\R\c\online.bin`, tstGiB, true)
	f.link(`C:\R\lnk`, `D:\x`)
	f.file(`D:\x\g`, 999)
	c := tstNewCounters()
	l, err := Measure(context.Background(), f, `C:\R`, c, func(Item) {})
	if err != nil {
		t.Fatal(err)
	}
	if got := tstCountFiles(c); got != l.TotalFiles {
		t.Errorf("Files() = %d, want TotalFiles %d", got, l.TotalFiles)
	}
	if got := tstCountBytes(c); got != l.TotalSize {
		t.Errorf("Bytes() = %d, want TotalSize %d", got, l.TotalSize)
	}
	if l.TotalSize != 180 || l.TotalFiles != 5 {
		t.Errorf("totals = %d bytes, %d files, want 180 and 5", l.TotalSize, l.TotalFiles)
	}
	if d := tstCountDirs(c); d < 4 || d > 5 {
		t.Errorf("Dirs() = %d, want the four folders below the root (the root itself may count)", d)
	}
}

func TestMeasureCountersNeverDecreaseWhileTheMeasurementRuns(t *testing.T) {
	f := newFakeFS()
	for i := 0; i < 40; i++ {
		for j := 0; j < 20; j++ {
			f.file(fmt.Sprintf(`C:\R\d%02d\s\f%02d`, i, j), 100)
		}
	}
	f.delay = time.Millisecond
	c := tstNewCounters()
	stop := make(chan struct{})
	var wg sync.WaitGroup
	var bad []string
	wg.Add(1)
	go func() {
		defer wg.Done()
		var pf, pd, pb int64
		for {
			select {
			case <-stop:
				return
			default:
			}
			nf, nd, nb := tstCountFiles(c), tstCountDirs(c), tstCountBytes(c)
			if nf < pf || nd < pd || nb < pb {
				bad = append(bad, fmt.Sprintf("(%d,%d,%d) after (%d,%d,%d)", nf, nd, nb, pf, pd, pb))
			}
			pf, pd, pb = nf, nd, nb
			time.Sleep(50 * time.Microsecond)
		}
	}()
	l, err := Measure(context.Background(), f, `C:\R`, c, func(Item) {})
	close(stop)
	wg.Wait()
	if err != nil {
		t.Fatal(err)
	}
	if len(bad) > 0 {
		t.Errorf("counters went down: %v", bad)
	}
	if tstCountFiles(c) != l.TotalFiles || tstCountBytes(c) != 800*100 {
		t.Errorf("final counters = %d files, %d bytes", tstCountFiles(c), tstCountBytes(c))
	}
}

func TestMeasureCountersAdvanceBeforeTheMeasurementEnds(t *testing.T) {
	f := newFakeFS()
	for i := 0; i < 137; i++ {
		f.file(fmt.Sprintf(`C:\R\a\f%03d`, i), tstKiB)
	}
	f.file(`C:\R\b\slow`, 1)
	f.hold(`C:\R\b`)
	c := tstNewCounters()
	done := make(chan struct{})
	go func() {
		defer close(done)
		Measure(context.Background(), f, `C:\R`, c, func(Item) {})
	}()
	deadline := time.Now().Add(10 * time.Second)
	for tstCountFiles(c) < 137 && time.Now().Before(deadline) {
		time.Sleep(2 * time.Millisecond)
	}
	if got := tstCountFiles(c); got != 137 {
		t.Errorf("Files() = %d while a sibling is still blocked, want 137", got)
	}
	if got := tstCountBytes(c); got != 137*tstKiB {
		t.Errorf("Bytes() = %d while a sibling is still blocked, want %d", got, 137*tstKiB)
	}
	select {
	case <-done:
		t.Error("the measurement ended although a read is blocked")
	default:
	}
	f.releaseAll()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Measure did not finish after the release")
	}
}

func TestMeasureReportsEveryDirectChildOnceThroughTheCallback(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\a\f`, 100)
	f.file(`C:\R\b\g`, 200)
	f.failDir(`C:\R\c`, errTstAccess)
	f.file(`C:\R\d.txt`, 5)
	f.link(`C:\R\lnk`, `D:\x`)
	var mu sync.Mutex
	var got []Item
	l, err := Measure(context.Background(), f, `C:\R`, tstNewCounters(), func(it Item) {
		mu.Lock()
		got = append(got, it)
		mu.Unlock()
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(l.Items) {
		t.Fatalf("callback got %d children, the listing has %d", len(got), len(l.Items))
	}
	for _, it := range l.Items {
		n := 0
		for _, g := range got {
			if g.Path == it.Path {
				n++
				if !reflect.DeepEqual(g, it) {
					t.Errorf("callback item %+v differs from the listed %+v", g, it)
				}
			}
		}
		if n != 1 {
			t.Errorf("%s reported %d times, want once", it.Path, n)
		}
	}
}

func TestMeasureReportsFinishedChildrenBeforeSlowSiblingsFinish(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\fast\f`, 100)
	f.file(`C:\R\slow\g`, 200)
	f.hold(`C:\R\slow`)
	arrived := make(chan Item, 8)
	done := make(chan struct{})
	go func() {
		defer close(done)
		Measure(context.Background(), f, `C:\R`, tstNewCounters(), func(it Item) { arrived <- it })
	}()
	select {
	case it := <-arrived:
		if it.Name != "fast" || it.Size != 100 {
			t.Errorf("first reported child = %+v, want fast with 100", it)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no child was reported while the slow sibling is blocked")
	}
	f.releaseAll()
	<-done
}

// ---------------------------------------------------------------------------
// Cloud placeholders and online files

func TestMeasureOnlineFilesCountNoLocalBytes(t *testing.T) {
	f := newFakeFS()
	f.file(`C:\R\D\local.bin`, 100)
	f.cloudFile(`C:\R\D\online.bin`, tstGiB, true)
	l := tstMeasure(t, f, `C:\R`)
	d := tstMustItem(t, l, "D")
	if d.Size != 100 || d.OnlineSize != tstGiB || !d.Cloud {
		t.Errorf("D = {size %d, online %d, cloud %v}, want 100, %d, true", d.Size, d.OnlineSize, d.Cloud, tstGiB)
	}
	if l.TotalSize != 100 || l.TotalOnlineSize != tstGiB || l.TotalFiles != 2 {
		t.Errorf("totals = %d local, %d online, %d files, want 100, %d, 2", l.TotalSize, l.TotalOnlineSize, l.TotalFiles, tstGiB)
	}
	if len(l.TopFiles) != 0 {
		t.Errorf("large files = %+v, want the online file absent", l.TopFiles)
	}
}

func TestMeasureLocalPlaceholderCountsItsLocalSize(t *testing.T) {
	f := newFakeFS()
	f.cloudFile(`C:\R\D\kept.bin`, 5*tstMiB, false)
	l := tstMeasure(t, f, `C:\R`)
	d := tstMustItem(t, l, "D")
	if d.Size != 5*tstMiB || d.OnlineSize != 0 || !d.Cloud {
		t.Errorf("D = {size %d, online %d, cloud %v}, want %d, 0, true", d.Size, d.OnlineSize, d.Cloud, 5*tstMiB)
	}
}

func TestMeasureCloudFlagComesFromAnyDescendantAndOnlyFromThere(t *testing.T) {
	f := newFakeFS()
	f.cloudFile(`C:\R\x\y\z\ph.txt`, 10, false)
	f.file(`C:\R\plain\f`, 10)
	l := tstMeasure(t, f, `C:\R`)
	if !tstMustItem(t, l, "x").Cloud {
		t.Errorf("x.Cloud = false, want true: a placeholder is three levels below")
	}
	if tstMustItem(t, l, "plain").Cloud {
		t.Errorf("plain.Cloud = true, want false")
	}
}

func TestMeasureCloudFoldersAreEnteredAndMeasuredAndAreNoLinks(t *testing.T) {
	f := newFakeFS()
	f.cloudDir(`C:\R\OneDrive`)
	f.file(`C:\R\OneDrive\doc.txt`, 100)
	f.file(`C:\R\OneDrive\sub\more.txt`, 50)
	l := tstMeasure(t, f, `C:\R`)
	od := tstMustItem(t, l, "OneDrive")
	if od.IsLink {
		t.Errorf("OneDrive.IsLink = true, a cloud folder is no link")
	}
	if od.Size != 150 || !od.Cloud || !od.IsDir {
		t.Errorf("OneDrive = {size %d, cloud %v, dir %v}, want 150, true, true", od.Size, od.Cloud, od.IsDir)
	}
	if f.readCount(`C:\R\OneDrive`) == 0 {
		t.Errorf("the cloud folder was not read")
	}
}

func TestMeasureOnlineSizeSumsOverTheTree(t *testing.T) {
	f := newFakeFS()
	f.cloudFile(`C:\R\D\a.bin`, 3*tstMiB, true)
	f.cloudFile(`C:\R\D\s\b.bin`, 4*tstMiB, true)
	f.file(`C:\R\other`, 1)
	l := tstMeasure(t, f, `C:\R`)
	if got := tstMustItem(t, l, "D").OnlineSize; got != 7*tstMiB {
		t.Errorf("D.OnlineSize = %d, want %d", got, 7*tstMiB)
	}
	if l.TotalOnlineSize != 7*tstMiB {
		t.Errorf("TotalOnlineSize = %d, want %d", l.TotalOnlineSize, 7*tstMiB)
	}
	if got := tstMustItem(t, l, "other").OnlineSize; got != 0 {
		t.Errorf("other.OnlineSize = %d, want 0", got)
	}
}
