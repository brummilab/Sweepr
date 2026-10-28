package main

// Arguments, operating modes, exit codes and channels of Run (ST-1 to ST-5,
// ST-24 on the platform-independent level).

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

// tstAssertSingleDocument checks the one-shot output: exactly one indented
// JSON object with a trailing newline, nothing else on stdout.
func tstAssertSingleDocument(t *testing.T, out string) map[string]any {
	t.Helper()
	if strings.HasPrefix(out, "\xef\xbb\xbf") {
		t.Errorf("stdout starts with a byte-order mark")
	}
	if strings.ContainsRune(out, 0x1b) {
		t.Errorf("stdout contains a control sequence: %q", out)
	}
	if !strings.HasSuffix(out, "\n") || strings.HasSuffix(out, "\n\n") {
		t.Errorf("stdout must end with exactly one newline")
	}
	if strings.Contains(out, "\r") {
		t.Errorf("stdout contains carriage returns")
	}
	if !strings.Contains(out, "\n  \"") {
		t.Errorf("one-shot output is not indented by two spaces:\n%s", out)
	}
	dec := json.NewDecoder(strings.NewReader(out))
	var doc map[string]any
	if err := dec.Decode(&doc); err != nil {
		t.Fatalf("stdout is not a JSON object: %v\n%s", err, out)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		t.Errorf("stdout holds more than one JSON document")
	}
	for _, k := range tstTopLevelKeys {
		if _, ok := doc[k]; !ok {
			t.Errorf("key %q missing in the document", k)
		}
	}
	return doc
}

func tstAssertUsageError(t *testing.T, res tstResult, w *fakeWorld, mentions ...string) {
	t.Helper()
	if res.code != 1 {
		t.Errorf("exit code %d, want 1", res.code)
	}
	if res.stdout != "" {
		t.Errorf("stdout = %q, want empty", res.stdout)
	}
	lower := strings.ToLower(res.stderr)
	for _, m := range mentions {
		if !strings.Contains(lower, strings.ToLower(m)) {
			t.Errorf("stderr %q does not mention %q", res.stderr, m)
		}
	}
	lines := strings.Split(strings.TrimRight(res.stderr, "\r\n"), "\n")
	if last := lines[len(lines)-1]; !strings.Contains(last, "--help") {
		t.Errorf("last stderr line %q has no pointer to --help", last)
	}
	if n := w.totalReads(); n != 0 {
		t.Errorf("sources were read %d times although the call was invalid", n)
	}
}

// ---------------------------------------------------------------------------
// ST-1: operating mode

