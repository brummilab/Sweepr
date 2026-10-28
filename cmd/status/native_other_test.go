//go:build !windows

package main

// Other platforms (ST-24): the program builds and runs, but every source is
// unavailable, so nothing is invented. The test binary runs main() in a child
// process.

import (
	"strings"
	"testing"
)

func tstChildEnv(e tstEnv) []string {
	return []string{"SWEEPR_DATA_DIR=" + e.data, "HOME=" + e.home, "USERPROFILE=" + e.home}
}

func TestOtherPlatformsOneShotFailsWithoutInventingData(t *testing.T) {
	for _, args := range [][]string{{"--json"}, {}} {
		e := tstIsolated(t)
		res := tstChildMain(t, args, tstChildEnv(e)...)
		if res.code != 1 {
			t.Errorf("%q: exit code %d, want 1", args, res.code)
		}
		if res.stdout != "" {
			t.Errorf("%q: stdout = %q, want empty", args, res.stdout)
		}
		lower := strings.ToLower(res.stderr)
		for _, area := range []string{"cpu", "memory", "disk", "network", "process"} {
			if !strings.Contains(lower, area) {
				t.Errorf("%q: stderr %q does not name the unavailable area %q", args, res.stderr, area)
			}
		}
		e.assertUntouched(t)
	}
}

func TestOtherPlatformsStreamWritesEntriesWithEveryAreaNull(t *testing.T) {
	lines := tstChildStreamLines(t, []string{"--watch", "--interval=100ms"}, 2)
	for i, l := range lines {
		doc := tstDecode(t, []byte(l))
		tstWantNotNull(t, doc, "collected_at")
		for _, k := range tstTopLevelKeys[1:] {
			tstWantNull(t, doc, k)
		}
		if strings.Count(strings.TrimSuffix(l, "\n"), "\n") != 0 {
			t.Errorf("entry %d spans several lines", i)
		}
	}
}

func TestProgramEntryPointExitCodes(t *testing.T) {
	e := tstIsolated(t)
	help := tstChildMain(t, []string{"--help"}, tstChildEnv(e)...)
	if help.code != 0 || !strings.HasPrefix(help.stdout, "Usage: sw status") || help.stderr != "" {
		t.Errorf("--help: exit %d, stdout %q, stderr %q", help.code, help.stdout, help.stderr)
	}
	bad := tstChildMain(t, []string{"--bogus"}, tstChildEnv(e)...)
	if bad.code != 1 || bad.stdout != "" || !strings.Contains(bad.stderr, "--bogus") || !strings.Contains(bad.stderr, "--help") {
		t.Errorf("--bogus: exit %d, stdout %q, stderr %q", bad.code, bad.stdout, bad.stderr)
	}
	e.assertUntouched(t)
}
