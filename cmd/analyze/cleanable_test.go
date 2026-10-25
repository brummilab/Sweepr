package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCleanableHintRequiresCacheEvidence(t *testing.T) {
	// Use relative paths so the host temporary directory does not trigger the
	// separate sw-clean exclusion before the cache evidence is tested.
	t.Chdir(t.TempDir())
	for _, name := range []string{"build", "dist", "vendor", ".yarn", ".bundle", "node_modules"} {
		dir := name
		if err := os.Mkdir(dir, 0755); err != nil {
			t.Fatal(err)
		}
		if isCleanableDir(dir) {
			t.Errorf("unverified directory %s was marked cleanable", name)
		}
	}
	dir := "."
	if err := os.WriteFile(filepath.Join(dir, cacheDirTagFileName), []byte(cacheDirTagSignature), 0644); err != nil {
		t.Fatal(err)
	}
	if !isCleanableDir(dir) {
		t.Fatal("valid cache tag should retain its hint")
	}
}

func TestCleanableHintExcludesHandledPaths(t *testing.T) {
	for _, path := range []string{
		`C:\Users\test\AppData\Local\Temp\tagged`,
		`C:\Users\test\AppData\Local\CrashDumps\tagged`,
		`C:\$Recycle.Bin\tagged`,
	} {
		if !isHandledByMoClean(path) {
			t.Errorf("handled path %q should not be offered again", path)
		}
	}
}
