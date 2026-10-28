package main

// The check of one entry before it may be moved (pre-check, rejection codes,
// tree check, identities, time budget).

import (
	"context"
	"fmt"
	"testing"
	"time"
)

type tstRev struct {
	f   *fakeFS
	clk *fakeClock
	env map[string]string
}

func newRev() *tstRev {
	f := newFakeFS()
	tstWinTree(f)
	return &tstRev{f: f, clk: newFakeClock(), env: tstWinEnv()}
}

func (r *tstRev) review(root, path string, item Item) *Refusal {
	return Review(context.Background(), r.f, r.clk, r.env, root, path, item)
}

func tstWantCode(t *testing.T, what string, ref *Refusal, codes ...string) {
	t.Helper()
	if ref == nil {
		t.Errorf("%s: not refused, want code %v", what, codes)
		return
	}
	for _, c := range codes {
		if ref.Code == c {
			return
		}
	}
	t.Errorf("%s: code %q, want one of %v", what, ref.Code, codes)
}

func tstWantClean(t *testing.T, what string, ref *Refusal) {
	t.Helper()
	if ref != nil {
		t.Errorf("%s: refused with %q (%s), want accepted", what, ref.Code, ref.Text)
	}
}

func TestReviewAcceptsAnOrdinaryFolderAndFile(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\a\sub\f.bin`, 10)
	r.f.file(`C:\Data\a\node_modules\p`, 5)
	r.f.file(`C:\Data\file.txt`, 7)
	tstWantClean(t, "folder", r.review(`C:\Data`, `C:\Data\a`, tstDirItem(`C:\Data\a`, 15)))
	tstWantClean(t, "file", r.review(`C:\Data`, `C:\Data\file.txt`, tstFileItem(`C:\Data\file.txt`, 7)))
	r.f.assertNoLinkFollowed(t)
}

func TestReviewAllowsDeepDescendantsOfTheRoot(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\a\b\c\big.bin`, 10)
	tstWantClean(t, "deep file", r.review(`C:\Data`, `C:\Data\a\b\c\big.bin`, tstFileItem(`C:\Data\a\b\c\big.bin`, 10)))
}

func TestReviewRefusalIsAnErrorWithCodeAndText(t *testing.T) {
	r := newRev()
	r.f.dir(`C:\Data`)
	ref := r.review(`C:\Data`, `C:\Data`, tstDirItem(`C:\Data`, 0))
	if ref == nil {
		t.Fatal("not refused")
	}
	var err error = ref
	if err.Error() == "" || ref.Code == "" || ref.Text == "" {
		t.Errorf("refusal = %q / %q / %q, want non-empty code and text", ref.Code, ref.Text, err.Error())
	}
}

// ---------------------------------------------------------------------------
// outside-root

func TestReviewRefusesTheRootItselfInAnySpelling(t *testing.T) {
	r := newRev()
	r.f.dir(`C:\Data\a`)
	for _, p := range []string{`C:\Data`, `C:\DATA`, `C:\Data\`, `c:/data`} {
		tstWantCode(t, p, r.review(`C:\Data`, p, tstDirItem(p, 0)), "outside-root")
	}
}

func TestReviewRefusesAncestorsSiblingsAndLookalikesOfTheRoot(t *testing.T) {
	r := newRev()
	r.f.dir(`C:\Data\sub\a`)
	r.f.dir(`C:\Data\sub2\x`)
	r.f.dir(`C:\Data\subx`)
	r.f.dir(`C:\Other\x`)
	for _, p := range []string{`C:\Data`, `C:\Data\sub2\x`, `C:\Data\sub2`, `C:\Data\subx`, `C:\Other\x`} {
		tstWantCode(t, p, r.review(`C:\Data\sub`, p, tstDirItem(p, 1)), "outside-root")
	}
}

func TestReviewRefusesAPathThatLeavesTheRootThroughAJunction(t *testing.T) {
	r := newRev()
	r.f.file(`D:\Other\x\f`, 1)
	r.f.file(`C:\Data2\y\f`, 1)
	r.f.link(`C:\Data\j`, `D:\Other`)
	r.f.link(`C:\Data\k`, `C:\Data2`)
	// the path looks like a child of the root, the parent resolves elsewhere
	tstWantCode(t, "via D:", r.review(`C:\Data`, `C:\Data\j\x`, tstDirItem(`C:\Data\j\x`, 1)), "outside-root", "link")
	tstWantCode(t, "via C:\\Data2", r.review(`C:\Data`, `C:\Data\k\y`, tstDirItem(`C:\Data\k\y`, 1)), "outside-root", "link")
}

func TestReviewRefusesWhenTheRootIsReachedThroughAJunctionAndThePathIsNot(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Real\child\f`, 1)
	r.f.link(`D:\RootLink`, `C:\Real`)
	// the view was opened through the junction; the entry is addressed through the real path
	ref := r.review(`D:\RootLink`, `C:\Real\child`, tstDirItem(`C:\Real\child`, 1))
	tstWantCode(t, "real path against a junction root", ref, "outside-root", "link")
}

