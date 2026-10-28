package main

// Arguments, operating modes, targets, exit codes and channels of Run.

import (
	"bytes"
	"errors"
	"os"
	"strings"
	"testing"
)

// tstQuietEnv returns an environment whose data folder lies in a temporary root
// that stays empty when nothing is written.
func tstQuietEnv(t *testing.T) (map[string]string, string) {
	t.Helper()
	root := t.TempDir()
	env := tstEnvWith(tstWinEnv(), "SWEEPR_DATA_DIR", root+string(os.PathSeparator)+"data")
	return env, root
}

func tstAssertNothingWritten(t *testing.T, root string) {
	t.Helper()
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		t.Errorf("unexpected entry %q was created", e.Name())
	}
}

// newDataRig is a run rig that also has the standard folder C:\Data.
func newDataRig() *tstRunRig {
	rr := newRunRig()
	tstSimpleTree(rr.fs)
	return rr
}

func tstAssertUsageError(t *testing.T, rr *tstRunRig, res tstResult, mentions ...string) {
	t.Helper()
	if res.code != 1 {
		t.Errorf("exit code %d, want 1 (stderr %q)", res.code, res.stderr)
	}
	if res.stdout != "" {
		t.Errorf("stdout = %q, want empty", res.stdout)
	}
	for _, m := range mentions {
		if !strings.Contains(res.stderr, m) {
			t.Errorf("stderr %q does not mention %q", res.stderr, m)
		}
	}
	if !strings.Contains(res.stderr, "sw analyze --help") {
		t.Errorf("stderr %q has no pointer to `sw analyze --help`", res.stderr)
	}
	if n := rr.fs.readTotal() + rr.fs.identityTotal() + rr.fs.driveReads(); n != 0 {
		t.Errorf("the file system was used %d times although the call was invalid", n)
	}
	if rr.ui.count() != 0 {
		t.Errorf("the display was started for an invalid call")
	}
}

// ---------------------------------------------------------------------------
// Help

func TestRunHelpPrintsUsageAndExitsZero(t *testing.T) {
	for _, args := range [][]string{{"-h"}, {"--help"}, {"-help"}} {
		rr := newDataRig()
		env, root := tstQuietEnv(t)
		res := rr.run(t, args, env, false)
		if res.code != 0 {
			t.Errorf("%q: exit code %d, stderr %q", args, res.code, res.stderr)
		}
		if !strings.HasPrefix(res.stdout, "Usage: sw analyze [OPTIONS] [PATH]") {
			t.Errorf("%q: stdout does not begin with the usage line:\n%s", args, res.stdout)
		}
		for _, want := range []string{"--json", "-h, --help"} {
			if !strings.Contains(res.stdout, want) {
				t.Errorf("%q: help does not mention %q", args, want)
			}
		}
		for _, bad := range []string{"analyze.exe", "analyze-windows-x64.exe"} {
			if strings.Contains(res.stdout, bad) {
				t.Errorf("%q: help names the shipped file %q", args, bad)
			}
		}
		if res.stderr != "" {
			t.Errorf("%q: stderr = %q, want empty", args, res.stderr)
		}
		if n := rr.fs.readTotal() + rr.fs.identityTotal() + rr.fs.driveReads(); n != 0 {
			t.Errorf("%q: the file system was used %d times", args, n)
		}
		if rr.ui.count() != 0 {
			t.Errorf("%q: the display was started", args)
		}
		tstAssertNothingWritten(t, root)
	}
}

func TestRunHelpWinsOverOtherValidArguments(t *testing.T) {
	for _, args := range [][]string{
		{"--json", "--help"}, {"--help", "--json"}, {"--help", `C:\Data`}, {`C:\Data`, "--help"}, {"-h", "-json"},
	} {
		rr := newDataRig()
		env, _ := tstQuietEnv(t)
		res := rr.run(t, args, env, false)
		if res.code != 0 || !strings.HasPrefix(res.stdout, "Usage: sw analyze") || res.stderr != "" {
			t.Errorf("%q: exit %d, stdout %q, stderr %q", args, res.code, res.stdout, res.stderr)
		}
		if strings.Contains(res.stdout, `"scan_status"`) {
			t.Errorf("%q: JSON was written besides the help", args)
		}
		if rr.fs.readTotal() != 0 {
			t.Errorf("%q: something was measured", args)
		}
	}
}

