//go:build windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

// F-01l (E21): the real decision of isProtectedPath for Sweepr's own data
// folders. Needs Windows for path semantics and runs in the Windows CI.

func setDataFolderEnv(t *testing.T, dataDir string) (home string) {
	t.Helper()
	home = filepath.Join(t.TempDir(), "Example")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("USERPROFILE", home)
	t.Setenv("SWEEPR_DATA_DIR", dataDir)
	return home
}

func TestIsProtectedPathProtectsTheOverrideDataFolder(t *testing.T) {
	root := t.TempDir()
	data := filepath.Join(root, "SweeprData")
	setDataFolderEnv(t, data)
	config := filepath.Join(data, "config")
	cache := filepath.Join(data, "cache")

	for _, path := range []string{
		config,
		cache,
		filepath.Join(config, "whitelist.txt"),
		filepath.Join(cache, "a", "b", "c.bin"),
		strings.ToUpper(config),
		strings.ToLower(cache) + `\`,
		`\\?\` + config,
		data,
		root,
	} {
		if !isProtectedPath(path) {
			t.Errorf("isProtectedPath(%q) = false, expected true", path)
		}
	}
	for _, path := range []string{
		filepath.Join(root, "SweeprData2"),
		filepath.Join(root, "SweeprData2", "config"),
		filepath.Join(data, "config2"),
		filepath.Join(data, "cache2", "x"),
		filepath.Join(data, "other"),
		filepath.Join(root, "ordinary"),
	} {
		if isProtectedPath(path) {
			t.Errorf("isProtectedPath(%q) = true, expected false", path)
		}
	}
}

func TestIsProtectedPathProtectsTheProfileDataFolder(t *testing.T) {
	for _, value := range []string{"", "   "} {
		home := setDataFolderEnv(t, value)
		config := filepath.Join(home, ".config", "sweepr")
		cache := filepath.Join(home, ".cache", "sweepr")

		for _, path := range []string{
			config,
			cache,
			filepath.Join(config, "operations.log"),
			filepath.Join(cache, "x"),
			strings.ToUpper(config),
			filepath.Join(home, ".config"),
			filepath.Join(home, ".cache"),
		} {
			if !isProtectedPath(path) {
				t.Errorf("SWEEPR_DATA_DIR=%q: isProtectedPath(%q) = false, expected true", value, path)
			}
		}
		for _, path := range []string{
			config + "2",
			filepath.Join(home, ".config", "sweepr-old", "x"),
			filepath.Join(home, ".config", "other"),
			filepath.Join(home, ".cache", "other"),
			filepath.Join(home, "Downloads"),
		} {
			if isProtectedPath(path) {
				t.Errorf("SWEEPR_DATA_DIR=%q: isProtectedPath(%q) = true, expected false", value, path)
			}
		}
	}
}

func TestIsProtectedPathOverrideReplacesTheProfileFolders(t *testing.T) {
	data := filepath.Join(t.TempDir(), "SweeprData")
	home := setDataFolderEnv(t, data)
	for _, path := range []string{
		filepath.Join(home, ".config", "sweepr"),
		filepath.Join(home, ".cache", "sweepr", "x"),
		filepath.Join(home, ".config"),
	} {
		if isProtectedPath(path) {
			t.Errorf("isProtectedPath(%q) = true with an override, expected false", path)
		}
	}
}

func TestRecycleRefusesDataFolderAndKeepsSiblings(t *testing.T) {
	calls := withRecorder(t)
	root := t.TempDir()
	data := filepath.Join(root, "sweepr")
	setDataFolderEnv(t, data)
	for _, dir := range []string{
		filepath.Join(data, "config", "sub"),
		filepath.Join(data, "cache"),
		filepath.Join(root, "sweepr2", "config"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	for _, path := range []string{
		filepath.Join(data, "config"),
		filepath.Join(data, "cache"),
		filepath.Join(data, "config", "sub"),
		data,
		root,
	} {
		_, err := moveToRecycleBin(path)
		if err == nil {
			t.Errorf("moveToRecycleBin(%q) = nil, expected a refusal", path)
			continue
		}
		if !strings.Contains(err.Error(), dataFolderNotice) {
			t.Errorf("moveToRecycleBin(%q) = %q, expected it to contain %q", path, err.Error(), dataFolderNotice)
		}
	}
	if len(*calls) != 0 {
		t.Fatalf("recycle called for protected data: %v", *calls)
	}

	if _, err := moveToRecycleBin(filepath.Join(root, "sweepr2")); err != nil {
		t.Fatalf("prefix sibling refused: %v", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("prefix sibling not recycled: %v", *calls)
	}
}

// The review of a recycle target is repeated just before recycling. A data
// folder that appears under the target in between (here: the environment
// changes to a folder inside it) must stop the recycle.
func TestRecycleReviewRechecksTheEnvironment(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Parent")
	if err := os.MkdirAll(filepath.Join(root, "sweepr", "config"), 0o755); err != nil {
		t.Fatal(err)
	}
	setDataFolderEnv(t, filepath.Join(t.TempDir(), "elsewhere"))
	guard, err := prepareRecycleTarget(root)
	if err != nil {
		t.Fatalf("target without data folder refused: %v", err)
	}
	t.Setenv("SWEEPR_DATA_DIR", filepath.Join(root, "sweepr"))
	if err := guard(); err == nil {
		t.Fatal("recheck accepted a target that now holds the data folder")
	}
}

// assertNeverRecycled requires a refusal for path, with the data folder notice
// when wantNotice is set, and no call to the Recycle Bin.
func assertNeverRecycled(t *testing.T, path string, wantNotice bool) {
	t.Helper()
	calls := withRecorder(t)
	if err := validateDeleteTarget(path); err == nil {
		t.Errorf("validateDeleteTarget(%q) = nil, expected a refusal", path)
	} else if wantNotice && !strings.Contains(err.Error(), dataFolderNotice) {
		t.Errorf("validateDeleteTarget(%q) = %q, expected it to contain %q", path, err.Error(), dataFolderNotice)
	}
	_, err := moveToRecycleBin(path)
	if err == nil {
		t.Errorf("moveToRecycleBin(%q) = nil, expected a refusal", path)
	} else if wantNotice && !strings.Contains(err.Error(), dataFolderNotice) {
		t.Errorf("moveToRecycleBin(%q) = %q, expected it to contain %q", path, err.Error(), dataFolderNotice)
	}
	if len(*calls) != 0 {
		t.Errorf("recycle called for %q: %v", path, *calls)
	}
}

func makeDataFolders(t *testing.T) (data string) {
	t.Helper()
	data = filepath.Join(t.TempDir(), "SweeprDataLongName")
	setDataFolderEnv(t, data)
	for _, dir := range []string{"config", "cache"} {
		if err := os.MkdirAll(filepath.Join(data, dir, "sub"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return data
}

func TestDataFolderRefusedInVerbatimSpelling(t *testing.T) {
	data := makeDataFolders(t)
	for _, path := range []string{
		`\\?\` + filepath.Join(data, "config"),
		`\\?\` + filepath.Join(data, "config", "sub"),
		`\\?\` + strings.ToUpper(filepath.Join(data, "cache")),
		`\\?\` + data,
	} {
		assertNeverRecycled(t, path, true)
	}
}

func shortPathOf(t *testing.T, path string) string {
	t.Helper()
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]uint16, windows.MAX_PATH*4)
	n, err := windows.GetShortPathName(p, &buf[0], uint32(len(buf)))
	if err != nil || n == 0 || int(n) > len(buf) {
		t.Skipf("no 8.3 name available: %v", err)
	}
	return windows.UTF16ToString(buf[:n])
}

func TestDataFolderRefusedThroughShortName(t *testing.T) {
	data := makeDataFolders(t)
	config := filepath.Join(data, "config")
	short := shortPathOf(t, config)
	if strings.EqualFold(short, config) {
		t.Skip("8.3 names are disabled on this volume, the folder has no short spelling")
	}
	assertNeverRecycled(t, short, true)
	assertNeverRecycled(t, filepath.Join(short, "sub"), true)
	assertNeverRecycled(t, shortPathOf(t, data), true)
}

func TestDataFolderRefusedThroughSubstDrive(t *testing.T) {
	data := makeDataFolders(t)
	var letter string
	for _, c := range "ZYXWVUTSRQP" {
		if _, err := os.Stat(string(c) + `:\`); err != nil {
			letter = string(c) + ":"
			break
		}
	}
	if letter == "" {
		t.Skip("no free drive letter for subst")
	}
	if out, err := exec.Command("subst", letter, data).CombinedOutput(); err != nil {
		t.Skipf("subst is not available: %v %s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("subst", letter, "/d").Run() })

	assertNeverRecycled(t, letter+`\config`, true)
	assertNeverRecycled(t, letter+`\cache\sub`, true)
	assertNeverRecycled(t, letter+`\`, true)
}

// \\localhost\C$ reaches the same folder over the network namespace. Refusing
// it is required; the notice is preferred and only logged when missing.
func TestDataFolderRefusedThroughUncLoopback(t *testing.T) {
	data := makeDataFolders(t)
	vol := filepath.VolumeName(data)
	if len(vol) != 2 || vol[1] != ':' {
		t.Skipf("data folder is not on a drive letter: %q", data)
	}
	unc := `\\localhost\` + vol[:1] + `$` + data[len(vol):]
	if _, err := os.Stat(unc); err != nil {
		t.Skipf("administrative share is not reachable: %v", err)
	}
	for _, path := range []string{
		filepath.Join(unc, "config"),
		filepath.Join(unc, "config", "sub"),
		unc,
	} {
		calls := withRecorder(t)
		err := validateDeleteTarget(path)
		if err == nil {
			t.Errorf("validateDeleteTarget(%q) = nil, expected a refusal", path)
		} else if !strings.Contains(err.Error(), dataFolderNotice) {
			t.Logf("validateDeleteTarget(%q) refused without the notice: %v", path, err)
		}
		if _, err := moveToRecycleBin(path); err == nil {
			t.Errorf("moveToRecycleBin(%q) = nil, expected a refusal", path)
		}
		if len(*calls) != 0 {
			t.Errorf("recycle called for %q: %v", path, *calls)
		}
	}
}

func TestDataFolderRefusedBehindJunctionAncestor(t *testing.T) {
	data := makeDataFolders(t)
	base := t.TempDir()

	toData := filepath.Join(base, "to-data")
	makeJunction(t, toData, data)
	assertNeverRecycled(t, filepath.Join(toData, "config"), true)
	assertNeverRecycled(t, filepath.Join(toData, "cache", "sub"), true)

	toParent := filepath.Join(base, "to-parent")
	makeJunction(t, toParent, filepath.Dir(data))
	assertNeverRecycled(t, filepath.Join(toParent, filepath.Base(data), "config"), true)
	assertNeverRecycled(t, filepath.Join(toParent, filepath.Base(data)), true)
}