// ---------------------------------------------------------------------------
// protected, data folder

func TestReviewRefusesProtectedEntries(t *testing.T) {
	r := newRev()
	tstEnsure(r.f, `C:\Users\Example\.ssh`, `C:\Users\Example\AppData\Roaming\Microsoft\Credentials`, `C:\Windows\Temp`)
	cases := []struct{ root, path string }{
		{`C:\`, `C:\Windows`},
		{`C:\Windows`, `C:\Windows\Temp`},
		{`C:\Users\Example`, `C:\Users\Example\.ssh`},
		{`C:\Users\Example\AppData\Roaming`, `C:\Users\Example\AppData\Roaming\Microsoft\Credentials`},
		{`C:\`, `C:\Program Files`},
	}
	for _, c := range cases {
		tstWantCode(t, c.path, r.review(c.root, c.path, tstDirItem(c.path, 1)), "protected")
	}
	// C:\Users is also an ancestor of the profile data folders: either code is right
	tstWantCode(t, `C:\Users`, r.review(`C:\`, `C:\Users`, tstDirItem(`C:\Users`, 1)), "protected", "data-folder")
}

func TestReviewRefusesTheDataFolderAndItsAncestors(t *testing.T) {
	r := newRev()
	r.env = tstEnvWith(r.env, "SWEEPR_DATA_DIR", `C:\SweeprData`)
	tstEnsure(r.f, `C:\SweeprData\config\operations.log`, `C:\SweeprData\cache`)
	for _, c := range []struct{ root, path string }{
		{`C:\`, `C:\SweeprData`},
		{`C:\SweeprData`, `C:\SweeprData\config`},
		{`C:\SweeprData`, `C:\SweeprData\config\operations.log`},
		{`C:\SweeprData`, `C:\SweeprData\cache`},
	} {
		tstWantCode(t, c.path, r.review(c.root, c.path, tstDirItem(c.path, 1)), "data-folder")
	}
}

func TestReviewRefusesAFolderThatContainsTheDataFolder(t *testing.T) {
	r := newRev()
	r.env = tstEnvWith(r.env, "SWEEPR_DATA_DIR", `C:\Data\a\sw`)
	tstEnsure(r.f, `C:\Data\a\sw\config`, `C:\Data\a\sw\cache`)
	tstWantCode(t, "ancestor of the data folder", r.review(`C:\Data`, `C:\Data\a`, tstDirItem(`C:\Data\a`, 1)), "data-folder")
}

func TestReviewRefusesAFolderWithAProtectedDescendant(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\proj\src\x`, 1)
	r.f.file(`C:\Data\proj\deep\er\est\.ssh\id`, 1)
	tstWantCode(t, "protected descendant", r.review(`C:\Data`, `C:\Data\proj`, tstDirItem(`C:\Data\proj`, 2)), "protected")
}

func TestReviewRefusesAFolderWithAProtectedFileNamedLikeAProtectedFolder(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\proj\.ssh`, 1)
	tstWantCode(t, ".ssh as a file", r.review(`C:\Data`, `C:\Data\proj`, tstDirItem(`C:\Data\proj`, 1)), "protected")
}

func TestReviewTreatsAnUnreadableIdentityAsARefusal(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\a\f`, 1)
	r.f.file(`C:\Data\b\f`, 1)
	r.f.failIdentity(`C:\Data\a`, errTstAccess)
	r.f.failIdentity(`C:\Data`, errTstBoom)
	// the code is not fixed by the rules: incomplete or data folder
	tstWantCode(t, "target identity", r.review(`C:\Data`, `C:\Data\a`, tstDirItem(`C:\Data\a`, 1)), "incomplete", "data-folder", "protected")
	r.f.clearFailures(`C:\Data\a`)
	tstWantCode(t, "ancestor identity", r.review(`C:\Data`, `C:\Data\b`, tstDirItem(`C:\Data\b`, 1)), "incomplete", "data-folder", "protected")
}

// ---------------------------------------------------------------------------
// link, cloud, unmeasured, invalid

