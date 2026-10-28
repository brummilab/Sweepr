package main

// Saving survives a read or a replace that fails for a moment, as happens on
// Windows while another program has the settings file open.

import (
	"errors"
	"os"
	"testing"
	"time"
)

func TestPrefsSetRetriesAReplaceThatFailsForAMoment(t *testing.T) {
	e := tstIsolated(t)
	e.writePrefs(t, "x=1\n")
	p := tstOpenPrefs(e.env)
	var pauses []time.Duration
	p.pause = func(d time.Duration) { pauses = append(pauses, d) }
	fail := 3
	p.rename = func(from, to string) error {
		if fail > 0 {
			fail--
			return errors.New("sharing violation")
		}
		return os.Rename(from, to)
	}
	p.Set("cpu_cores", "4")
	if got := e.readPrefs(t); got != "cpu_cores=4\nx=1\n" {
		t.Errorf("file = %q, want the change saved after the transient failures", got)
	}
	if len(pauses) != 3 {
		t.Errorf("paused %d times, want once per failed attempt (3)", len(pauses))
	}
	for _, d := range pauses {
		if d <= 0 || d > maxSavePause {
			t.Errorf("pause %v outside 0..%v", d, maxSavePause)
		}
	}
	if names := tstDirNames(t, e.data+"/config"); !tstSameStrings(names, []string{"status_prefs", "status_prefs.lock"}) {
		t.Errorf("settings folder holds %q", names)
	}
}

func TestPrefsSetRetriesAReadThatFailsForAMoment(t *testing.T) {
	e := tstIsolated(t)
	e.writePrefs(t, "x=1\n")
	p := tstOpenPrefs(e.env)
	p.pause = func(time.Duration) {}
	fail := 2
	p.readFile = func(name string) ([]byte, error) {
		if fail > 0 {
			fail--
			return nil, errors.New("sharing violation")
		}
		return os.ReadFile(name)
	}
	p.Set("cpu_cores", "4")
	if got := e.readPrefs(t); got != "cpu_cores=4\nx=1\n" {
		t.Errorf("file = %q; the existing key must survive a transient read failure", got)
	}
}

func TestPrefsSetGivesUpAfterTheAttemptsAndLeavesNothingBehind(t *testing.T) {
	e := tstIsolated(t)
	e.writePrefs(t, "x=1\n")
	p := tstOpenPrefs(e.env)
	pauses := 0
	p.pause = func(time.Duration) { pauses++ }
	attempts := 0
	p.rename = func(string, string) error { attempts++; return errors.New("access denied") }
	p.Set("cpu_cores", "4")
	if attempts != saveAttempts || pauses != saveAttempts-1 {
		t.Errorf("%d attempts and %d pauses, want %d and %d", attempts, pauses, saveAttempts, saveAttempts-1)
	}
	if got := e.readPrefs(t); got != "x=1\n" {
		t.Errorf("file = %q, want it unchanged", got)
	}
	if names := tstDirNames(t, e.data+"/config"); !tstSameStrings(names, []string{"status_prefs", "status_prefs.lock"}) {
		t.Errorf("temporary file left behind: %q", names)
	}
}

func TestPrefsSetKeepsAFileThatStaysUnreadable(t *testing.T) {
	e := tstIsolated(t)
	e.writePrefs(t, "x=1\n")
	p := tstOpenPrefs(e.env)
	p.pause = func(time.Duration) {}
	p.readFile = func(string) ([]byte, error) { return nil, errors.New("access denied") }
	p.Set("cpu_cores", "4")
	if got := e.readPrefs(t); got != "x=1\n" {
		t.Errorf("file = %q; a file that cannot be read must not be replaced", got)
	}
}
