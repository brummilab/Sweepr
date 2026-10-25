//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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

// A folder that merely contains a data folder is judged again at the moment of
// recycling, like the Docker case.
func TestRecycleReviewRechecksNewDataFolderChild(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Parent")
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	setDataFolderEnv(t, filepath.Join(root, "sweepr"))
	guard, err := prepareRecycleTarget(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "sweepr", "config"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := guard(); err == nil {
		t.Fatal("new data folder child accepted")
	}
}
