package main

// Two protections that no other test reaches: names read from the system
// cannot inject terminal instructions, and a settings file that cannot be
// read is never replaced.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFrameDropsControlCharactersFromNames(t *testing.T) {
	doc := tstCopyDoc(tstBaseDoc())
	procs := doc["top_processes"].([]any)
	procs[0].(map[string]any)["name"] = "evil\x1b[31mname\x07"
	disks := doc["disks"].([]any)
	disks[0].(map[string]any)["mount"] = "C\x1b]0;title\x07:\\"
	for _, color := range []bool{false, true} {
		frame := tstRenderFrame(tstSnapshotFromDoc(t, doc), 2, 100, 60, color)
		if strings.Contains(frame, "\x1b[31m") || strings.Contains(frame, "\x1b]0;") || strings.Contains(frame, "\x07") {
			t.Errorf("color=%v: a control character of a name reached the frame: %q", color, frame)
		}
		if !strings.Contains(frame, "evil[31mname") {
			t.Errorf("color=%v: the printable part of the name is missing:\n%s", color, frame)
		}
	}
}

func TestPrefsSetDoesNotReplaceAFileItCannotRead(t *testing.T) {
	e := tstIsolated(t)
	// A folder where the file should be: reading fails with an error other
	// than "does not exist".
	if err := os.MkdirAll(filepath.Join(e.prefsFile(), "keep"), 0o755); err != nil {
		t.Fatal(err)
	}
	tstOpenPrefs(e.env).Set("cpu_cores", "4")
	fi, err := os.Stat(e.prefsFile())
	if err != nil || !fi.IsDir() {
		t.Errorf("the unreadable settings file was replaced: %v, %v", fi, err)
	}
	for _, name := range tstDirNames(t, filepath.Dir(e.prefsFile())) {
		if strings.Contains(name, ".tmp") {
			t.Errorf("temporary file %q left behind", name)
		}
	}
}
