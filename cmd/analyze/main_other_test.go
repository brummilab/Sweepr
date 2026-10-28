//go:build !windows

package main

// Other platforms: the package builds and its logic runs, the program itself
// reports that it is for Windows only and measures nothing. The test binary
// runs main() in a child process.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOtherPlatformsMainSaysWindowsOnlyAndExitsOne(t *testing.T) {
	for _, args := range [][]string{nil, {"--json"}, {"--json", `C:\Data`}} {
		root := t.TempDir()
		res := tstChildMain(t, args,
			"SWEEPR_DATA_DIR="+filepath.Join(root, "data"),
			"HOME="+filepath.Join(root, "home"), "USERPROFILE="+filepath.Join(root, "home"))
		if res.code != 1 {
			t.Errorf("%q: exit code %d, want 1", args, res.code)
		}
		if res.stdout != "" {
			t.Errorf("%q: stdout = %q, want empty", args, res.stdout)
		}
		if !strings.Contains(strings.ToLower(res.stderr), "windows") {
			t.Errorf("%q: stderr %q does not say that the program is for Windows only", args, res.stderr)
		}
		entries, _ := os.ReadDir(root)
		if len(entries) != 0 {
			t.Errorf("%q: the program created %v", args, entries)
		}
	}
}
