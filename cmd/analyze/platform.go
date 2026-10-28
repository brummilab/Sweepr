package main

import (
	"os"
	"runtime"
)

// Where the logic asks the host about itself: the home folder according to the
// Go runtime and the working directory of the process.

// runtimeHomeDir is the home folder according to the Go runtime, or "" when
// it is not known.
func runtimeHomeDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return home
}

// workingDir is the working directory of the process.
func workingDir() (string, error) { return os.Getwd() }

// strictDataDir tells whether a SWEEPR_DATA_DIR that cannot be compared as a
// Windows path makes every removal refused. It does where the program really
// runs; elsewhere such a value (a path of the host) simply names no data
// folder, which is what the logic is exercised with.
var strictDataDir = runtime.GOOS == "windows"
