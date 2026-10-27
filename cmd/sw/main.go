// Command sw is the native entry point of Sweepr. Package managers and the
// portable ZIP can only put an .exe on PATH, so this program starts
// sweepr.ps1 from its own folder with Windows PowerShell 5.1, passes every
// argument through as data and returns the script's exit code.
// Behaviour rules V-1 to V-15 are locked by launcher_test.go.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
)

const programName = "sw"

func main() {
	os.Exit(run(os.Args[1:]))
}

// fail prints one error line on stderr; stdout stays reserved for the script.
func fail(format string, a ...interface{}) int {
	fmt.Fprintf(os.Stderr, programName+": "+format+"\n", a...)
	return 1
}

func run(args []string) int {
	dir, err := programDir()
	if err != nil {
		return fail("sweepr.ps1 not found: cannot determine the program folder: %v", err)
	}
	script := filepath.Join(dir, "sweepr.ps1")
	if info, err := os.Stat(script); err != nil || info.IsDir() {
		return fail("sweepr.ps1 not found in %s", dir)
	}

	powershell, err := windowsPowerShellPath()
	if err != nil {
		return fail("%v", err)
	}

	// No -NonInteractive: the main menu reads keys. No -File: the router
	// expects this -Command form, which keeps every argument a plain string.
	cmd := exec.Command(powershell,
		"-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
		"-Command", psCommandText(script, args))
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr

	// Ctrl+C reaches PowerShell too. Catching it here (instead of ignoring it,
	// which the child would inherit) keeps the launcher alive until the script
	// has decided how to end, so the shell prompt does not return early.
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt)
	defer signal.Stop(interrupts)

	if err := cmd.Start(); err != nil {
		return fail("cannot start %s: %v", powershell, err)
	}
	err = cmd.Wait()
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	if err != nil {
		return fail("waiting for PowerShell failed: %v", err)
	}
	return 0
}

// programDir returns the folder of the real executable. winget starts sw.exe
// through a symbolic link in its Links folder, so the link is resolved; if
// that fails, the folder the program was started from is used.
func programDir() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	return filepath.Dir(exe), nil
}

// windowsPowerShellPath returns the absolute path of Windows PowerShell 5.1
// under %SystemRoot%. The path must be absolute so that a powershell.exe in
// PATH or in the current folder can never be picked instead.
func windowsPowerShellPath() (string, error) {
	root := os.Getenv("SystemRoot")
	if root == "" {
		root = `C:\Windows`
	}
	p := filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if !filepath.IsAbs(p) {
		return "", fmt.Errorf("Windows PowerShell path %s is not absolute; check SystemRoot", p)
	}
	return p, nil
}
