//go:build !windows

package main

import (
	"fmt"
	"os"
)

// realMain on other systems: the package builds and its logic can be tested,
// but the program measures a Windows file system and says so.
func realMain() int {
	fmt.Fprintln(os.Stderr, "analyze: this program runs on Windows only")
	return 1
}
