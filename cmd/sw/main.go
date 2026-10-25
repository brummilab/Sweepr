// Command sw starts sweepr.ps1 from the same folder with Windows PowerShell.
//
// Package managers that can only expose an executable (winget portable
// installs) put this on PATH as `sw`. It passes every argument through as a
// literal PowerShell string, the same call shape as the sw.cmd launcher that
// install.ps1 writes, and returns the script's exit code.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	script, err := scriptPath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "sw: %v\n", err)
		return 1
	}

	// The console sends Ctrl+C to PowerShell as well; let it decide.
	signal.Ignore(os.Interrupt)

	cmd := exec.Command(powerShellPath(), "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", commandLine(script, args))
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return exitErr.ExitCode()
		}
		fmt.Fprintf(os.Stderr, "sw: could not start PowerShell: %v\n", err)
		return 1
	}
	return 0
}

// scriptPath resolves sweepr.ps1 beside the real executable; winget runs this
// through a symlink in its Links folder.
func scriptPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	script := filepath.Join(filepath.Dir(exe), "sweepr.ps1")
	if _, err := os.Stat(script); err != nil {
		return "", fmt.Errorf("sweepr.ps1 not found next to %s", exe)
	}
	return script, nil
}

// powerShellPath is the absolute Windows PowerShell path, so a powershell.exe
// earlier on PATH is never picked up instead.
func powerShellPath() string {
	root := os.Getenv("SystemRoot")
	if root == "" {
		root = `C:\Windows`
	}
	return filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
}

// commandLine builds `& 'script' 'arg' ...; exit $LASTEXITCODE` with every
// value single-quoted, so PowerShell never expands or splits an argument.
func commandLine(script string, args []string) string {
	parts := make([]string, 0, len(args)+2)
	parts = append(parts, "&", quote(script))
	for _, arg := range args {
		parts = append(parts, quote(arg))
	}
	return strings.Join(parts, " ") + "; exit $LASTEXITCODE"
}

func quote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}