// ---------------------------------------------------------------------------
// Invalid calls

func TestRunUnknownOptionFailsBeforeAnyMeasurement(t *testing.T) {
	for _, args := range [][]string{{"--bogus"}, {"-x"}, {"--JSON"}, {"--dry-run"}, {"--bogus", `C:\Data`}, {`C:\Data`, "--bogus"}} {
		rr := newDataRig()
		env, root := tstQuietEnv(t)
		res := rr.run(t, args, env, false)
		bad := "--bogus"
		for _, a := range args {
			if strings.HasPrefix(a, "-") {
				bad = a
			}
		}
		tstAssertUsageError(t, rr, res, bad)
		tstAssertNothingWritten(t, root)
	}
}

func TestRunRetiredPathOptionIsAnUnknownOption(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{"--path", `C:\Data`}, env, false)
	tstAssertUsageError(t, rr, res, "--path")
}

func TestRunSecondPathWordFails(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{`C:\Data`, `C:\Other`}, env, false)
	tstAssertUsageError(t, rr, res, `C:\Other`)
}

func TestRunDoubleDashEndsTheOptions(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{"--", "--json"}, env, false)
	if res.code != 1 || res.stdout != "" {
		t.Errorf(`"-- --json": exit %d, stdout %q: the word after -- is a path, not an option`, res.code, res.stdout)
	}
	if !strings.Contains(res.stderr, "--json") {
		t.Errorf(`"-- --json": stderr %q does not name the path`, res.stderr)
	}

	rr = newDataRig()
	res = rr.run(t, []string{"--", `C:\Data`}, env, false)
	if res.code != 0 {
		t.Errorf(`"-- C:\Data": exit %d, stderr %q`, res.code, res.stderr)
	}
	doc := tstDecode(t, res.stdout)
	if doc["path"] != `C:\Data` {
		t.Errorf(`"-- C:\Data": path = %v`, doc["path"])
	}

	rr = newDataRig()
	res = rr.run(t, []string{"--json", "--", `C:\Data`}, env, true)
	if res.code != 0 || res.stdout == "" {
		t.Errorf(`"--json -- C:\Data": exit %d, stdout %q`, res.code, res.stdout)
	}

	rr = newDataRig()
	res = rr.run(t, []string{"--", `C:\Data`, `C:\Other`}, env, false)
	tstAssertUsageError(t, rr, res, `C:\Other`)
}

func TestRunOptionsMayStandBeforeAndAfterThePath(t *testing.T) {
	for _, args := range [][]string{{"--json", `C:\Data`}, {`C:\Data`, "--json"}, {"-json", `C:\Data`}, {`C:\Data`, "-json"}} {
		rr := newDataRig()
		env, _ := tstQuietEnv(t)
		res := rr.run(t, args, env, true)
		if res.code != 0 {
			t.Errorf("%q: exit code %d, stderr %q", args, res.code, res.stderr)
			continue
		}
		doc := tstDecode(t, res.stdout)
		if doc["path"] != `C:\Data` {
			t.Errorf("%q: path = %v", args, doc["path"])
		}
		if rr.ui.count() != 0 {
			t.Errorf("%q: the display was started", args)
		}
	}
}

// ---------------------------------------------------------------------------
// Operating mode

func TestRunWithoutATerminalPrintsJSONAndStartsNoDisplay(t *testing.T) {
	rr := newDataRig()
	env, root := tstQuietEnv(t)
	res := rr.run(t, []string{`C:\Data`}, env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	tstDecode(t, res.stdout)
	if rr.ui.count() != 0 {
		t.Errorf("the display was started although stdout is not a terminal")
	}
	if res.stderr != "" {
		t.Errorf("stderr = %q, want empty", res.stderr)
	}
	tstAssertNothingWritten(t, root)
}

func TestRunJSONOptionPrintsJSONOnATerminal(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{"--json", `C:\Data`}, env, true)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	tstDecode(t, res.stdout)
	if rr.ui.count() != 0 {
		t.Errorf("the display was started although --json was given")
	}
}

