//go:build !windows

package main

import (
	"os/signal"
	"syscall"
)

// ignoreBrokenPipe keeps a write to a closed stdout or stderr from killing the
// program with SIGPIPE. The write then fails with an error, which the stream
// treats as the end of its reader.
func ignoreBrokenPipe() {
	signal.Ignore(syscall.SIGPIPE)
}
