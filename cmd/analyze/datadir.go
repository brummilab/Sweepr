package main

import (
	"os"
	"path/filepath"
	"strings"
)

// dataFolderRefusal is shown when a delete is refused because it would touch
// Sweepr's own config or cache folder.
const dataFolderRefusal = "Sweepr's own data folder is protected."

// sweeprDataFolders returns the active config and cache folders, resolved from
// the environment on every call so a changed SWEEPR_DATA_DIR takes effect at
// once. With an override they are <dir>\config and <dir>\cache; without one,
// %USERPROFILE%\.config\sweepr and %USERPROFILE%\.cache\sweepr (USERPROFILE, as
// in oplog.go). An unset profile yields no folders.
func sweeprDataFolders(getenv func(string) string) []string {
	if dir := strings.TrimSpace(getenv("SWEEPR_DATA_DIR")); dir != "" {
		return []string{filepath.Join(dir, "config"), filepath.Join(dir, "cache")}
	}
	home := getenv("USERPROFILE")
	if strings.TrimSpace(home) == "" {
		return nil
	}
	return []string{
		filepath.Join(home, ".config", "sweepr"),
		filepath.Join(home, ".cache", "sweepr"),
	}
}

// touchesSweeprDataFolder reports whether path is one of folders, lies below
// one, or is an ancestor of one (deleting an ancestor would take the folder
// with it). Comparison ignores case and a trailing separator, and never treats
// a prefix sibling such as "sweepr2" as a match.
func touchesSweeprDataFolder(path string, folders []string) bool {
	p, ok := dataFolderKey(path)
	if !ok {
		return false
	}
	sep := string(filepath.Separator)
	for _, folder := range folders {
		f, ok := dataFolderKey(folder)
		if !ok {
			continue
		}
		if p == f || strings.HasPrefix(p, f+sep) || strings.HasPrefix(f, p+sep) {
			return true
		}
	}
	return false
}

// dataFolderKey normalizes a path for comparison: absolute, cleaned, lowercase,
// no trailing separator.
func dataFolderKey(path string) (string, bool) {
	if strings.TrimSpace(path) == "" {
		return "", false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", false
	}
	return strings.TrimRight(strings.ToLower(abs), string(filepath.Separator)), true
}

// isSweeprDataFolderPath reports whether deleting path would touch the data
// folders in the current environment.
func isSweeprDataFolderPath(path string) bool {
	return touchesSweeprDataFolder(path, sweeprDataFolders(os.Getenv))
}
