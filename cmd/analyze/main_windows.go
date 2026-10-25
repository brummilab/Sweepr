//go:build windows

package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	opts, code, keepGoing := parseArgs(os.Args[1:], os.Stdout, os.Stderr)
	if !keepGoing {
		os.Exit(code)
	}

	envPath := os.Getenv("MO_ANALYZE_PATH")
	if envPath == "" {
		envPath = opts.path
	}
	target, isOverview, err := resolveScanTarget(envPath, opts.args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	// JSON mode never starts the TUI, so it can neither delete nor write the
	// operations log; errors go to stderr with a nonzero exit.
	if opts.jsonMode {
		if err := runJSONMode(os.Stdout, target, isOverview); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	p := tea.NewProgram(newModel(target, isOverview), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "analyzer error: %v\n", err)
		os.Exit(1)
	}
}
