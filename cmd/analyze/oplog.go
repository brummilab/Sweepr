package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
)

// The operations log is shared with the PowerShell commands: one line per
// outcome, UTF-8 without a byte-order mark, CRLF line ends, appended. `sw
// history` reads the same file, so the form of the lines must not drift.

const (
	logTimeLayout   = "2006-01-02 15:04:05"
	logRotateAbove  = 5 * 1024 * 1024
	logAttempts     = 5
	logRetryStep    = 20 * time.Millisecond
	debugLogName    = "sweepr_debug_session.log"
	defaultLogLabel = "analyze"
)

// OpLog writes the operations log. The zero value and a nil pointer write
// nothing. It is safe for concurrent use: the marker that opens a session is
// written once, together with the first record that reaches the file, and no
// line is torn.
type OpLog struct {
	mu       sync.Mutex
	clock    Clock
	appendFn func(path string, data []byte) error
	path     string // the log file; empty when nothing is to be written
	label    string // command and run id as they appear in every line
	debug    bool

	rotated       bool
	markerWritten bool
}

// NewOpLog prepares the log from the environment: SWEEPR_NO_OPLOG=1 turns it
// off, SWEEPR_DATA_DIR names the data folder (the log lies in its config
// folder) and otherwise the log lies in the profile folder. When no folder is
// known it writes nothing, silently. appendFn appends data to a path; nil
// appends to the real file. Nothing is created before the first record.
func NewOpLog(env map[string]string, clock Clock, appendFn func(path string, data []byte) error) *OpLog {
	l := &OpLog{clock: clock, appendFn: appendFn, label: logLabel(env), debug: env["SWEEPR_DEBUG"] == "1"}
	if l.clock == nil {
		l.clock = systemClock{}
	}
	if l.appendFn == nil {
		l.appendFn = appendToFile
	}
	if env["SWEEPR_NO_OPLOG"] == "1" {
		return l
	}
	if dir := envValue(env, "SWEEPR_DATA_DIR"); dir != "" {
		l.path = filepath.Join(dir, "config", "operations.log")
	} else if profile := profileFolder(env); profile != "" {
		l.path = filepath.Join(profile, ".config", "sweepr", "operations.log")
	}
	return l
}

// logLabel builds "command[ run=id]". A value with a blank, a closing
// bracket or a control character would make the line unreadable for the
// history command, so such a command falls back to the default and such an
// id is left out.
func logLabel(env map[string]string) string {
	label := defaultLogLabel
	if cmd := env["_SWEEPR_OPLOG_RUN_COMMAND"]; cmd != "" && labelOK(cmd) {
		label = cmd
	}
	if id := env["_SWEEPR_OPLOG_RUN_ID"]; id != "" && labelOK(id) {
		label += " run=" + id
	}
	return label
}

func labelOK(s string) bool {
	for _, r := range s {
		if r == ']' || unicode.IsSpace(r) || unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// escapeControl writes control characters as text so that one record is one
// line: tab, line feed and carriage return as \t \n \r, the others as \xNN.
func escapeControl(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\x%02x`, r)
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// FormatRecord builds one record line without the line end. Path and detail
// have their control characters written out; in the detail the parentheses
// become brackets, because the reader takes the last parenthesized group as
// the detail. An empty detail is a dash.
func FormatRecord(t time.Time, label, action, path, detail string) string {
	d := escapeControl(detail)
	d = strings.NewReplacer("(", "[", ")", "]").Replace(d)
	if d == "" {
		d = "-"
	}
	return fmt.Sprintf("[%s] [%s] %s %s (%s)", t.Format(logTimeLayout), label, action, escapeControl(path), d)
}

// Record appends one line. A failure never reaches the caller: the line is
// dropped, and with SWEEPR_DEBUG=1 a note says so in the debug file.
func (l *OpLog) Record(action, path, detail string) {
	if l == nil || l.path == "" || path == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.clock.Now()
	data := FormatRecord(now, l.label, action, path, detail) + "\r\n"
	if !l.markerWritten {
		data = "\r\n# ========== " + l.label + " session started at " + now.Format(logTimeLayout) + " ==========\r\n" + data
	}
	l.rotateOnce()
	if err := l.appendWithRetry(data); err != nil {
		l.note(err)
		return
	}
	l.markerWritten = true
}

// rotateOnce moves a log above the size limit to <file>.old, replacing an
// older one, at the first write of the process only.
func (l *OpLog) rotateOnce() {
	if l.rotated {
		return
	}
	l.rotated = true
	if st, err := os.Stat(l.path); err == nil && st.Size() > logRotateAbove {
		_ = os.Rename(l.path, l.path+".old")
	}
}

// appendWithRetry tries up to logAttempts times, pausing a little longer
// after each failure, because another Sweepr process may be appending at the
// same moment. "Access denied" is not retried: waiting does not change it.
func (l *OpLog) appendWithRetry(data string) error {
	var err error
	for attempt := 1; attempt <= logAttempts; attempt++ {
		if err = l.appendFn(l.path, []byte(data)); err == nil {
			return nil
		}
		if errors.Is(err, fs.ErrPermission) {
			return err
		}
		if attempt < logAttempts {
			l.clock.Sleep(time.Duration(attempt) * logRetryStep)
		}
	}
	return err
}

// note records a dropped line in the debug file; if that fails too, nothing
// more happens (printing would disturb the display).
func (l *OpLog) note(cause error) {
	if !l.debug {
		return
	}
	line := fmt.Sprintf("%s [DEBUG] operations log line not written to %s: %s\r\n",
		l.clock.Now().Format("15:04:05"), escapeControl(l.path), escapeControl(cause.Error()))
	_ = l.appendFn(filepath.Join(filepath.Dir(l.path), debugLogName), []byte(line))
}

// appendToFile appends to the real file and creates the folder first. The
// file is opened shared, so a viewer or another process may read and append
// at the same time.
func appendToFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	_, werr := f.Write(data)
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	return werr
}
