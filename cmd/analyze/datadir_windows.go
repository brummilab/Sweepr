//go:build windows

package main

import (
	"errors"
	"io/fs"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

type fileID struct{ volume, high, low uint32 }

// readFileID returns the identity of path. With follow set, links on the last
// element are followed; otherwise the link itself is identified.
func readFileID(path string, follow bool) (fileID, error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return fileID{}, err
	}
	flags := uint32(windows.FILE_FLAG_BACKUP_SEMANTICS)
	if !follow {
		flags |= windows.FILE_FLAG_OPEN_REPARSE_POINT
	}
	h, err := windows.CreateFile(p, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, flags, 0)
	if err != nil {
		return fileID{}, err
	}
	defer windows.CloseHandle(h)
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(h, &info); err != nil {
		return fileID{}, err
	}
	return fileID{info.VolumeSerialNumber, info.FileIndexHigh, info.FileIndexLow}, nil
}

func isUNCPath(path string) bool {
	abs, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	n := normalizeWindowsPath(abs)
	return strings.HasPrefix(n, `\\`) && !strings.HasPrefix(n, `\\?\`) && !strings.HasPrefix(n, `\\.\`)
}

// touchesDataFolderIdentity compares what path really is, by volume serial and
// file index, with the data folders: the same folder reached through an 8.3
// name, a subst drive, a mapped drive or \\localhost\C$ has the same identity.
// For a network path whose identity cannot be read it fails closed.
func touchesDataFolderIdentity(path string, folders []string) bool {
	unc := isUNCPath(path)

	// Identities of every data folder (if it exists) and of all its ancestors.
	folderSelf := map[fileID]bool{}
	folderChain := map[fileID]bool{}
	for _, folder := range folders {
		for current, first := filepath.Clean(folder), true; ; first = false {
			id, err := readFileID(current, true)
			if err == nil {
				if first {
					folderSelf[id] = true
				}
				folderChain[id] = true
			}
			parent := filepath.Dir(current)
			if parent == current {
				break
			}
			current = parent
		}
	}

	// The target itself without following it, then its ancestors followed.
	current := filepath.Clean(path)
	if id, err := readFileID(current, false); err == nil {
		if folderChain[id] {
			return true
		}
	} else if unc && !errors.Is(err, fs.ErrNotExist) {
		return true
	}
	readAny := false
	for {
		parent := filepath.Dir(current)
		if parent == current {
			break
		}
		current = parent
		id, err := readFileID(current, true)
		if err != nil {
			if unc && !errors.Is(err, fs.ErrNotExist) {
				return true
			}
			continue
		}
		readAny = true
		if folderSelf[id] {
			return true
		}
	}
	return unc && !readAny
}