func TestReviewRefusesALinkEntry(t *testing.T) {
	r := newRev()
	r.f.link(`C:\Data\lnk`, `D:\target`)
	it := tstDirItem(`C:\Data\lnk`, 0)
	it.IsLink = true
	tstWantCode(t, "link item", r.review(`C:\Data`, `C:\Data\lnk`, it), "link")
	r.f.fileLink(`C:\Data\sym.txt`)
	fi := tstFileItem(`C:\Data\sym.txt`, 0)
	fi.IsLink = true
	tstWantCode(t, "file link item", r.review(`C:\Data`, `C:\Data\sym.txt`, fi), "link")
}

func TestReviewRefusesWhenTheFileSystemShowsALinkTheItemDoesNot(t *testing.T) {
	r := newRev()
	r.f.link(`C:\Data\swapped`, `D:\target`)
	tstWantCode(t, "link behind a plain item", r.review(`C:\Data`, `C:\Data\swapped`, tstDirItem(`C:\Data\swapped`, 1)), "link")
}

func TestReviewRefusesAFolderWithALinkInsideAndNeverEntersIt(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\a\f`, 1)
	r.f.link(`C:\Data\a\inner\lnk`, `D:\elsewhere`)
	r.f.file(`D:\elsewhere\g`, 1)
	tstWantCode(t, "link inside", r.review(`C:\Data`, `C:\Data\a`, tstDirItem(`C:\Data\a`, 1)), "link")
	if n := r.f.readCount(`D:\elsewhere`); n != 0 {
		t.Errorf("the link target was read %d times", n)
	}
	r.f.assertNoLinkFollowed(t)
}

func TestReviewRefusesATargetBelowALinkedAncestor(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\real\x\f`, 1)
	r.f.link(`C:\Data\via`, `C:\Data\real`)
	tstWantCode(t, "ancestor is a junction", r.review(`C:\Data`, `C:\Data\via\x`, tstDirItem(`C:\Data\via\x`, 1)), "link")
}

func TestReviewRefusesCloudContentInEveryPlace(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\plain\f`, 1)
	r.f.cloudFile(`C:\Data\withfile\sub\ph.txt`, 10, false)
	r.f.cloudFile(`C:\Data\withonline\o.bin`, tstGiB, true)
	r.f.cloudDir(`C:\Data\withdir\od`)
	r.f.file(`C:\Data\withdir\od\f`, 1)
	r.f.cloudDir(`C:\Data\OneDrive`)
	r.f.file(`C:\Data\OneDrive\sub\f`, 1)
	r.f.cloudFile(`C:\Data\placeholder.txt`, 10, false)

	flagged := tstDirItem(`C:\Data\plain`, 1)
	flagged.Cloud = true
	tstWantCode(t, "item flagged cloud", r.review(`C:\Data`, `C:\Data\plain`, flagged), "cloud")
	tstWantCode(t, "placeholder file inside", r.review(`C:\Data`, `C:\Data\withfile`, tstDirItem(`C:\Data\withfile`, 10)), "cloud")
	tstWantCode(t, "online file inside", r.review(`C:\Data`, `C:\Data\withonline`, tstDirItem(`C:\Data\withonline`, 0)), "cloud")
	tstWantCode(t, "cloud folder inside", r.review(`C:\Data`, `C:\Data\withdir`, tstDirItem(`C:\Data\withdir`, 1)), "cloud")
	tstWantCode(t, "the target is a cloud folder", r.review(`C:\Data`, `C:\Data\OneDrive`, tstDirItem(`C:\Data\OneDrive`, 1)), "cloud")
	tstWantCode(t, "the target is a placeholder", r.review(`C:\Data`, `C:\Data\placeholder.txt`, tstFileItem(`C:\Data\placeholder.txt`, 10)), "cloud")
	tstWantCode(t, "the target lies in a cloud folder", r.review(`C:\Data`, `C:\Data\OneDrive\sub`, tstDirItem(`C:\Data\OneDrive\sub`, 1)), "cloud")
	tstWantClean(t, "an ordinary sibling", r.review(`C:\Data`, `C:\Data\plain`, tstDirItem(`C:\Data\plain`, 1)))
}

func TestReviewRefusesUnmeasuredEntries(t *testing.T) {
	r := newRev()
	r.f.dir(`C:\Data\locked`)
	it := tstDirItem(`C:\Data\locked`, 0)
	it.State = Unavailable
	tstWantCode(t, "unavailable", r.review(`C:\Data`, `C:\Data\locked`, it), "unmeasured")
}

func TestReviewRefusesRelativeAndMalformedPaths(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\a`, 1)
	for _, p := range []string{`a`, `Data\a`, "C:\\Data\\a\x00b", ""} {
		if ref := r.review(`C:\Data`, p, tstFileItem(p, 1)); ref == nil {
			t.Errorf("%q: not refused", p)
		}
	}
}

// ---------------------------------------------------------------------------
// tree check: incomplete, budget, cancellation, size

