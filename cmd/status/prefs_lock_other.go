//go:build !windows

package main

import (
	"os"
	"syscall"
)

// The status binary ships for Windows only; this lets the platform-neutral
// code and its tests build on the macOS and Linux machines developers use.
func lockPrefsFile(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
}

func unlockPrefsFile(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
}