func TestRunOnATerminalStartsTheDisplayForAFolder(t *testing.T) {
	rr := newDataRig()
	env, root := tstQuietEnv(t)
	res := rr.run(t, []string{`C:\Data`}, env, true)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	if res.stdout != "" {
		t.Errorf("stdout = %q, want empty (the display draws itself)", res.stdout)
	}
	if rr.ui.count() != 1 {
		t.Fatalf("the display was started %d times, want once", rr.ui.count())
	}
	p := newTstPump(t, rr.ui.model)
	p.size = tstSize(100, 30)
	p.start(p.m.Init())
	p.feed(p.size)
	if !p.settle(func() bool { return strings.Contains(tstStrip(p.m.View()), `C:\Data`) }) {
		t.Errorf("the display does not show the folder:\n%s", tstStrip(p.m.View()))
	}
	tstAssertNothingWritten(t, root)
}

func TestRunOnATerminalWithoutAPathStartsTheOverview(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, nil, env, true)
	if res.code != 0 || res.stdout != "" {
		t.Fatalf("exit %d, stdout %q, stderr %q", res.code, res.stdout, res.stderr)
	}
	if rr.ui.count() != 1 {
		t.Fatalf("the display was started %d times, want once", rr.ui.count())
	}
	p := newTstPump(t, rr.ui.model)
	p.size = tstSize(100, 30)
	p.start(p.m.Init())
	p.feed(p.size)
	if !p.settle(func() bool {
		v := tstStrip(p.m.View())
		return strings.Contains(v, `C:\`) && strings.Contains(v, `D:\`)
	}) {
		t.Fatalf("the overview does not show the drives:\n%s", tstStrip(p.m.View()))
	}
}

func TestRunDisplayThatCannotStartExitsOne(t *testing.T) {
	rr := newDataRig()
	rr.ui.err = errors.New("no console available")
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{`C:\Data`}, env, true)
	if res.code != 1 {
		t.Errorf("exit code %d, want 1", res.code)
	}
	if res.stdout != "" || res.stderr == "" {
		t.Errorf("stdout %q, stderr %q: want the error on stderr only", res.stdout, res.stderr)
	}
}

func TestRunWithoutATerminalAndWithoutAPathPrintsTheOverviewAsJSON(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, nil, env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	doc := tstDecode(t, res.stdout)
	if doc["overview"] != true {
		t.Errorf("overview = %v, want true", doc["overview"])
	}
	if rr.ui.count() != 0 {
		t.Errorf("the display was started")
	}
}

func TestRunIgnoresTheRetiredVariables(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	plain := rr.run(t, []string{`C:\Data`}, env, false)
	rr2 := newDataRig()
	env2 := tstEnvWith(env, "SWEEPR_ANALYZE_LIVE_SORT", "1", "SWEEPR_ANALYZE_RECYCLE_FIXTURE", "x")
	with := rr2.run(t, []string{`C:\Data`}, env2, false)
	if plain.code != 0 || with.code != 0 || plain.stdout != with.stdout {
		t.Errorf("the retired variables changed the result: %d/%d\n%s\n%s", plain.code, with.code, plain.stdout, with.stdout)
	}
}

// ---------------------------------------------------------------------------
// Target

func TestRunEnvironmentPathWinsOverThePathWord(t *testing.T) {
	rr := newDataRig()
	rr.fs.dir(`C:\Other`)
	env, _ := tstQuietEnv(t)
	env["SWEEPR_ANALYZE_PATH"] = `C:\Data`
	res := rr.run(t, []string{`C:\Other`}, env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	if doc := tstDecode(t, res.stdout); doc["path"] != `C:\Data` {
		t.Errorf("path = %v, want C:\\Data (the variable wins)", doc["path"])
	}
}

func TestRunEnvironmentPathAloneSelectsTheTarget(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	env["SWEEPR_ANALYZE_PATH"] = `C:\Data`
	res := rr.run(t, nil, env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	if doc := tstDecode(t, res.stdout); doc["path"] != `C:\Data` || doc["overview"] != false {
		t.Errorf("doc = path %v, overview %v", doc["path"], doc["overview"])
	}
}

func TestRunEnvironmentPathOfOnlyWhitespaceCountsAsUnset(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	env["SWEEPR_ANALYZE_PATH"] = " \t "
	res := rr.run(t, []string{`C:\Data`}, env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	if doc := tstDecode(t, res.stdout); doc["path"] != `C:\Data` {
		t.Errorf("path = %v, want the path word", doc["path"])
	}
	rr = newDataRig()
	res = rr.run(t, nil, env, false)
	if doc := tstDecode(t, res.stdout); doc["overview"] != true {
		t.Errorf("overview = %v, want true: whitespace is no target", doc["overview"])
	}
}

func TestRunEnvironmentPathIsTrimmed(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	env["SWEEPR_ANALYZE_PATH"] = `  C:\Data  `
	res := rr.run(t, nil, env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	if doc := tstDecode(t, res.stdout); doc["path"] != `C:\Data` {
		t.Errorf("path = %v", doc["path"])
	}
}

func TestRunTildeStandsForTheProfileFolder(t *testing.T) {
	for in, want := range map[string]string{
		`~\Downloads`: `C:\Users\Example\Downloads`,
		`~/Downloads`: `C:\Users\Example\Downloads`,
		`~`:           `C:\Users\Example`,
	} {
		rr := newDataRig()
		env, _ := tstQuietEnv(t)
		res := rr.run(t, []string{in}, env, false)
		if res.code != 0 {
			t.Errorf("%q: exit code %d, stderr %q", in, res.code, res.stderr)
			continue
		}
		if doc := tstDecode(t, res.stdout); doc["path"] != want {
			t.Errorf("%q: path = %v, want %s", in, doc["path"], want)
		}
	}
}

func TestRunTildeWithANameStaysUnchanged(t *testing.T) {
	rr := newDataRig()
	rr.fs.dir(`C:\Users\Example\~name`)
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{`~name`}, env, false)
	if res.code != 1 || !strings.Contains(res.stderr, "~name") {
		t.Errorf("exit %d, stderr %q: ~name must not be replaced by the profile folder", res.code, res.stderr)
	}
}

func TestRunTildeFallsBackToTheHomeFolderOfTheRuntime(t *testing.T) {
	home := `D:\Profiles\Fallback`
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	rr := newDataRig()
	rr.fs.dir(home + `\Docs`)
	env, _ := tstQuietEnv(t)
	env["USERPROFILE"] = ""
	res := rr.run(t, []string{`~\Docs`}, env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	if doc := tstDecode(t, res.stdout); doc["path"] != home+`\Docs` {
		t.Errorf("path = %v", doc["path"])
	}
}

func TestRunDriveWithoutAPathMeansTheRoot(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{`D:`}, env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	if doc := tstDecode(t, res.stdout); doc["path"] != `D:\` {
		t.Errorf("path = %v, want D:\\", doc["path"])
	}
}

func TestRunTargetIsCleaned(t *testing.T) {
	for in, want := range map[string]string{
		`C:\Data\`:                 `C:\Data`,
		`C:\Data\.\alpha\..`:       `C:\Data`,
		`C:\Data\\alpha`:           `C:\Data\alpha`,
		`C:/Data/alpha`:            `C:\Data\alpha`,
		`C:\Data\alpha\..\..\Data`: `C:\Data`,
		`C:\`:                      `C:\`,
	} {
		rr := newDataRig()
		env, _ := tstQuietEnv(t)
		res := rr.run(t, []string{in}, env, false)
		if res.code != 0 {
			t.Errorf("%q: exit code %d, stderr %q", in, res.code, res.stderr)
			continue
		}
		if doc := tstDecode(t, res.stdout); doc["path"] != want {
			t.Errorf("%q: path = %v, want %s", in, doc["path"], want)
		}
	}
}

func TestRunAcceptsVerbatimAndUNCTargets(t *testing.T) {
	for _, in := range []string{`\\?\C:\Data`, `\\srv\share\x`, `\\?\UNC\srv\share\x`} {
		rr := newDataRig()
		rr.fs.dir(`\\srv\share\x\f`)
		env, _ := tstQuietEnv(t)
		res := rr.run(t, []string{in}, env, false)
		if res.code != 0 {
			t.Errorf("%q: exit code %d, stderr %q", in, res.code, res.stderr)
			continue
		}
		tstDecode(t, res.stdout)
	}
}

func TestRunMissingTargetFailsWithThePath(t *testing.T) {
	for _, mode := range []string{"word", "env"} {
		rr := newDataRig()
		env, _ := tstQuietEnv(t)
		args := []string{`C:\Nope`}
		if mode == "env" {
			env["SWEEPR_ANALYZE_PATH"] = `C:\Nope`
			args = nil
		}
		res := rr.run(t, args, env, true)
		if res.code != 1 || res.stdout != "" {
			t.Errorf("%s: exit %d, stdout %q, want 1 and nothing", mode, res.code, res.stdout)
		}
		if !strings.Contains(res.stderr, `C:\Nope`) {
			t.Errorf("%s: stderr %q does not name the path", mode, res.stderr)
		}
		if rr.ui.count() != 0 {
			t.Errorf("%s: the display was started for a missing folder", mode)
		}
	}
}

func TestRunFileAsTargetFailsWithThePath(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{`C:\Data\notes.txt`}, env, false)
	if res.code != 1 || res.stdout != "" {
		t.Errorf("exit %d, stdout %q, want 1 and nothing", res.code, res.stdout)
	}
	if !strings.Contains(res.stderr, `C:\Data\notes.txt`) {
		t.Errorf("stderr %q does not name the path", res.stderr)
	}
}

// ---------------------------------------------------------------------------
// Failures and channels in the JSON mode

func TestRunUnreadableRootFailsInJSONMode(t *testing.T) {
	rr := newDataRig()
	rr.fs.failDir(`C:\Data`, errTstAccess)
	env, root := tstQuietEnv(t)
	res := rr.run(t, []string{"--json", `C:\Data`}, env, true)
	if res.code != 1 || res.stdout != "" {
		t.Errorf("exit %d, stdout %q, want 1 and nothing", res.code, res.stdout)
	}
	if !strings.Contains(res.stderr, `C:\Data`) {
		t.Errorf("stderr %q does not name the path", res.stderr)
	}
	tstAssertNothingWritten(t, root)
}

func TestRunJSONWriteFailureExitsOne(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	var errOut bytes.Buffer
	code := tstRunWith(t, rr.deps(), []string{"--json", `C:\Data`}, env, false, tstFailWriter{}, &errOut)
	if code != 1 {
		t.Errorf("exit code %d, want 1", code)
	}
	if errOut.Len() == 0 {
		t.Errorf("stderr is empty, want a message")
	}
}

type tstFailWriter struct{}

func (tstFailWriter) Write([]byte) (int, error) { return 0, errors.New("broken pipe") }

func TestRunOnlyKnowsTheExitCodesZeroAndOne(t *testing.T) {
	cases := []struct {
		args     []string
		terminal bool
	}{
		{[]string{"--bogus"}, false}, {[]string{"-h"}, false}, {[]string{`C:\Nope`}, false}, {[]string{`C:\Data`}, false},
		{nil, false}, {[]string{`C:\a`, `C:\b`}, true},
	}
	for _, c := range cases {
		rr := newDataRig()
		env, _ := tstQuietEnv(t)
		if res := rr.run(t, c.args, env, c.terminal); res.code != 0 && res.code != 1 {
			t.Errorf("%q: exit code %d", c.args, res.code)
		}
	}
}
