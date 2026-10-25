//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// lockPrefsFile takes an exclusive lock on the first byte of the lock file,
// the Windows counterpart of flock(LOCK_EX) on main.
func lockPrefsFile(f *os.File) error {
	var overlapped windows.Overlapped
	return windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &overlapped)
}

func unlockPrefsFile(f *os.File) error {
	var overlapped windows.Overlapped
	return windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, &overlapped)
}
