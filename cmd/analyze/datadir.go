package main

import (
	"fmt"
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
// with it). Comparison ignores case, the verbatim/device prefixes and a
// trailing separator, and never treats a prefix sibling such as "sweepr2" as a
// match. It compares spellings only; see touchesDataFolderResolved for links.
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

// normalizeWindowsPath is a pure string function: it rewrites \\?\X:\, \\.\X:\
// and \??\X:\ to X:\ and the matching UNC prefixes to \\host\share\, then
// lowercases. Volume{GUID} and GLOBALROOT spellings keep their prefix, so they
// never collide with a drive-letter folder.
func normalizeWindowsPath(path string) string {
	lower := strings.ToLower(path)
	for _, prefix := range []string{`\\?\`, `\\.\`, `\??\`} {
		if !strings.HasPrefix(lower, prefix) {
			continue
		}
		rest := lower[len(prefix):]
		if strings.HasPrefix(rest, `unc\`) {
			return `\\` + rest[len(`unc\`):]
		}
		if len(rest) >= 2 && rest[0] >= 'a' && rest[0] <= 'z' && rest[1] == ':' {
			return rest
		}
		break
	}
	return lower
}

// dataFolderKey normalizes a path for comparison: absolute, cleaned, without
// verbatim prefix, lowercase, no trailing separator.
func dataFolderKey(path string) (string, bool) {
	if strings.TrimSpace(path) == "" {
		return "", false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", false
	}
	return strings.TrimRight(normalizeWindowsPath(abs), string(filepath.Separator)), true
}

// resolveExisting resolves links in the longest existing part of path and
// appends the rest unchanged. With leaf set the last element is resolved too;
// otherwise it is kept as spelled, because removing a link removes only the link.
func resolveExisting(path string, leaf bool) string {
	path = filepath.Clean(path)
	if !leaf {
		dir, base := filepath.Split(path)
		if dir == "" || base == "" {
			return path
		}
		return filepath.Join(resolveExisting(dir, true), base)
	}
	rest := ""
	for current := path; ; {
		if resolved, err := resolveFinalPath(current); err == nil {
			return filepath.Join(resolved, rest)
		}
		parent := filepath.Dir(current)
		if parent == current {
			return path
		}
		rest = filepath.Join(filepath.Base(current), rest)
		current = parent
	}
}

// touchesDataFolderResolved compares the final spellings: the data folders with
// their links resolved (where they exist) against path with its parent resolved.
// This catches 8.3 names, subst drives and junction ancestors.
func touchesDataFolderResolved(path string, folders []string) bool {
	resolvedPath := resolveExisting(path, false)
	resolvedFolders := make([]string, 0, len(folders))
	for _, folder := range folders {
		resolvedFolders = append(resolvedFolders, resolveExisting(folder, true))
	}
	return touchesSweeprDataFolder(resolvedPath, resolvedFolders) ||
		touchesSweeprDataFolder(resolvedPath, folders) ||
		touchesSweeprDataFolder(path, resolvedFolders)
}

// isSweeprDataFolderPath is the cheap, spelling-only check, fit for every entry
// of a tree walk.
func isSweeprDataFolderPath(path string) bool {
	return touchesSweeprDataFolder(path, sweeprDataFolders(os.Getenv))
}

// isSweeprDataFolderTarget is the thorough check for one selected target: it
// also compares final spellings and, on Windows, file identities.
func isSweeprDataFolderTarget(path string) bool {
	folders := sweeprDataFolders(os.Getenv)
	return touchesSweeprDataFolder(path, folders) ||
		touchesDataFolderResolved(path, folders) ||
		touchesDataFolderIdentity(path, folders)
}

// checkDataFolderTarget returns the data folder notice if path touches one.
func checkDataFolderTarget(path string) error {
	if isSweeprDataFolderTarget(path) {
		return fmt.Errorf("%s %s", dataFolderRefusal, path)
	}
	return nil
}
