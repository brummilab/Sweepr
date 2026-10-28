package main

// The data folders of Sweepr through links, the failure to read them, the
// rules for odd segment names, the text of sums that contain unmeasured
// entries, and the behaviour of the display while a check runs and when it
// ends during a move.

import (
	"errors"
	"regexp"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func tstAssertProtection(t *testing.T, f *fakeFS, env map[string]string, want map[string]bool) {
	t.Helper()
	for p, w := range want {
		if got := IsProtected(p, env, f); got != w {
			t.Errorf("IsProtected(%s) = %v, want %v", p, got, w)
		}
	}
}

func TestProtectionFollowsALinkInAnAncestorOfTheDataFolder(t *testing.T) {
	f, env := tstProtRig()
	f.dir(`D:\dotfiles\config\sweepr`)
	f.dir(`D:\dotfiles\config\notes`)
	f.dir(`D:\dotfiles\other`)
	f.link(`C:\Users\Example\.config`, `D:\dotfiles\config`)
	tstAssertProtection(t, f, env, map[string]bool{
		`D:\dotfiles\config`:                true, // where the linked ancestor leads
		`D:\dotfiles`:                       true, // holds it
		`D:\dotfiles\config\sweepr`:         true,
		`D:\dotfiles\config\sweepr\deeper`:  true,
		`D:\dotfiles\config\notes`:          false,
		`D:\dotfiles\other`:                 false,
		`C:\Users\Example\.config\sweepr\x`: true,
	})
}

func TestProtectionFollowsALinkAsTheDataFolderItself(t *testing.T) {
	f, env := tstDataRig(`C:\SweeprData`)
	f.dir(`E:\swdata\x`)
	f.dir(`E:\other`)
	f.link(`C:\SweeprData\config`, `E:\swdata`)
	tstAssertProtection(t, f, env, map[string]bool{
		`E:\swdata`:         true,
		`E:\swdata\x`:       true,
		`E:\swdata\x\later`: true,
		`E:\other`:          false,
		`C:\SweeprData`:     true,
	})
}

func TestReviewRefusesAFolderThatContainsTheTargetOfALinkedDataFolder(t *testing.T) {
	r := newRev()
	r.env = tstEnvWith(r.env, "SWEEPR_DATA_DIR", `C:\SweeprData`)
	r.f.dir(`E:\stuff\swdata`)
	r.f.dir(`E:\stuff2\x`)
	r.f.dir(`C:\SweeprData`)
	r.f.link(`C:\SweeprData\config`, `E:\stuff\swdata`)
	tstWantCode(t, "folder holding the link target", r.review(`E:\`, `E:\stuff`, tstDirItem(`E:\stuff`, 1)), "data-folder")
	tstWantCode(t, "the link target itself", r.review(`E:\stuff`, `E:\stuff\swdata`, tstDirItem(`E:\stuff\swdata`, 1)), "data-folder")
	tstWantClean(t, "a sibling folder", r.review(`E:\`, `E:\stuff2`, tstDirItem(`E:\stuff2`, 1)))
}

func TestProtectionRecognisesAnAncestorOfTheDataFolderByIdentity(t *testing.T) {
	for _, resolving := range []bool{true, false} {
		f, env := tstDataRig(`C:\Work\Sweepr\data`)
		f.dir(`C:\Work\Sweepr\data\config`)
		f.dir(`C:\Work\Other`)
		f.noResolve = !resolving
		f.alias(`C:\SWEEPR~1`, `C:\Work\Sweepr`) // a short name of the ancestor
		f.rootAlias("S", `C:\Work`)              // a substituted drive for its parent
		tstAssertProtection(t, f, env, map[string]bool{
			`C:\SWEEPR~1`:   true,
			`S:\Sweepr`:     true,
			`C:\Work`:       true,
			`C:\Work\Other`: false,
			`S:\Other`:      false,
		})
	}
	r := newRev()
	r.env = tstEnvWith(r.env, "SWEEPR_DATA_DIR", `C:\Work\Sweepr\data`)
	r.f.dir(`C:\Work\Sweepr\data\config`)
	r.f.noResolve = true
	r.f.alias(`C:\SWEEPR~1`, `C:\Work\Sweepr`)
	tstWantCode(t, "short name of an ancestor", r.review(`C:\`, `C:\SWEEPR~1`, tstDirItem(`C:\SWEEPR~1`, 1)), "data-folder")
}

func TestProtectionRefusesWhenTheDataFolderCannotBeReadOrResolved(t *testing.T) {
	prepare := func() (*fakeFS, map[string]string) {
		f, env := tstDataRig(`C:\SweeprData`)
		f.dir(`C:\SweeprData\config`)
		f.dir(`C:\Data\x`)
		return f, env
	}
	cases := map[string]func(f *fakeFS){
		"identity of the data folder":   func(f *fakeFS) { f.failIdentity(`C:\SweeprData\config`, errTstAccess) },
		"identity of a folder above it": func(f *fakeFS) { f.failIdentity(`C:\SweeprData`, errTstBoom) },
		"resolving the data folder":     func(f *fakeFS) { f.resolveErr[tstKey(`C:\SweeprData\config`)] = errTstBoom },
	}
	for name, setup := range cases {
		f, env := prepare()
		setup(f)
		if !IsProtected(`C:\Data\x`, env, f) {
			t.Errorf("%s fails: an ordinary path is not protected, want everything refused", name)
		}
		r := newRev()
		r.env = env
		r.f = f
		tstWantCode(t, name, r.review(`C:\Data`, `C:\Data\x`, tstDirItem(`C:\Data\x`, 1)), "data-folder")
	}
	// only "does not exist" means that there is no data folder
	f, env := tstDataRig(`C:\SweeprData`)
	f.dir(`C:\Data\x`)
	if IsProtected(`C:\Data\x`, env, f) {
		t.Errorf("a data folder that does not exist protects an ordinary path")
	}
}

func TestProtectionRefusesEverythingForAnIncomparableDataDirectoryWhereItIsStrict(t *testing.T) {
	f, env := tstProtRig()
	f.dir(`C:\Data\x`)
	env = tstEnvWith(env, "SWEEPR_DATA_DIR", `/tmp/not-a-windows-path`)
	old := strictDataDir
	t.Cleanup(func() { strictDataDir = old })
	strictDataDir = false
	if IsProtected(`C:\Data\x`, env, f) {
		t.Errorf("a data directory of the host protects a Windows path")
	}
	strictDataDir = true
	if !IsProtected(`C:\Data\x`, env, f) {
		t.Errorf("an incomparable data directory does not refuse a removal")
	}
	r := newRev()
	r.env = env
	tstWantCode(t, "strict", r.review(`C:\Data`, `C:\Data\x`, tstDirItem(`C:\Data\x`, 1)), "data-folder")
}

func TestReviewChecksTheResolvedSpellingOfDescendants(t *testing.T) {
	r := newRev()
	r.f.dir(`C:\Users\Example\AppData\Local\Packages\Foo`)
	r.f.dir(`C:\Users\Example\AppData\Roaming\App`)
	r.f.rootAlias("S", `C:\Users\Example\AppData`)
	// S:\Local is not protected, but what is below it is: the folder Packages
	// of the local application data, which only its resolved spelling shows
	tstWantCode(t, "Packages below a substituted drive", r.review(`S:\`, `S:\Local`, tstDirItem(`S:\Local`, 1)), "protected")
	tstWantClean(t, "a folder without such content", r.review(`S:\`, `S:\Roaming`, tstDirItem(`S:\Roaming`, 1)))
}

func TestProtectionIgnoresTrailingDotsBlanksAndStreamSuffixesOfNames(t *testing.T) {
	f, env := tstProtRig()
	paths := map[string]bool{
		`C:\Windows.\x`:                          true,
		`C:\Windows \x`:                          true,
		`C:\Program Files.\App`:                  true,
		`C:\Users\Example\.ssh.\id`:              true,
		`C:\Users\Example\.ssh:stream`:           true,
		`C:\Users\Example\Documents\Cookies `:    true,
		`C:\Users\Example\Documents\Cookies.. .`: true,
		`C:\Windows.old\x`:                       false,
	}
	for p := range paths {
		tstEnsure(f, p) // every folder exists, so that "cannot be resolved" is not the reason
	}
	tstAssertProtection(t, f, env, paths)
}

func TestReviewChecksTrailingDotsBlanksAndStreamSuffixesInATree(t *testing.T) {
	for _, name := range []string{`.ssh.`, `.ssh `, `.ssh:s`, `Cookies. `} {
		r := newRev()
		r.f.file(`C:\Data\p\`+name+`\id`, 1)
		tstWantCode(t, name, r.review(`C:\Data`, `C:\Data\p`, tstDirItem(`C:\Data\p`, 1)), "protected")
	}
}

// ---------------------------------------------------------------------------
// Sums that contain unmeasured entries

func TestExplorerNeverShowsAZeroForUnmeasuredEntriesInMarksAndDialog(t *testing.T) {
	r := tstScanRig(t, `C:\Data`)
	r.waitScans(1)
	r.fs.dir(`C:\Data\p`)
	r.fs.dir(`C:\Data\q`)
	part := tstDirItem(`C:\Data\p`, 0)
	part.State = Partial
	r.sc.all()[0].final(tstListingOf(`C:\Data`, tstDirItem(`C:\Data\q`, 2048), part))
	r.until("the rows", func(v string) bool { return strings.Contains(v, "2.0KB") && strings.Contains(v, "not measured") })
	r.press("home", "down") // p
	r.press("space")
	if v := r.view(); !strings.Contains(v, "1 marked, not measured") || strings.Contains(v, "0B+") {
		t.Errorf("the mark message of one unmeasured entry is wrong:\n%s", v)
	}
	r.press("delete")
	r.untilIdle()
	v := r.view()
	if !strings.Contains(v, `Move "p" (not measured)`) || strings.Contains(v, "0B+") {
		t.Errorf("the dialog of one unmeasured entry is wrong:\n%s", v)
	}
	r.press("esc", "up", "space") // q is marked too: a sum of the measured part, flagged as incomplete
	r.press("delete")
	r.untilIdle()
	if v := r.view(); !strings.Contains(v, "(2.0KB+)") {
		t.Errorf("the dialog sum of a measured and an unmeasured entry is wrong:\n%s", v)
	}
}

func TestExplorerDryRunSaysHowManyEntriesWouldBeMoved(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{env: map[string]string{"SWEEPR_DRY_RUN": "1"}})
	r.press("space", "down", "space", "delete", "enter")
	r.untilIdle()
	if !regexp.MustCompile(`(?i)dry run: 2 entries would be moved`).MatchString(r.view()) {
		t.Errorf("the message does not give the number of entries that would be moved:\n%s", r.view())
	}
	r2 := tstOpenSimple(t, tstRigOpts{env: map[string]string{"SWEEPR_DRY_RUN": "1"}})
	r2.goTo("notes.txt", tstSimpleNames)
	r2.press("delete", "enter")
	r2.untilIdle()
	if !regexp.MustCompile(`(?i)dry run: 1 entry would be moved`).MatchString(r2.view()) {
		t.Errorf("the message of a single entry is wrong:\n%s", r2.view())
	}
}

// ---------------------------------------------------------------------------
// The check before the dialog and the end of the program during a move

func TestExplorerEscCancelsACheckThatTakesLong(t *testing.T) {
	r := tstOpenSimple(t, tstRigOpts{})
	r.goTo("beta", tstSimpleNames)
	r.fs.hold(`C:\Data\beta`) // the check reads this folder and has to wait
	r.press("delete")
	r.untilContains("Checking")
	r.press("space", "down", "enter") // ignored while the check runs
	r.press("esc")
	r.untilContains("Canceled")
	if r.p.quit {
		t.Errorf("Esc during the check ended the program")
	}
	if !strings.Contains(r.view(), `C:\Data`) || strings.Contains(r.view(), "Recycle Bin?") {
		t.Errorf("the check was not canceled cleanly:\n%s", r.view())
	}
	r.fs.releaseAll()
	r.untilIdle()
	r.press("enter") // no dialog opened late: Enter opens the folder, it moves nothing
	r.assertNothingRecycled("after the canceled check")

	r2 := tstOpenSimple(t, tstRigOpts{})
	r2.goTo("beta", tstSimpleNames)
	r2.fs.hold(`C:\Data\beta`)
	r2.press("delete")
	r2.untilContains("Checking")
	r2.press("q")
	if !r2.waitQuit() {
		t.Errorf("q during the check did not end the program")
	}
}

func TestRunWaitsForAStartedRecycleCallWhenTheDisplayEnds(t *testing.T) {
	rr := newDataRig()
	env, logFile := tstLogEnv(t, tstWinEnv())
	rr.rec.block()
	d := rr.deps()
	d.StartUI = func(m tea.Model) error {
		p := newTstPump(t, m)
		p.size = tstSize(100, 30)
		p.start(m.Init())
		p.feed(p.size)
		if !p.settle(func() bool { return strings.Contains(tstStrip(p.m.View()), "%") }) {
			t.Error("the folder was not measured")
			return nil
		}
		p.feed(tstKeyMsg("delete"))
		p.drain(30 * time.Millisecond)
		p.feed(tstKeyMsg("enter"))
		rr.rec.waitCalls(t, 1)
		p.feed(tstKeyMsg("q"))
		p.drain(30 * time.Millisecond)
		return nil
	}
	done := make(chan int, 1)
	go func() {
		var out, errOut strings.Builder
		done <- Run([]string{`C:\Data`}, env, &out, &errOut, true, d)
	}()
	select {
	case <-done:
		t.Fatal("Run returned while a Recycle Bin call was still running")
	case <-time.After(300 * time.Millisecond):
	}
	rr.rec.unblock()
	select {
	case code := <-done:
		if code != 0 {
			t.Errorf("exit code %d, want 0", code)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Run did not return after the call ended")
	}
	if calls := rr.rec.recorded(); len(calls) != 1 {
		t.Errorf("recycler calls = %q, want only the call that had begun", calls)
	}
	if got := tstReadLog(t, logFile); got != "" {
		t.Errorf("the interrupted call was logged: %q", got)
	}
}

func TestRunStartsNoConfirmedMoveAfterTheDisplayEndedWithAnError(t *testing.T) {
	rr := newDataRig()
	env, logFile := tstLogEnv(t, tstWinEnv())
	var pending tea.Cmd
	d := rr.deps()
	d.StartUI = func(m tea.Model) error {
		p := newTstPump(t, m)
		p.size = tstSize(100, 30)
		p.start(m.Init())
		p.feed(p.size)
		if !p.settle(func() bool { return strings.Contains(tstStrip(p.m.View()), "%") }) {
			t.Error("the folder was not measured")
		}
		p.feed(tstKeyMsg("delete"))
		// The move is confirmed, but its command is not run: the display ends first.
		_, pending = m.Update(tstKeyMsg("enter"))
		return errors.New("the display failed")
	}
	var out, errOut strings.Builder
	if code := Run([]string{`C:\Data`}, env, &out, &errOut, true, d); code != 1 {
		t.Errorf("exit code %d, want 1", code)
	}
	if pending == nil {
		t.Fatal("the confirmation produced no command")
	}
	if msg := pending(); msg != nil {
		t.Errorf("the move ran after the display ended: %v", msg)
	}
	if calls := rr.rec.recorded(); len(calls) != 0 {
		t.Errorf("recycler calls = %q, want none", calls)
	}
	if got := tstReadLog(t, logFile); got != "" {
		t.Errorf("the log was written: %q", got)
	}
}
