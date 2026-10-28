package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// lockExclusive blocks until it holds an exclusive lock on the first byte of f.
// The lock is released by unlock or when f is closed.
func lockExclusive(f *os.File) error {
	ol := new(windows.Overlapped)
	return windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, ol)
}

func unlock(f *os.File) {
	ol := new(windows.Overlapped)
	_ = windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, ol)
}
