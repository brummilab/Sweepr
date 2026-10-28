//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

// environmentNames are the variables the program reads. The logic works on a
// map built here, once, and never asks the process itself.
var environmentNames = []string{
	"SWEEPR_ANALYZE_PATH", "SWEEPR_DATA_DIR", "USERPROFILE", "LOCALAPPDATA",
	"WINDIR", "SystemRoot", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData",
	"NO_COLOR", "SWEEPR_NO_OPLOG", "SWEEPR_DRY_RUN", "SWEEPR_DEBUG",
	"_SWEEPR_OPLOG_RUN_COMMAND", "_SWEEPR_OPLOG_RUN_ID",
}

func processEnvironment() map[string]string {
	env := map[string]string{}
	for _, name := range environmentNames {
		if v, ok := os.LookupEnv(name); ok {
			env[name] = v
		}
	}
	// A relative data directory is relative to the working directory of the
	// process; make it absolute so that the protection rules can compare it.
	if dir := strings.TrimSpace(env["SWEEPR_DATA_DIR"]); dir != "" && !filepath.IsAbs(dir) {
		if abs, err := filepath.Abs(dir); err == nil {
			env["SWEEPR_DATA_DIR"] = abs
		}
	}
	return env
}

// isConsole tells whether a file is a console, which is what a terminal is on
// Windows; a pipe or a file is not.
func isConsole(f *os.File) bool {
	var mode uint32
	return windows.GetConsoleMode(windows.Handle(f.Fd()), &mode) == nil
}

func realMain() int {
	return Run(os.Args[1:], processEnvironment(), os.Stdout, os.Stderr, isConsole(os.Stdout), Deps{
		FS:       NewOSFS(),
		Recycler: NewShellRecycler(),
		Clock:    systemClock{},
	})
}
