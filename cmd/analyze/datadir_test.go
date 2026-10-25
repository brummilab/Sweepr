package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// F-01l (E21): Analyze must refuse to delete Sweepr's own config and cache
// folders. These tests use only validateDeleteTarget, deletePathCmd and the
// model, so they run on every platform. The platform stand-in of isProtectedPath
// fails closed off Windows, so what they check is the message: a data folder is
// refused with the notice, anything else is not refused *as a data folder*.
// The Windows-only tests in datadir_windows_test.go check the real decision.

const dataFolderNotice = "Sweepr's own data folder is protected."

// dataFolderEnv points the profile and SWEEPR_DATA_DIR at fresh folders and
// returns the profile root.
func dataFolderEnv(t *testing.T, dataDirValue string) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("USERPROFILE", home)
	t.Setenv("HOME", home)
	t.Setenv("SWEEPR_DATA_DIR", dataDirValue)
	return home
}

func assertDataFolderRefused(t *testing.T, path string) {
	t.Helper()
	err := validateDeleteTarget(path)
	if err == nil {
		t.Errorf("validateDeleteTarget(%q) = nil, expected a refusal", path)
		return
	}
	if !strings.Contains(err.Error(), dataFolderNotice) {
		t.Errorf("validateDeleteTarget(%q) = %q, expected it to contain %q", path, err.Error(), dataFolderNotice)
	}
}

func assertNotDataFolder(t *testing.T, path string) {
	t.Helper()
	// Off Windows the stand-in refuses everything; the notice must still be absent.
	if err := validateDeleteTarget(path); err != nil && strings.Contains(err.Error(), dataFolderNotice) {
		t.Errorf("validateDeleteTarget(%q) = %q, expected no data folder notice", path, err.Error())
	}
}

func TestDataFolderOverrideIsRefusedWithContent(t *testing.T) {
	dataFolderEnv(t, "")
	data := t.TempDir()
	t.Setenv("SWEEPR_DATA_DIR", data)
	config := filepath.Join(data, "config")
	cache := filepath.Join(data, "cache")

	for _, path := range []string{
		config,
		cache,
		filepath.Join(config, "whitelist.txt"),
		filepath.Join(config, "nested", "deeper", "file.bin"),
		filepath.Join(cache, "update-check.json"),
		config + string(filepath.Separator),
		strings.ToUpper(config),
		strings.ToLower(cache),
		filepath.Join(strings.ToUpper(data), "Config", "x"),
	} {
		assertDataFolderRefused(t, path)
	}
}

func TestDataFolderOverrideTrimsTheVariable(t *testing.T) {
	dataFolderEnv(t, "")
	data := t.TempDir()
	t.Setenv("SWEEPR_DATA_DIR", "  "+data+"  ")
	assertDataFolderRefused(t, filepath.Join(data, "config"))
	assertDataFolderRefused(t, filepath.Join(data, "cache", "x"))
}

func TestDataFolderParentsOfProtectedFoldersAreRefused(t *testing.T) {
	dataFolderEnv(t, "")
	data := filepath.Join(t.TempDir(), "SweeprData")
	t.Setenv("SWEEPR_DATA_DIR", data)

	// The folder that holds config and cache, and every ancestor of it.
	assertDataFolderRefused(t, data)
	assertDataFolderRefused(t, strings.ToUpper(data))
	assertDataFolderRefused(t, filepath.Dir(data))
}

func TestDataFolderSiblingsStayDeletable(t *testing.T) {
	dataFolderEnv(t, "")
	root := t.TempDir()
	data := filepath.Join(root, "sweepr")
	t.Setenv("SWEEPR_DATA_DIR", data)

	for _, path := range []string{
		filepath.Join(root, "sweepr2"),
		filepath.Join(root, "sweepr2", "config"),
		filepath.Join(data, "config2"),
		filepath.Join(data, "config2", "x"),
		filepath.Join(data, "cache2"),
		filepath.Join(data, "cachefiles"),
		filepath.Join(data, "other"),
		filepath.Join(data, "other", "x"),
		filepath.Join(root, "sweepr-backup"),
		filepath.Join(root, "other"),
	} {
		assertNotDataFolder(t, path)
	}
}

func TestDataFolderProfileDefaultsApplyWithoutOverride(t *testing.T) {
	for _, value := range []string{"", "   ", "\t"} {
		home := dataFolderEnv(t, value)
		config := filepath.Join(home, ".config", "sweepr")
		cache := filepath.Join(home, ".cache", "sweepr")

		for _, path := range []string{
			config,
			cache,
			filepath.Join(config, "operations.log"),
			filepath.Join(cache, "x", "y"),
			strings.ToUpper(config),
			filepath.Join(home, ".config"),
			filepath.Join(home, ".cache"),
		} {
			assertDataFolderRefused(t, path)
		}
		for _, path := range []string{
			config + "2",
			filepath.Join(home, ".config", "sweepr2", "x"),
			filepath.Join(home, ".cache", "sweepr-old"),
			filepath.Join(home, ".config", "other"),
			filepath.Join(home, "config"),
			filepath.Join(home, "cache"),
		} {
			assertNotDataFolder(t, path)
		}
	}
}

func TestDataFolderOverrideReplacesTheProfileFolders(t *testing.T) {
	home := dataFolderEnv(t, "")
	data := t.TempDir()
	t.Setenv("SWEEPR_DATA_DIR", data)

	// With an override the profile folders are not Sweepr's data folders.
	assertNotDataFolder(t, filepath.Join(home, ".config", "sweepr"))
	assertNotDataFolder(t, filepath.Join(home, ".cache", "sweepr", "x"))
	// Without one, the override folders are not.
	t.Setenv("SWEEPR_DATA_DIR", "")
	assertNotDataFolder(t, filepath.Join(data, "config"))
	assertNotDataFolder(t, filepath.Join(data, "cache"))
}

func TestDataFolderFollowsTheEnvironmentAtCallTime(t *testing.T) {
	dataFolderEnv(t, "")
	first := t.TempDir()
	second := t.TempDir()
	t.Setenv("SWEEPR_DATA_DIR", first)
	assertDataFolderRefused(t, filepath.Join(first, "config"))
	t.Setenv("SWEEPR_DATA_DIR", second)
	assertNotDataFolder(t, filepath.Join(first, "config"))
	assertDataFolderRefused(t, filepath.Join(second, "config"))
}

// The refusal reaches the user through the status line, with nothing recycled.
func TestAnalyzeShowsTheDataFolderNotice(t *testing.T) {
	dataFolderEnv(t, "")
	data := t.TempDir()
	t.Setenv("SWEEPR_DATA_DIR", data)
	config := filepath.Join(data, "config")
	if err := os.MkdirAll(config, 0o755); err != nil {
		t.Fatal(err)
	}

	var recycled []string
	previous := recycleItem
	recycleItem = func(path string) (recycleOutcome, error) {
		recycled = append(recycled, path)
		return recycledVerified, nil
	}
	t.Cleanup(func() { recycleItem = previous })

	m := newModel(data, false)
	m.scanning = false
	m.deleting = true
	msg := deletePathCmd(config, "", nil)()
	next, _ := m.Update(msg)
	got := next.(model)

	if !strings.Contains(got.status, dataFolderNotice) {
		t.Errorf("status = %q, expected it to contain %q", got.status, dataFolderNotice)
	}
	if len(recycled) != 0 {
		t.Errorf("data folder was sent to the Recycle Bin: %v", recycled)
	}
	if _, err := os.Stat(config); err != nil {
		t.Errorf("data folder is gone: %v", err)
	}
}
