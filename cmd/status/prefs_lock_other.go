//go:build !windows

package main

import (
	"errors"
	"os"
	"syscall"
)

// lockExclusive blocks until it holds an exclusive advisory lock on f. The
// lock is released by unlock or when f is closed.
func lockExclusive(f *os.File) error {
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
		if !errors.Is(err, syscall.EINTR) {
			return err
		}
	}
}

func unlock(f *os.File) {
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
}
