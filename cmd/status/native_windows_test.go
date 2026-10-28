//go:build windows

package main

// Plausibility of the real Windows sources. These tests run only on Windows
// (the Windows CI); they check ranges and structure, never fixed values.

import (
	"regexp"
	"strings"
	"testing"
)

func TestWindowsOneShotMeasuresThisMachine(t *testing.T) {
	res := tstChildMain(t, []string{"--json"})
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	doc := tstAssertSingleDocument(t, res.stdout)

	logical, _ := tstAt(doc, "cpu", "logical_cpu")
	if f, ok := logical.(float64); !ok || f < 1 {
		t.Errorf("cpu.logical_cpu = %v, want at least 1", logical)
	}
	if n := len(tstArr(t, doc, "cpu", "per_core")); float64(n) != logical {
		t.Errorf("cpu.per_core has %d values, logical_cpu is %v", n, logical)
	}
	total, _ := tstAt(doc, "memory", "total")
	used, _ := tstAt(doc, "memory", "used")
	if f, ok := total.(float64); !ok || f <= 0 {
		t.Errorf("memory.total = %v, want > 0", total)
	}
	if u, ok := used.(float64); !ok || u < 0 || u > total.(float64) {
		t.Errorf("memory.used = %v, want 0..total", used)
	}
	if v, _ := tstAt(doc, "uptime_seconds"); v == nil || v.(float64) <= 0 {
		t.Errorf("uptime_seconds = %v, want > 0", v)
	}
	if v, _ := tstAt(doc, "platform"); !regexp.MustCompile(`^windows \d+\.\d+\.\d+$`).MatchString(tstString(v)) {
		t.Errorf("platform = %v, want windows <major>.<minor>.<build>", v)
	}
	if v, _ := tstAt(doc, "procs"); v == nil || v.(float64) < 1 {
		t.Errorf("procs = %v, want at least 1", v)
	}
	disks := tstArr(t, doc, "disks")
	if len(disks) == 0 {
		t.Fatal("disks is empty")
	}
	system := strings.ToUpper(tstSystemDrive()) + `\`
	if m, _ := tstAt(disks[0], "mount"); m != system {
		t.Errorf("first drive is %v, want the system drive %s", m, system)
	}
	for _, d := range disks {
		pct, _ := tstAt(d, "used_percent")
		if f, ok := pct.(float64); !ok || f < 0 || f > 100 {
			t.Errorf("disk used_percent = %v", pct)
		}
	}
	if v, _ := tstAt(doc, "cpu", "usage"); v != nil {
		if f := v.(float64); f < 0 || f > 100 {
			t.Errorf("cpu.usage = %v", v)
		}
	}
	for _, p := range tstArr(t, doc, "top_processes") {
		name, _ := tstAt(p, "name")
		if strings.ContainsAny(tstString(name), `\/`) {
			t.Errorf("process name %q carries a path", name)
		}
	}
	if n := len(tstArr(t, doc, "top_processes")); n > 5 {
		t.Errorf("top_processes has %d entries, want at most 5", n)
	}
	if n := len(tstArr(t, doc, "network")); n > 3 {
		t.Errorf("network has %d entries, want at most 3", n)
	}
}

func TestWindowsStreamDeliversEntries(t *testing.T) {
	lines := tstChildStreamLines(t, []string{"--watch", "--interval=500ms"}, 2)
	for _, l := range lines {
		doc := tstDecode(t, []byte(l))
		for _, k := range tstTopLevelKeys {
			if _, ok := doc[k]; !ok {
				t.Errorf("key %q missing in %q", k, l)
			}
		}
	}
}

func TestWindowsHelpAndInvalidCalls(t *testing.T) {
	help := tstChildMain(t, []string{"--help"})
	if help.code != 0 || !strings.HasPrefix(help.stdout, "Usage: sw status") {
		t.Errorf("--help: exit %d, stdout %q", help.code, help.stdout)
	}
	bad := tstChildMain(t, []string{"--interval=0s"})
	if bad.code != 1 || bad.stdout != "" {
		t.Errorf("--interval=0s: exit %d, stdout %q", bad.code, bad.stdout)
	}
}
