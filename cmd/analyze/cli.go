package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const usageText = `Usage: sw analyze [OPTIONS] [PATH]

Explore disk usage. Without PATH, shows an overview of your folders and drives.

Options:
  --json          Output the analysis as JSON instead of the interactive TUI
  -h, --help      Show this help message

Examples:
  sw analyze                 Folders and drives overview
  sw analyze ~\Downloads     Scan one directory
  sw analyze D:\             Scan a whole drive
  sw analyze --json D:\      Machine-readable output
`

// cliOptions is what one invocation asked for. path is the legacy -path flag;
// args are the positional arguments left after the flags.
type cliOptions struct {
	path     string
	jsonMode bool
	args     []string
}

// parseArgs applies Sweepr's CLI conventions to the flag package: help goes to
// stdout and exits 0, and an unknown flag goes to stderr and exits 1. It
// returns the parsed options, the exit code and whether main should run. Flags
// must come before PATH: parsing stops at the first positional argument.
func parseArgs(args []string, stdout, stderr io.Writer) (cliOptions, int, bool) {
	flags := flag.NewFlagSet("sw analyze", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.Usage = func() {}
	pathFlag := flags.String("path", "", "Path to analyze")
	jsonFlag := flags.Bool("json", false, "output analysis as JSON instead of TUI")

	err := flags.Parse(args)
	switch {
	case errors.Is(err, flag.ErrHelp):
		_, _ = fmt.Fprint(stdout, usageText)
		return cliOptions{}, 0, false
	case err != nil:
		_, _ = fmt.Fprintln(stderr, err)
		_, _ = fmt.Fprintln(stderr, "Use 'sw analyze --help' for usage information")
		return cliOptions{}, 1, false
	}
	return cliOptions{path: *pathFlag, jsonMode: *jsonFlag, args: flags.Args()}, 0, true
}

// resolveScanTarget decides which scan an invocation asks for: no target means
// the overview, anything else must be an existing path.
func resolveScanTarget(envPath string, args []string) (string, bool, error) {
	target := envPath
	if target == "" && len(args) > 0 {
		target = args[0]
	}
	if target == "" {
		return overviewPath, true, nil
	}

	abs, err := filepath.Abs(target)
	if err != nil {
		return "", false, fmt.Errorf("cannot resolve %q: %v", target, err)
	}
	if _, err := os.Stat(abs); err != nil {
		return "", false, fmt.Errorf("path does not exist: %s", abs)
	}
	return abs, false, nil
}