func TestRunWithoutTerminalMeasuresOnceAndPrintsJSON(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	res := tstRun(t, w, clk, nil, e.env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	doc := tstAssertSingleDocument(t, res.stdout)
	for _, k := range tstTopLevelKeys {
		tstWantNotNull(t, doc, k)
	}
	if res.stderr != "" {
		t.Errorf("stderr = %q, want empty when every area was measured", res.stderr)
	}
	e.assertUntouched(t)
}

func TestRunJSONOptionMeasuresOnceEvenOnATerminal(t *testing.T) {
	for _, args := range [][]string{{"--json"}, {"-json"}} {
		e := tstIsolated(t)
		clk := newFakeClock()
		w := newHealthyWorld(clk)
		res := tstRun(t, w, clk, args, e.env, true)
		if res.code != 0 {
			t.Errorf("%q: exit code %d, stderr %q", args, res.code, res.stderr)
			continue
		}
		tstAssertSingleDocument(t, res.stdout)
		e.assertUntouched(t)
	}
}

func TestRunIntervalWithoutWatchIsIgnored(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	res := tstRun(t, w, clk, []string{"--interval=5s"}, e.env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	tstAssertSingleDocument(t, res.stdout)
}

func TestRunWatchOptionStreamsEvenOnATerminal(t *testing.T) {
	for _, args := range [][]string{{"--watch"}, {"-watch"}, {"--watch", "--json"}, {"--json", "--watch"}} {
		e := tstIsolated(t)
		clk := newFakeClock()
		w := newHealthyWorld(clk)
		out := &tstLineLimitWriter{limit: 2}
		var errOut bytes.Buffer
		code := tstRunWith(t, w, clk, args, e.env, true, out, &errOut)
		if code != 0 {
			t.Errorf("%q: exit code %d, stderr %q", args, code, errOut.String())
		}
		lines := out.lines()
		if len(lines) != 2 {
			t.Errorf("%q: %d lines, want 2", args, len(lines))
			continue
		}
		for _, l := range lines {
			if strings.HasPrefix(l, " ") || strings.HasPrefix(l, "{\n") || !json.Valid([]byte(l)) {
				t.Errorf("%q: stream entry is not a compact JSON line: %q", args, l)
			}
		}
		e.assertUntouched(t)
	}
}

// ---------------------------------------------------------------------------
// ST-1, ST-4: rejected calls

func TestRunUnknownOptionsAreRejected(t *testing.T) {
	cases := []struct {
		args     []string
		mentions []string
	}{
		{[]string{"--bogus"}, []string{"--bogus"}},
		{[]string{"-x"}, []string{"-x"}},
		{[]string{"--json", "--bogus"}, []string{"--bogus"}},
		{[]string{"--watch", "--bogus"}, []string{"--bogus"}},
		{[]string{"--proc-cpu-alerts"}, []string{"proc-cpu-alerts"}},
		{[]string{"--proc-cpu-threshold=50"}, []string{"proc-cpu-threshold"}},
		{[]string{"--proc-cpu-window", "5s"}, []string{"proc-cpu-window"}},
		{[]string{"--version"}, []string{"--version"}},
		// Option names are lower case.
		{[]string{"--JSON"}, []string{"JSON"}},
		{[]string{"-Watch"}, []string{"Watch"}},
		{[]string{"--Interval=2s"}, []string{"Interval"}},
		{[]string{"--HELP"}, []string{"HELP"}},
	}
	for _, c := range cases {
		for _, terminal := range []bool{false, true} {
			e := tstIsolated(t)
			clk := newFakeClock()
			w := newHealthyWorld(clk)
			res := tstRun(t, w, clk, c.args, e.env, terminal)
			tstAssertUsageError(t, res, w, c.mentions...)
			e.assertUntouched(t)
		}
	}
}

func TestRunSuperfluousWordsAreRejected(t *testing.T) {
	for _, args := range [][]string{{"foo"}, {"--json", "foo"}, {"foo", "--json"}, {"--watch", "foo"}, {"--json", "--json", "bar"}} {
		e := tstIsolated(t)
		clk := newFakeClock()
		w := newHealthyWorld(clk)
		res := tstRun(t, w, clk, args, e.env, false)
		word := "foo"
		if args[len(args)-1] == "bar" {
			word = "bar"
		}
		tstAssertUsageError(t, res, w, word)
	}
}

// ---------------------------------------------------------------------------
// ST-2: option values

func TestRunInvalidIntervalIsRejectedWithOrWithoutWatch(t *testing.T) {
	cases := []struct {
		args     []string
		mentions []string
	}{
		{[]string{"--watch", "--interval=abc"}, []string{"interval", "abc"}},
		{[]string{"--watch", "--interval=1"}, []string{"interval", "1"}},
		{[]string{"--watch", "--interval="}, []string{"interval"}},
		{[]string{"--watch", "--interval", ""}, []string{"interval"}},
		{[]string{"--watch", "--interval=0s"}, []string{"interval", "0s"}},
		{[]string{"--watch", "--interval=-1s"}, []string{"interval", "-1s"}},
		{[]string{"--watch", "--interval", "0s"}, []string{"interval", "0s"}},
		{[]string{"--watch", "--interval"}, []string{"interval"}},
		{[]string{"--interval=abc"}, []string{"interval", "abc"}},
		{[]string{"--interval=0s"}, []string{"interval", "0s"}},
		{[]string{"--json", "--interval=-5s"}, []string{"interval", "-5s"}},
		{[]string{"-interval=xyz"}, []string{"interval", "xyz"}},
	}
	for _, c := range cases {
		e := tstIsolated(t)
		clk := newFakeClock()
		w := newHealthyWorld(clk)
		res := tstRun(t, w, clk, c.args, e.env, false)
		tstAssertUsageError(t, res, w, c.mentions...)
		e.assertUntouched(t)
	}
}

// ---------------------------------------------------------------------------
// ST-3: help

func TestRunHelpPrintsUsageAndExitsWithZero(t *testing.T) {
	for _, args := range [][]string{{"-h"}, {"--help"}, {"-help"}} {
		for _, terminal := range []bool{false, true} {
			e := tstIsolated(t)
			clk := newFakeClock()
			w := newHealthyWorld(clk)
			res := tstRun(t, w, clk, args, e.env, terminal)
			if res.code != 0 {
				t.Errorf("%q: exit code %d", args, res.code)
			}
			if !strings.HasPrefix(res.stdout, "Usage: sw status") {
				t.Errorf("%q: help does not begin with \"Usage: sw status\": %q", args, res.stdout)
			}
			for _, opt := range []string{"--json", "--watch", "--interval", "-h", "--help"} {
				if !strings.Contains(res.stdout, opt) {
					t.Errorf("%q: help does not mention %s", args, opt)
				}
			}
			for _, name := range []string{"status.exe", "status-windows-x64.exe"} {
				if strings.Contains(res.stdout, name) {
					t.Errorf("%q: help names the file %s", args, name)
				}
			}
			if res.stderr != "" {
				t.Errorf("%q: stderr = %q, want empty", args, res.stderr)
			}
			if n := w.totalReads(); n != 0 {
				t.Errorf("%q: help measured (%d reads)", args, n)
			}
			e.assertUntouched(t)
		}
	}
}

func TestRunHelpWinsOverEarlierValidArguments(t *testing.T) {
	cases := [][]string{
		{"--json", "--help"},
		{"--watch", "--help"},
		{"--watch", "--interval=2s", "-h"},
		{"--interval=5s", "-help"},
		{"--json", "--watch", "--help"},
	}
	for _, args := range cases {
		e := tstIsolated(t)
		clk := newFakeClock()
		w := newHealthyWorld(clk)
		res := tstRun(t, w, clk, args, e.env, false)
		if res.code != 0 {
			t.Errorf("%q: exit code %d, stderr %q", args, res.code, res.stderr)
		}
		if !strings.HasPrefix(res.stdout, "Usage: sw status") {
			t.Errorf("%q: stdout is not the help: %q", args, res.stdout)
		}
		if strings.Contains(res.stdout, "collected_at") {
			t.Errorf("%q: JSON printed next to the help", args)
		}
		if res.stderr != "" || w.totalReads() != 0 {
			t.Errorf("%q: stderr %q, reads %d", args, res.stderr, w.totalReads())
		}
	}
}

// ---------------------------------------------------------------------------
// ST-5: one-shot measurement

func TestRunOneShotWaitsForTheMinimumWindow(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	res := tstRun(t, w, clk, []string{"--json"}, e.env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	reads := w.readTimes("cpu")
	if len(reads) < 2 {
		t.Fatalf("CPU source read %d times, want a reading before and one after the window", len(reads))
	}
	if gap := reads[len(reads)-1].Sub(reads[0]); gap < 250*time.Millisecond {
		t.Errorf("one-shot window is %v, want at least 250ms", gap)
	}
}

func TestRunOneShotWithUnreadableProcessTableStillSucceeds(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	w.procsErr = errFakeUnavailable
	res := tstRun(t, w, clk, nil, e.env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	doc := tstAssertSingleDocument(t, res.stdout)
	tstWantNull(t, doc, "procs")
	tstWantNull(t, doc, "top_processes")
	for _, k := range []string{"platform", "uptime_seconds", "cpu", "memory", "disks", "disk_io", "network", "network_total"} {
		tstWantNotNull(t, doc, k)
	}
	if !strings.Contains(strings.ToLower(res.stderr), "process") {
		t.Errorf("stderr %q does not name the area that could not be measured", res.stderr)
	}
}

func TestRunOneShotNamesEveryUnmeasurableAreaOnStderr(t *testing.T) {
	cases := []struct {
		name string
		fail func(w *fakeWorld)
		area string
	}{
		{"cpu", func(w *fakeWorld) { w.cpuErr = errFakeUnavailable }, "cpu"},
		{"memory", func(w *fakeWorld) { w.memErr = errFakeUnavailable }, "memory"},
		{"drives", func(w *fakeWorld) { w.drivesErr = errFakeUnavailable }, "disk"},
		{"network", func(w *fakeWorld) { w.netErr = errFakeUnavailable }, "network"},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			e := tstIsolated(t)
			clk := newFakeClock()
			w := newHealthyWorld(clk)
			c.fail(w)
			res := tstRun(t, w, clk, nil, e.env, false)
			if res.code != 0 {
				t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
			}
			tstAssertSingleDocument(t, res.stdout)
			if !strings.Contains(strings.ToLower(res.stderr), c.area) {
				t.Errorf("stderr %q does not name the area %q", res.stderr, c.area)
			}
		})
	}
}

func TestRunOneShotFailsWhenNothingIsMeasurable(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	w.failAll()
	res := tstRun(t, w, clk, nil, e.env, false)
	if res.code != 1 {
		t.Errorf("exit code %d, want 1", res.code)
	}
	if res.stdout != "" {
		t.Errorf("stdout = %q, want empty", res.stdout)
	}
	lower := strings.ToLower(res.stderr)
	for _, area := range []string{"cpu", "memory", "disk", "network", "process"} {
		if !strings.Contains(lower, area) {
			t.Errorf("stderr %q does not name the failed area %q", res.stderr, area)
		}
	}
	e.assertUntouched(t)
}

func TestRunOneShotCountsAnIdleCPUAsMeasured(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	w.set(func() {
		w.memErr, w.swapErr, w.drivesErr, w.diskErr = errFakeUnavailable, errFakeUnavailable, errFakeUnavailable, errFakeUnavailable
		w.netErr, w.adaptersErr, w.procsErr, w.uptimeErr, w.platformErr = errFakeUnavailable, errFakeUnavailable, errFakeUnavailable, errFakeUnavailable, errFakeUnavailable
		w.cpuSteps = []fakeCPU{{Idle: 10_000_000, Total: 10_000_000}, {Idle: 10_000_000, Total: 10_000_000}}
	})
	res := tstRun(t, w, clk, nil, e.env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q; a fully idle CPU is a valid measurement", res.code, res.stderr)
	}
	doc := tstAssertSingleDocument(t, res.stdout)
	tstWantNum(t, doc, 0, "cpu", "usage")
}

func TestRunOneShotFailsWhenTheDocumentCannotBeWritten(t *testing.T) {
	e := tstIsolated(t)
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	var errOut bytes.Buffer
	code := tstRunWith(t, w, clk, nil, e.env, false, tstFailingWriter{}, &errOut)
	if code != 1 {
		t.Errorf("exit code %d, want 1", code)
	}
}

type tstFailingWriter struct{}

func (tstFailingWriter) Write([]byte) (int, error) { return 0, errors.New("closed") }

// ---------------------------------------------------------------------------
// ST-10: system drive from the environment

func TestRunPutsTheSystemDriveFirst(t *testing.T) {
	cases := []struct {
		systemDrive string
		want        []string
	}{
		{"E:", []string{`E:\`, `C:\`, `D:\`}},
		{"D:", []string{`D:\`, `C:\`, `E:\`}},
		{"", []string{`C:\`, `D:\`, `E:\`}},
		{"C:", []string{`C:\`, `D:\`, `E:\`}},
	}
	for _, c := range cases {
		e := tstIsolated(t).with("SystemDrive", c.systemDrive)
		clk := newFakeClock()
		w := newHealthyWorld(clk)
		w.drives = []fakeDrive{
			{Mount: `D:\`, Total: 64 * tstGiB, Free: 44 * tstGiB, FS: "NTFS"},
			{Mount: `E:\`, Total: 64 * tstGiB, Free: 44 * tstGiB, FS: "NTFS"},
			{Mount: `C:\`, Total: 100 * tstGiB, Free: 60 * tstGiB, FS: "NTFS"},
		}
		res := tstRun(t, w, clk, nil, e.env, false)
		if res.code != 0 {
			t.Fatalf("SystemDrive=%q: exit code %d, stderr %q", c.systemDrive, res.code, res.stderr)
		}
		doc := tstAssertSingleDocument(t, res.stdout)
		var got []string
		for _, d := range tstArr(t, doc, "disks") {
			m, _ := tstAt(d, "mount")
			s, _ := m.(string)
			got = append(got, s)
		}
		if !tstSameStrings(got, c.want) {
			t.Errorf("SystemDrive=%q: mounts %q, want %q", c.systemDrive, got, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// Fixed environment values that must have no effect

func TestRunIgnoresDryRunAndLogSwitches(t *testing.T) {
	e := tstIsolated(t)
	for k, v := range map[string]string{"SWEEPR_DRY_RUN": "1", "SWEEPR_NO_OPLOG": "1", "_SWEEPR_OPLOG_RUN_ID": "x", "NO_COLOR": "1"} {
		e = e.with(k, v)
	}
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	res := tstRun(t, w, clk, nil, e.env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	tstAssertSingleDocument(t, res.stdout)
	e.assertUntouched(t)
}
