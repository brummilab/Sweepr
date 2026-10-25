package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	cacheDirTagFileName  = "CACHEDIR.TAG"
	cacheDirTagSignature = "Signature: 8a477f597d28d172789f06886806bc55"
)

// isCleanableDir marks paths safe to delete manually (not handled by fm clean).
func isCleanableDir(path string) bool {
	if path == "" {
		return false
	}

	// Exclude paths fm clean already handles.
	if isHandledByMoClean(path) {
		return false
	}

	// A name is not evidence: even build outputs and dependency folders may
	// contain authored or tracked files. Only the owner's cache tag opts in.
	return hasValidCacheDirTag(path)
}

func hasValidCacheDirTag(path string) bool {
	tagPath := filepath.Join(path, cacheDirTagFileName)
	info, err := os.Lstat(tagPath)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}

	file, err := os.Open(tagPath)
	if err != nil {
		return false
	}
	defer func() {
		_ = file.Close()
	}()

	buf := make([]byte, len(cacheDirTagSignature))
	if _, err := io.ReadFull(file, buf); err != nil {
		return false
	}

	return string(buf) == cacheDirTagSignature
}

// isHandledByMoClean checks if a path is cleaned by fm clean.
func isHandledByMoClean(path string) bool {
	lower := strings.ToLower(path)
	for _, fragment := range moCleanHandledPathFragments {
		if strings.Contains(lower, fragment) {
			return true
		}
	}

	return false
}

var moCleanHandledPathFragments = []string{
	`\appdata\local\temp\`,
	`\appdata\local\crashdumps\`,
	`\$recycle.bin\`,
}
