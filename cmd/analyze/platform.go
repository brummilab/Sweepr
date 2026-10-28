package main

import "os"

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
