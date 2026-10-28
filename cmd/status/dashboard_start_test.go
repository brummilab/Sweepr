package main

// The choice between the interactive display and the JSON modes,
// checked with a replaced start function instead of a terminal.

import (
	"bytes"
	"io"
	"testing"
)

type tstStartRecorder struct {
	calls int
	cfg   DashboardConfig
	code  int
}

func (r *tstStartRecorder) start(cfg DashboardConfig) int {
	r.calls++
	r.cfg = cfg
	return r.code
}

func tstRunWithDisplay(t *testing.T, w *fakeWorld, clk *fakeClock, args []string, env map[string]string,
	terminal bool, rec *tstStartRecorder) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := Run(args, env, &out, &errOut, terminal, tstSources(w), clk, WithDashboard(rec.start))
	return code, out.String(), errOut.String()
}

func TestRunOnATerminalStartsTheDisplay(t *testing.T) {
	e := tstIsolated(t)
	e.writePrefs(t, "cpu_cores=4\n")
	clk := newFakeClock()
	w := newHealthyWorld(clk)
	rec := &tstStartRecorder{code: 7}
	code, stdout, stderr := tstRunWithDisplay(t, w, clk, nil, e.env, true, rec)
	if rec.calls != 1 {
		t.Fatalf("display started %d times, want once", rec.calls)
	}
	if code != 7 {
		t.Errorf("exit code %d, want the code of the display (7)", code)
	}
	if stdout != "" || stderr != "" {
		t.Errorf("Run wrote around the display: stdout %q, stderr %q", stdout, stderr)
	}
	if n := w.totalReads(); n != 0 {
		t.Errorf("Run read the sources %d times itself; the display measures", n)
	}
	if rec.cfg.Prefs == nil {
		t.Fatal("the display got no settings store")
	}
	if v, ok := rec.cfg.Prefs.Get("cpu_cores"); !ok || v != "4" {
		t.Errorf("settings store reads %q, %v; want the saved 4", v, ok)
	}
	if rec.cfg.Env["SystemDrive"] != "C:" {
		t.Errorf("the display did not get the environment: %v", rec.cfg.Env)
	}
}

func TestRunDoesNotStartTheDisplayInTheOtherModes(t *testing.T) {
	cases := []struct {
		name     string
		args     []string
		terminal bool
		code     int
	}{
		{"no terminal", nil, false, 0},
		{"json on a terminal", []string{"--json"}, true, 0},
		{"watch on a terminal", []string{"--watch"}, true, 0},
		{"help on a terminal", []string{"--help"}, true, 0},
		{"bad option on a terminal", []string{"--bogus"}, true, 1},
		{"bad interval on a terminal", []string{"--interval=0s"}, true, 1},
		{"extra word on a terminal", []string{"foo"}, true, 1},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			e := tstIsolated(t)
			clk := newFakeClock()
			w := newHealthyWorld(clk)
			rec := &tstStartRecorder{code: 7}
			var errOut bytes.Buffer
			var out io.Writer = &bytes.Buffer{}
			if c.args != nil && c.args[0] == "--watch" {
				// A line limit keeps the stream from running forever.
				out = &tstLineLimitWriter{limit: 1}
			}
			code := Run(c.args, e.env, out, &errOut, c.terminal, tstSources(w), clk, WithDashboard(rec.start))
			if rec.calls != 0 {
				t.Errorf("the display started although the call was %s", c.name)
			}
			if code != c.code {
				t.Errorf("exit code %d, want %d", code, c.code)
			}
			e.assertUntouched(t)
		})
	}
}