func TestReviewRefusesATreeThatCannotBeReadCompletely(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\a\ok\f`, 1)
	r.f.file(`C:\Data\a\locked\f`, 1)
	r.f.failDir(`C:\Data\a\locked`, errTstAccess)
	r.f.file(`C:\Data\b\f`, 1)
	r.f.failDir(`C:\Data\b`, errTstBoom)
	tstWantCode(t, "unreadable subfolder", r.review(`C:\Data`, `C:\Data\a`, tstDirItem(`C:\Data\a`, 1)), "incomplete")
	tstWantCode(t, "unreadable target", r.review(`C:\Data`, `C:\Data\b`, tstDirItem(`C:\Data\b`, 1)), "incomplete")
}

func TestReviewRefusesWhenTheTimeBudgetIsExceeded(t *testing.T) {
	r := newRev()
	for i := 0; i < 6; i++ {
		r.f.file(fmt.Sprintf(`C:\Data\big\d%d\f`, i), 1)
	}
	r.f.onRead = func(key string, nth int) { r.clk.Advance(25 * time.Second) }
	tstWantCode(t, "slow tree", r.review(`C:\Data`, `C:\Data\big`, tstDirItem(`C:\Data\big`, 6)), "incomplete")
}

func TestReviewAcceptsATreeThatStaysWithinTheTimeBudget(t *testing.T) {
	r := newRev()
	for i := 0; i < 3; i++ {
		r.f.file(fmt.Sprintf(`C:\Data\big\d%d\f`, i), 1)
	}
	r.f.onRead = func(key string, nth int) { r.clk.Advance(10 * time.Second) }
	tstWantClean(t, "quick tree", r.review(`C:\Data`, `C:\Data\big`, tstDirItem(`C:\Data\big`, 3)))
}

func TestReviewTakesTheBudgetFromTheClockNotFromTheWallTime(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\big\d\f`, 1)
	r.f.delay = 30 * time.Millisecond // real time passes, the artificial clock stands still
	tstWantClean(t, "tree with the frozen clock", r.review(`C:\Data`, `C:\Data\big`, tstDirItem(`C:\Data\big`, 1)))
}

func TestReviewNeverTreatsACanceledCheckAsClean(t *testing.T) {
	r := newRev()
	for i := 0; i < 6; i++ {
		r.f.file(fmt.Sprintf(`C:\Data\big\d%d\f`, i), 1)
	}
	ctx, cancel := context.WithCancel(context.Background())
	r.f.onRead = func(key string, nth int) {
		if nth >= 1 && key != tstKey(`C:\Data\big`) {
			cancel()
		}
	}
	ref := Review(ctx, r.f, r.clk, r.env, `C:\Data`, `C:\Data\big`, tstDirItem(`C:\Data\big`, 6))
	if ref == nil {
		t.Errorf("a canceled check returned no refusal")
	}
	cancel()
	ctx2, cancel2 := context.WithCancel(context.Background())
	cancel2()
	if ref := Review(ctx2, r.f, r.clk, r.env, `C:\Data`, `C:\Data\big`, tstDirItem(`C:\Data\big`, 6)); ref == nil {
		t.Errorf("a check with a canceled context returned no refusal")
	}
}

func TestReviewHasNoLimitOnTheNumberOfEntries(t *testing.T) {
	r := newRev()
	for i := 0; i < 100500; i++ {
		r.f.fileExact(`C:\Data\huge`, fmt.Sprintf("f%06d", i), 1)
	}
	tstWantClean(t, "100500 entries", r.review(`C:\Data`, `C:\Data\huge`, tstDirItem(`C:\Data\huge`, 100500)))
}

func TestReviewOfAFileReadsNoDirectoryOfTheTarget(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\a\f.bin`, 5)
	tstWantClean(t, "file", r.review(`C:\Data`, `C:\Data\a\f.bin`, tstFileItem(`C:\Data\a\f.bin`, 5)))
	if n := r.f.readCount(`C:\Data\a\f.bin`); n != 0 {
		t.Errorf("the file was read as a directory %d times", n)
	}
}

func TestReviewReadsTheIdentityOfTheTargetAndEveryAncestor(t *testing.T) {
	r := newRev()
	r.f.file(`C:\Data\a\b\f`, 1)
	tstWantClean(t, "folder", r.review(`C:\Data`, `C:\Data\a\b`, tstDirItem(`C:\Data\a\b`, 1)))
	for _, p := range []string{`C:\Data\a\b`, `C:\Data\a`, `C:\Data`, `C:\`} {
		if r.f.identityCount(p) == 0 {
			t.Errorf("the identity of %s was not read", p)
		}
	}
}
