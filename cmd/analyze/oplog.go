package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// What analyze moved, one line per item in the operations.log that the
// PowerShell commands write through Write-MoleOperation (lib/core/log.ps1), so
// support can answer which path went where, when and how from one file.
// MO_NO_OPLOG=1 turns it off. The launcher passes the run in
// _MOLE_OPLOG_RUN_COMMAND and _MOLE_OPLOG_RUN_ID.
var (
	operationsLogPath             = defaultOperationsLogPath
	operationsLogMaxBytes   int64 = 5 << 20
	operationsLogNow              = time.Now
	operationsLogRetryDelay       = 20 * time.Millisecond

	operationsLogMu      sync.Mutex
	operationsLogStarted bool
)

const operationsLogAttempts = 5

func defaultOperationsLogPath() string {
	home := os.Getenv("USERPROFILE")
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	if home == "" {
		return ""
	}
	return filepath.Join(home, ".config", "freemole", "operations.log")
}

var logControlChars = regexp.MustCompile(`[\x00-\x1f\x7f]`)

// logValue escapes control characters so a file name cannot forge a record.
// Backslashes stay literal: Windows paths are full of them.
func logValue(value string) string {
	return logControlChars.ReplaceAllStringFunc(value, func(match string) string {
		switch match[0] {
		case '\t':
			return `\t`
		case '\n':
			return `\n`
		case '\r':
			return `\r`
		default:
			return fmt.Sprintf(`\x%02x`, match[0])
		}
	})
}

// operationLine is one record. The detail is parenthesis-free so a reader can
// split it from a path such as "Program Files (x86)".
func operationLine(now time.Time, label, action, path, detail string) string {
	safeDetail := "-"
	if detail != "" {
		safeDetail = strings.NewReplacer("(", "[", ")", "]").Replace(logValue(detail))
	}
	return fmt.Sprintf("[%s] [%s] %s %s (%s)", now.Format("2006-01-02 15:04:05"), label, action, logValue(path), safeDetail)
}

func operationsLogLabel() string {
	command := os.Getenv("_MOLE_OPLOG_RUN_COMMAND")
	if command == "" {
		command = "analyze"
	}
	if id := os.Getenv("_MOLE_OPLOG_RUN_ID"); id != "" {
		return command + " run=" + id
	}
	return command
}

// writeOperation appends one record. A failure never fails the deletion it
// describes, and another freeMole run holding the file is retried briefly.
func writeOperation(action, path, detail string) {
	if os.Getenv("MO_NO_OPLOG") == "1" || path == "" {
		return
	}
	file := operationsLogPath()
	if file == "" {
		return
	}

	operationsLogMu.Lock()
	defer operationsLogMu.Unlock()

	now := operationsLogNow()
	label := operationsLogLabel()
	text := operationLine(now, label, action, path, detail) + "\r\n"
	if !operationsLogStarted {
		if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
			debugOperationFailure(file, err)
			return
		}
		if info, err := os.Stat(file); err == nil && info.Size() > operationsLogMaxBytes {
			_ = os.Rename(file, file+".old")
		}
		// The marker goes with the first record, so a run that removes
		// nothing leaves the log untouched.
		text = fmt.Sprintf("\r\n# ========== %s session started at %s ==========\r\n", label, now.Format("2006-01-02 15:04:05")) + text
	}
	for attempt := 1; ; attempt++ {
		err := appendOperationText(file, text)
		if err == nil {
			operationsLogStarted = true
			return
		}
		if attempt >= operationsLogAttempts || errors.Is(err, os.ErrPermission) {
			debugOperationFailure(file, err)
			return
		}
		time.Sleep(time.Duration(attempt) * operationsLogRetryDelay)
	}
}

// Keep normal TUI output quiet; explicit debug mode shares the shell's session log.
func debugOperationFailure(file string, err error) {
	if os.Getenv("MOLE_DEBUG") != "1" {
		return
	}
	line := fmt.Sprintf("%s [DEBUG] operations.log not written: %s: %s\r\n", operationsLogNow().Format("15:04:05"), logValue(file), logValue(err.Error()))
	logRoot := defaultOperationsLogPath()
	if logRoot != "" {
		debugFile := filepath.Join(filepath.Dir(logRoot), "mole_debug_session.log")
		if appendOperationText(debugFile, line) == nil {
			return
		}
	}
	// Debug diagnostics still have an outlet when the entire log directory is unavailable.
	_, _ = fmt.Fprint(os.Stderr, line)
}

func appendOperationText(file, text string) error {
	f, err := os.OpenFile(file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	_, writeErr := f.WriteString(text)
	closeErr := f.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}

// recycleOutcome is what the shell did with an item it accepted.
type recycleOutcome int

const (
	// recycledVerified: the Recycle Bin of the item's drive grew.
	recycledVerified recycleOutcome = iota
	// recycledUnverified: the shell reported success but the Recycle Bin
	// could not be read before and after.
	recycledUnverified
	// deletedPermanently: the item is gone and the Recycle Bin did not grow,
	// which is what the shell's "too big to recycle, delete permanently?"
	// prompt leads to. A full bin that dropped an older item reads the same,
	// so the detail keeps that doubt.
	deletedPermanently
)

// logDeleteResult records one analyze deletion in operations.log.
func logDeleteResult(path, size string, outcome recycleOutcome, err error) {
	detail := func(parts ...string) string {
		kept := make([]string, 0, len(parts))
		for _, part := range parts {
			if part != "" {
				kept = append(kept, part)
			}
		}
		return strings.Join(kept, "; ")
	}
	if err != nil {
		writeOperation("FAILED", path, detail(size, err.Error()))
		return
	}
	switch outcome {
	case deletedPermanently:
		writeOperation("REMOVED", path, detail(size, "the Recycle Bin did not grow, so the shell probably deleted it permanently"))
	case recycledUnverified:
		writeOperation("RECYCLED", path, detail(size, "Recycle Bin not verified"))
	default:
		writeOperation("RECYCLED", path, size)
	}
}
