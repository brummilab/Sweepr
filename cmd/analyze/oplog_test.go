package main

// The operations log: record and marker format, label, path, rotation,
// retries, debug note, concurrency. The reader is lib/core/history.ps1; its
// patterns are used unchanged (tstRecordRe, tstMarkerRe).

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

func tstRealAppend(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(data)
	return err
}

type tstAppendCall struct {
	path string
	data []byte
}

// tstAppender replaces the append operation of the log; rule decides per call
// (1-based number, path) whether it fails; successful calls reach the real file.
type tstAppender struct {
	mu    sync.Mutex
	calls []tstAppendCall
	rule  func(n int, path string) error
	delay time.Duration
}

func (a *tstAppender) append(path string, data []byte) error {
	a.mu.Lock()
	a.calls = append(a.calls, tstAppendCall{path, append([]byte(nil), data...)})
	n := len(a.calls)
	rule, delay := a.rule, a.delay
	a.mu.Unlock()
	if delay > 0 {
		time.Sleep(delay)
	}
	if rule != nil {
		if err := rule(n, path); err != nil {
			return err
		}
	}
	return tstRealAppend(path, data)
}

func (a *tstAppender) recorded() []tstAppendCall {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]tstAppendCall(nil), a.calls...)
}

func (a *tstAppender) callsTo(base string) []tstAppendCall {
	var out []tstAppendCall
	for _, c := range a.recorded() {
		if filepath.Base(c.path) == base {
			out = append(out, c)
		}
	}
	return out
}

type tstLogRig struct {
	t       *testing.T
	clk     *fakeClock
	env     map[string]string
	data    string
	logFile string
	app     *tstAppender
}

func newLogRig(t *testing.T) *tstLogRig {
	t.Helper()
	data := filepath.Join(t.TempDir(), "data")
	return &tstLogRig{
		t: t, clk: newFakeClock(), data: data,
		env:     map[string]string{"SWEEPR_DATA_DIR": data},
		logFile: filepath.Join(data, "config", "operations.log"),
		app:     &tstAppender{},
	}
}

func (r *tstLogRig) newLog() *OpLog { return tstNewOpLog(r.env, r.clk, r.app.append) }

func (r *tstLogRig) read() string { return tstReadLog(r.t, r.logFile) }

const tstMarker1000 = "\r\n# ========== analyze session started at 2026-10-15 10:00:00 ==========\r\n"

// ---------------------------------------------------------------------------
// Format

func TestOpLogFirstRecordWritesMarkerAndRecordInOneOperation(t *testing.T) {
	r := newLogRig(t)
	log := r.newLog()
	tstRecord(log, "RECYCLED", `D:\Games\Old`, "3.4GB")
	calls := r.app.recorded()
	if len(calls) != 1 {
		t.Fatalf("%d append operations, want 1 for marker and record together", len(calls))
	}
	want := tstMarker1000 + "[2026-10-15 10:00:00] [analyze] RECYCLED D:\\Games\\Old (3.4GB)\r\n"
	if string(calls[0].data) != want {
		t.Errorf("written bytes = %q\nwant %q", calls[0].data, want)
	}
	if calls[0].path != r.logFile {
		t.Errorf("appended to %q, want %q", calls[0].path, r.logFile)
	}
	if got := r.read(); got != want {
		t.Errorf("file content = %q, want %q", got, want)
	}
}

func TestOpLogFollowingRecordsCarryNoMarker(t *testing.T) {
	r := newLogRig(t)
	log := r.newLog()
	tstRecord(log, "RECYCLED", `C:\a`, "1B")
	r.clk.Advance(5 * time.Second)
	tstRecord(log, "FAILED", `C:\b`, "1B; the shell reported an error")
	r.clk.Advance(3 * time.Second)
	tstRecord(log, "SKIPPED", `C:\c`, "refused: protected")
	calls := r.app.recorded()
	if len(calls) != 3 {
		t.Fatalf("%d append operations, want 3", len(calls))
	}
	if strings.Contains(string(calls[1].data), "session started") || strings.Contains(string(calls[2].data), "session started") {
		t.Errorf("a later record carries a marker")
	}
	if want := "[2026-10-15 10:00:05] [analyze] FAILED C:\\b (1B; the shell reported an error)\r\n"; string(calls[1].data) != want {
		t.Errorf("second write = %q, want %q", calls[1].data, want)
	}
	if want := "[2026-10-15 10:00:08] [analyze] SKIPPED C:\\c (refused: protected)\r\n"; string(calls[2].data) != want {
		t.Errorf("third write = %q, want %q", calls[2].data, want)
	}
}

func TestOpLogLinesMatchTheReaderPatternsOfTheHistoryCommand(t *testing.T) {
	r := newLogRig(t)
	log := r.newLog()
	tstRecord(log, "RECYCLED", `D:\Games\Old`, "3.4GB")
	tstRecord(log, "FAILED", `D:\Temp\x`, "12.0MB; the shell reported an error")
	tstRecord(log, "SKIPPED", `D:\Work\proj`, `refused: protected entry inside: D:\Work\proj\.ssh`)
	tstRecord(log, "RECYCLED", `C:\Program Files (x86)\App`, "1.0KB")
	recs, markers := tstParseLog(t, r.read())
	if len(markers) != 1 || len(recs) != 4 {
		t.Fatalf("%d markers and %d records, want 1 and 4", len(markers), len(recs))
	}
	if m := tstMarkerRe.FindStringSubmatch(markers[0]); m[1] != "analyze" || m[2] != "" || m[3] != "2026-10-15 10:00:00" {
		t.Errorf("marker groups = %q", m[1:])
	}
	if recs[3].path != `C:\Program Files (x86)\App` || recs[3].detail != "1.0KB" {
		t.Errorf("record with parentheses in the path parsed as %+v", recs[3])
	}
	if recs[2].detail != `refused: protected entry inside: D:\Work\proj\.ssh` || recs[2].action != "SKIPPED" {
		t.Errorf("SKIPPED record parsed as %+v", recs[2])
	}
	for _, rec := range recs {
		if rec.time != "2026-10-15 10:00:00" || rec.command != "analyze" || rec.run != "" {
			t.Errorf("record %+v: unexpected time, command or run", rec)
		}
	}
}

func TestOpLogFileIsUTF8WithoutBOMAndEndsEveryLineWithCRLF(t *testing.T) {
	r := newLogRig(t)
	log := r.newLog()
	tstRecord(log, "RECYCLED", `C:\Üb\ñ 日本`, "1B")
	got := r.read()
	if strings.HasPrefix(got, "\xef\xbb\xbf") {
		t.Errorf("the log starts with a byte-order mark")
	}
	if !strings.HasSuffix(got, "\r\n") || strings.Count(got, "\n") != strings.Count(got, "\r\n") {
		t.Errorf("not every line ends with CRLF: %q", got)
	}
	recs, _ := tstParseLog(t, got)
	if len(recs) != 1 || recs[0].path != `C:\Üb\ñ 日本` {
		t.Errorf("records = %+v, want the non-ASCII path unchanged", recs)
	}
}

func TestOpLogWritesControlCharactersOfPathAndDetailAsText(t *testing.T) {
	r := newLogRig(t)
	log := r.newLog()
	path := "C:\\a\tb\nc\rd\x01e\x7ff\x00g (h)"
	tstRecord(log, "FAILED", path, "x(1)\ny\x1fz")
	got := r.read()
	recs, _ := tstParseLog(t, got)
	if len(recs) != 1 {
		t.Fatalf("%d records, want 1 (a line break in the path must not split the line): %q", len(recs), got)
	}
	if want := `C:\a\tb\nc\rd\x01e\x7ff\x00g (h)`; recs[0].path != want {
		t.Errorf("path = %q, want %q", recs[0].path, want)
	}
	if want := `x[1]\ny\x1fz`; recs[0].detail != want {
		t.Errorf("detail = %q, want %q", recs[0].detail, want)
	}
}

func TestOpLogEmptyDetailIsADash(t *testing.T) {
	r := newLogRig(t)
	log := r.newLog()
	tstRecord(log, "SKIPPED", `C:\a`, "")
	recs, _ := tstParseLog(t, r.read())
	if len(recs) != 1 || recs[0].detail != "-" {
		t.Errorf("records = %+v, want the detail -", recs)
	}
}

func TestFormatRecordMatchesTheExamplesOfTheLogFormat(t *testing.T) {
	at := time.Date(2026, 10, 15, 10, 0, 2, 0, time.Local)
	cases := []struct{ label, action, path, detail, want string }{
		{"analyze run=a1", "RECYCLED", `D:\Games\Old`, "3.4GB", `[2026-10-15 10:00:02] [analyze run=a1] RECYCLED D:\Games\Old (3.4GB)`},
		{"analyze run=a1", "FAILED", `D:\Temp\x`, "12.0MB; the shell reported an error", `[2026-10-15 10:00:02] [analyze run=a1] FAILED D:\Temp\x (12.0MB; the shell reported an error)`},
		{"analyze run=a1", "SKIPPED", `D:\Work\proj`, `refused: protected entry inside: D:\Work\proj\.ssh`, `[2026-10-15 10:00:02] [analyze run=a1] SKIPPED D:\Work\proj (refused: protected entry inside: D:\Work\proj\.ssh)`},
		{"analyze", "RECYCLED", `C:\x`, "1B", `[2026-10-15 10:00:02] [analyze] RECYCLED C:\x (1B)`},
		{"analyze", "RECYCLED", `C:\Program Files (x86)\App`, "1B", `[2026-10-15 10:00:02] [analyze] RECYCLED C:\Program Files (x86)\App (1B)`},
		{"analyze", "RECYCLED", `C:\x`, "", `[2026-10-15 10:00:02] [analyze] RECYCLED C:\x (-)`},
	}
	for _, c := range cases {
		got := FormatRecord(at, c.label, c.action, c.path, c.detail)
		if got != c.want {
			t.Errorf("FormatRecord = %q, want %q", got, c.want)
		}
		if strings.HasSuffix(got, "\n") {
			t.Errorf("FormatRecord ends with a line break: %q", got)
		}
		if !tstRecordRe.MatchString(got) {
			t.Errorf("%q does not match the reader pattern", got)
		}
	}
}

func TestFormatRecordEscapesControlCharactersAndBracketsTheDetail(t *testing.T) {
	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.Local)
	got := FormatRecord(at, "analyze", "FAILED", "C:\\a\tb\nc\rd\x01\x7f\x00", "(x)\n\x1f(y)")
	want := `[2026-01-02 03:04:05] [analyze] FAILED C:\a\tb\nc\rd\x01\x7f\x00 ([x]\n\x1f[y])`
	if got != want {
		t.Errorf("FormatRecord = %q\nwant %q", got, want)
	}
	if strings.ContainsAny(got, "\t\r\n\x01\x7f\x00") {
		t.Errorf("FormatRecord still contains a control character: %q", got)
	}
}

func TestFormatRecordKeepsBackslashesAndParenthesesOfThePath(t *testing.T) {
	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.Local)
	got := FormatRecord(at, "analyze", "RECYCLED", `C:\a (b)\c\\d`, "1B")
	if want := `[2026-01-02 03:04:05] [analyze] RECYCLED C:\a (b)\c\\d (1B)`; got != want {
		t.Errorf("FormatRecord = %q, want %q", got, want)
	}
}

// ---------------------------------------------------------------------------
// Label: command and run id

func TestOpLogLabelFollowsTheRunVariables(t *testing.T) {
	cases := []struct {
		name, cmd, id string
		set           bool
		want          string
	}{
		{"default", "", "", false, "analyze"},
		{"command and id", "sw-analyze", "a1", true, "sw-analyze run=a1"},
		{"command only", "sw-analyze", "", true, "sw-analyze"},
		{"id only", "", "r-1_2.x", true, "analyze run=r-1_2.x"},
		{"command with a space", "my cmd", "a1", true, "analyze run=a1"},
		{"command with a bracket", "a]b", "a1", true, "analyze run=a1"},
		{"command with a control character", "a\x01b", "a1", true, "analyze run=a1"},
		{"id with a space", "sw", "a 1", true, "sw"},
		{"id with a bracket", "sw", "a]1", true, "sw"},
		{"id with a control character", "sw", "a\x07", true, "sw"},
		{"id with a tab", "sw", "a\t1", true, "sw"},
	}
	for _, c := range cases {
		r := newLogRig(t)
		if c.set {
			r.env["_SWEEPR_OPLOG_RUN_COMMAND"] = c.cmd
			r.env["_SWEEPR_OPLOG_RUN_ID"] = c.id
		}
		tstRecord(r.newLog(), "RECYCLED", `C:\x`, "1B")
		recs, markers := tstParseLog(t, r.read())
		if len(recs) != 1 || len(markers) != 1 {
			t.Errorf("%s: %d records, %d markers", c.name, len(recs), len(markers))
			continue
		}
		wantMarker := fmt.Sprintf("# ========== %s session started at 2026-10-15 10:00:00 ==========", c.want)
		if markers[0] != wantMarker {
			t.Errorf("%s: marker = %q, want %q", c.name, markers[0], wantMarker)
		}
		cmd, run, _ := strings.Cut(c.want, " run=")
		if recs[0].command != cmd || recs[0].run != run {
			t.Errorf("%s: record command %q run %q, want %q and %q", c.name, recs[0].command, recs[0].run, cmd, run)
		}
	}
}

// ---------------------------------------------------------------------------
// Nothing without a record, switches

func TestOpLogLeavesNoFileAndNoFolderWithoutARecord(t *testing.T) {
	r := newLogRig(t)
	_ = r.newLog()
	if _, err := os.Stat(r.data); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the data folder exists (%v) although nothing was recorded", err)
	}
	if n := len(r.app.recorded()); n != 0 {
		t.Errorf("%d append operations without a record", n)
	}
}

func TestOpLogCreatesTheFolderOnTheFirstWrite(t *testing.T) {
	r := newLogRig(t)
	log := tstNewOpLog(r.env, r.clk, nil)
	tstRecord(log, "RECYCLED", `C:\x`, "1B")
	if _, err := os.Stat(r.logFile); err != nil {
		t.Errorf("the log file does not exist after the first record: %v", err)
	}
	recs, markers := tstParseLog(t, r.read())
	if len(recs) != 1 || len(markers) != 1 {
		t.Errorf("%d records and %d markers, want 1 and 1", len(recs), len(markers))
	}
}

func TestOpLogSwitchedOffByTheValueOneOnly(t *testing.T) {
	r := newLogRig(t)
	r.env["SWEEPR_NO_OPLOG"] = "1"
	tstRecord(r.newLog(), "RECYCLED", `C:\x`, "1B")
	if _, err := os.Stat(r.data); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("SWEEPR_NO_OPLOG=1: the data folder exists (%v)", err)
	}
	if len(r.app.recorded()) != 0 {
		t.Errorf("SWEEPR_NO_OPLOG=1: the log was written")
	}
	for _, v := range []string{"0", "true", "", " 1", "yes"} {
		r2 := newLogRig(t)
		r2.env["SWEEPR_NO_OPLOG"] = v
		tstRecord(r2.newLog(), "RECYCLED", `C:\x`, "1B")
		if recs, _ := tstParseLog(t, r2.read()); len(recs) != 1 {
			t.Errorf("SWEEPR_NO_OPLOG=%q: %d records, want 1", v, len(recs))
		}
	}
}

// ---------------------------------------------------------------------------
// Path of the file

func TestOpLogDataDirectoryIsTrimmed(t *testing.T) {
	r := newLogRig(t)
	r.env["SWEEPR_DATA_DIR"] = "  " + r.data + "\t "
	tstRecord(r.newLog(), "RECYCLED", `C:\x`, "1B")
	if recs, _ := tstParseLog(t, r.read()); len(recs) != 1 {
		t.Errorf("%d records in %s, want 1", len(recs), r.logFile)
	}
}

func TestOpLogRelativeDataDirectoryIsRelativeToTheWorkingDirectory(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)
	r := newLogRig(t)
	r.env["SWEEPR_DATA_DIR"] = "rel-data"
	tstRecord(tstNewOpLog(r.env, r.clk, nil), "RECYCLED", `C:\x`, "1B")
	got := tstReadLog(t, filepath.Join(root, "rel-data", "config", "operations.log"))
	if recs, _ := tstParseLog(t, got); len(recs) != 1 {
		t.Errorf("%d records below the working directory, want 1", len(recs))
	}
}

func TestOpLogWithoutADataDirectoryUsesTheProfileFolder(t *testing.T) {
	for _, blank := range []string{"", "   "} {
		root := t.TempDir()
		profile := filepath.Join(root, "profile")
		r := newLogRig(t)
		r.env = map[string]string{"SWEEPR_DATA_DIR": blank, "USERPROFILE": profile}
		tstRecord(tstNewOpLog(r.env, r.clk, nil), "RECYCLED", `C:\x`, "1B")
		got := tstReadLog(t, filepath.Join(profile, ".config", "sweepr", "operations.log"))
		if recs, _ := tstParseLog(t, got); len(recs) != 1 {
			t.Errorf("data directory %q: %d records in the profile log, want 1", blank, len(recs))
		}
	}
}

func TestOpLogFallsBackToTheHomeFolderOfTheRuntimeWhenTheProfileIsEmpty(t *testing.T) {
	home := filepath.Join(t.TempDir(), "home")
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	r := newLogRig(t)
	r.env = map[string]string{"USERPROFILE": ""}
	tstRecord(tstNewOpLog(r.env, r.clk, nil), "RECYCLED", `C:\x`, "1B")
	got := tstReadLog(t, filepath.Join(home, ".config", "sweepr", "operations.log"))
	if recs, _ := tstParseLog(t, got); len(recs) != 1 {
		t.Errorf("%d records in the home log, want 1", len(recs))
	}
}

func TestOpLogIsSilentWhenNoFolderIsKnown(t *testing.T) {
	t.Setenv("HOME", "")
	t.Setenv("USERPROFILE", "")
	root := t.TempDir()
	t.Chdir(root)
	r := newLogRig(t)
	r.env = map[string]string{}
	tstRecord(tstNewOpLog(r.env, r.clk, r.app.append), "RECYCLED", `C:\x`, "1B")
	if n := len(r.app.recorded()); n != 0 {
		t.Errorf("%d append operations although no folder is known", n)
	}
	entries, _ := os.ReadDir(root)
	if len(entries) != 0 {
		t.Errorf("the working directory gained entries: %v", entries)
	}
}

// ---------------------------------------------------------------------------
// Rotation

func TestOpLogRotatesALogLargerThanFiveMiBAtTheFirstWriteOnly(t *testing.T) {
	r := newLogRig(t)
	if err := os.MkdirAll(filepath.Dir(r.logFile), 0o755); err != nil {
		t.Fatal(err)
	}
	big := bytes.Repeat([]byte("x"), 5*1024*1024+1)
	if err := os.WriteFile(r.logFile, big, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(r.logFile+".old", []byte("OLD"), 0o644); err != nil {
		t.Fatal(err)
	}
	log := tstNewOpLog(r.env, r.clk, nil)
	tstRecord(log, "RECYCLED", `C:\x`, "1B")
	old, err := os.ReadFile(r.logFile + ".old")
	if err != nil || !bytes.Equal(old, big) {
		t.Errorf("the old log was not moved to .old (read error %v, %d bytes)", err, len(old))
	}
	recs, markers := tstParseLog(t, r.read())
	if len(recs) != 1 || len(markers) != 1 {
		t.Errorf("the new log has %d records and %d markers, want 1 and 1", len(recs), len(markers))
	}

	// grown again during the same run: no second rotation
	f, err := os.OpenFile(r.logFile, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	f.Write(bytes.Repeat([]byte("y"), 6*1024*1024))
	f.Close()
	tstRecord(log, "RECYCLED", `C:\y`, "1B")
	old2, _ := os.ReadFile(r.logFile + ".old")
	if !bytes.Equal(old2, big) {
		t.Errorf("the log was rotated again during the same run")
	}
	if st, err := os.Stat(r.logFile); err != nil || st.Size() < 6*1024*1024 {
		t.Errorf("the grown log was replaced (%v)", err)
	}
}

func TestOpLogDoesNotRotateALogOfExactlyFiveMiB(t *testing.T) {
	r := newLogRig(t)
	if err := os.MkdirAll(filepath.Dir(r.logFile), 0o755); err != nil {
		t.Fatal(err)
	}
	content := bytes.Repeat([]byte("x"), 5*1024*1024)
	if err := os.WriteFile(r.logFile, content, 0o644); err != nil {
		t.Fatal(err)
	}
	tstRecord(tstNewOpLog(r.env, r.clk, nil), "RECYCLED", `C:\x`, "1B")
	if _, err := os.Stat(r.logFile + ".old"); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("a log of exactly 5 MiB was rotated (%v)", err)
	}
	got, _ := os.ReadFile(r.logFile)
	if !bytes.HasPrefix(got, content) || len(got) <= len(content) {
		t.Errorf("the record was not appended to the existing log")
	}
}

// ---------------------------------------------------------------------------
// Retries

func TestOpLogRetriesAfterASharingErrorWithGrowingPauses(t *testing.T) {
	r := newLogRig(t)
	r.app.rule = func(n int, path string) error {
		if n <= 2 {
			return errors.New("the process cannot access the file because it is being used by another process")
		}
		return nil
	}
	tstRecord(r.newLog(), "RECYCLED", `C:\x`, "1B")
	if n := len(r.app.recorded()); n != 3 {
		t.Errorf("%d attempts, want 3", n)
	}
	if got, want := r.clk.slept(), []time.Duration{20 * time.Millisecond, 40 * time.Millisecond}; !tstSameDurations(got, want) {
		t.Errorf("pauses = %v, want %v", got, want)
	}
	recs, markers := tstParseLog(t, r.read())
	if len(recs) != 1 || len(markers) != 1 {
		t.Errorf("%d records and %d markers in the file, want 1 and 1", len(recs), len(markers))
	}
}

func tstSameDurations(a, b []time.Duration) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestOpLogGivesUpAfterFiveAttemptsAndDropsTheLine(t *testing.T) {
	r := newLogRig(t)
	r.app.rule = func(n int, path string) error { return errors.New("sharing violation") }
	tstRecord(r.newLog(), "RECYCLED", `C:\x`, "1B")
	if n := len(r.app.recorded()); n != 5 {
		t.Errorf("%d attempts, want 5", n)
	}
	want := []time.Duration{20 * time.Millisecond, 40 * time.Millisecond, 60 * time.Millisecond, 80 * time.Millisecond}
	if got := r.clk.slept(); !tstSameDurations(got, want) {
		t.Errorf("pauses = %v, want %v (after the first to the fourth failed attempt)", got, want)
	}
	if got := r.read(); got != "" {
		t.Errorf("the dropped line reached the file: %q", got)
	}
}

func TestOpLogDoesNotRetryAfterAccessDenied(t *testing.T) {
	for _, denied := range []error{errTstAccess, &os.PathError{Op: "open", Path: "x", Err: os.ErrPermission}} {
		r := newLogRig(t)
		r.app.rule = func(n int, path string) error { return denied }
		tstRecord(r.newLog(), "RECYCLED", `C:\x`, "1B")
		if n := len(r.app.recorded()); n != 1 {
			t.Errorf("%d attempts after access denied, want 1", n)
		}
		if got := r.clk.slept(); len(got) != 0 {
			t.Errorf("pauses = %v, want none", got)
		}
	}
}

func TestOpLogMarkerComesWithTheFirstRecordThatIsWritten(t *testing.T) {
	r := newLogRig(t)
	r.app.rule = func(n int, path string) error {
		if n <= 5 { // every attempt of the first record fails
			return errors.New("sharing violation")
		}
		return nil
	}
	log := r.newLog()
	tstRecord(log, "RECYCLED", `C:\lost`, "1B")
	if got := r.read(); got != "" {
		t.Fatalf("the file has content after a dropped record: %q", got)
	}
	r.clk.Advance(7 * time.Second)
	tstRecord(log, "RECYCLED", `C:\kept`, "1B")
	tstRecord(log, "RECYCLED", `C:\kept2`, "1B")
	recs, markers := tstParseLog(t, r.read())
	if len(markers) != 1 || len(recs) != 2 {
		t.Fatalf("%d markers and %d records, want 1 and 2", len(markers), len(recs))
	}
	if recs[0].path != `C:\kept` {
		t.Errorf("first record = %+v, want C:\\kept (the dropped one is gone)", recs[0])
	}
	if !strings.HasPrefix(r.read(), "\r\n# ==========") || !strings.Contains(markers[0], "10:00:07") {
		t.Errorf("the marker must come with the first written record, at its time: %q", markers[0])
	}
}

func TestOpLogWritesNoSecondMarkerAfterALaterFailure(t *testing.T) {
	r := newLogRig(t)
	fail := false
	var mu sync.Mutex
	r.app.rule = func(n int, path string) error {
		mu.Lock()
		defer mu.Unlock()
		if fail {
			return errTstAccess
		}
		return nil
	}
	log := r.newLog()
	tstRecord(log, "RECYCLED", `C:\a`, "1B")
	mu.Lock()
	fail = true
	mu.Unlock()
	tstRecord(log, "RECYCLED", `C:\b`, "1B")
	mu.Lock()
	fail = false
	mu.Unlock()
	tstRecord(log, "RECYCLED", `C:\c`, "1B")
	recs, markers := tstParseLog(t, r.read())
	if len(markers) != 1 || len(recs) != 2 {
		t.Errorf("%d markers and %d records, want 1 and 2", len(markers), len(recs))
	}
}

func TestOpLogAWriteFailureNeverPanicsOrBlocks(t *testing.T) {
	r := newLogRig(t)
	r.app.rule = func(n int, path string) error { return errTstBoom }
	done := make(chan struct{})
	go func() {
		defer close(done)
		log := r.newLog()
		for i := 0; i < 3; i++ {
			tstRecord(log, "FAILED", `C:\x`, "1B")
		}
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Record blocked after write failures")
	}
}

// ---------------------------------------------------------------------------
// Debug note for a dropped line

func tstDropOperationsLog(n int, path string) error {
	if filepath.Base(path) == "operations.log" {
		return errors.New("sharing violation")
	}
	return nil
}

func TestOpLogDebugNoteNamesTheFileAndTheReasonOnlyWithDebugOn(t *testing.T) {
	r := newLogRig(t)
	r.env["SWEEPR_DEBUG"] = "1"
	r.app.rule = tstDropOperationsLog
	tstRecord(r.newLog(), "RECYCLED", `C:\x`, "1B")
	debugFile := filepath.Join(r.data, "config", "sweepr_debug_session.log")
	got := tstReadLog(t, debugFile)
	if got == "" {
		t.Fatalf("no debug note in %s", debugFile)
	}
	lines := strings.FieldsFunc(got, func(c rune) bool { return c == '\n' || c == '\r' })
	if len(lines) != 1 {
		t.Fatalf("%d debug lines, want 1: %q", len(lines), got)
	}
	if !regexp.MustCompile(`\b[0-9]{2}:[0-9]{2}:[0-9]{2}\b`).MatchString(lines[0]) || !strings.Contains(lines[0], "[DEBUG]") {
		t.Errorf("debug line %q lacks the time or the [DEBUG] marker", lines[0])
	}
	if !strings.Contains(lines[0], "operations.log") || !strings.Contains(lines[0], "sharing violation") {
		t.Errorf("debug line %q does not name the file and the reason", lines[0])
	}
}

func TestOpLogDebugNoteIsOnlyWrittenForTheValueOne(t *testing.T) {
	for _, v := range []string{"", "0", "true", "11"} {
		r := newLogRig(t)
		if v != "" {
			r.env["SWEEPR_DEBUG"] = v
		}
		r.app.rule = tstDropOperationsLog
		tstRecord(r.newLog(), "RECYCLED", `C:\x`, "1B")
		if _, err := os.Stat(filepath.Join(r.data, "config", "sweepr_debug_session.log")); err == nil {
			t.Errorf("SWEEPR_DEBUG=%q: a debug file exists", v)
		}
	}
}

func TestOpLogDebugNoteMasksControlCharactersOfTheReason(t *testing.T) {
	r := newLogRig(t)
	r.env["SWEEPR_DEBUG"] = "1"
	r.app.rule = func(n int, path string) error {
		if filepath.Base(path) == "operations.log" {
			return errors.New("first line\nsecond line\x01")
		}
		return nil
	}
	tstRecord(r.newLog(), "RECYCLED", `C:\x`, "1B")
	got := tstReadLog(t, filepath.Join(r.data, "config", "sweepr_debug_session.log"))
	lines := strings.FieldsFunc(got, func(c rune) bool { return c == '\n' || c == '\r' })
	if len(lines) != 1 || strings.ContainsRune(got, 0x01) {
		t.Errorf("the reason was not masked: %q", got)
	}
}

func TestOpLogNothingMoreHappensWhenTheDebugNoteFailsToo(t *testing.T) {
	r := newLogRig(t)
	r.env["SWEEPR_DEBUG"] = "1"
	r.app.rule = func(n int, path string) error { return errTstBoom }
	tstRecord(r.newLog(), "RECYCLED", `C:\x`, "1B")
	if _, err := os.Stat(r.data); err == nil {
		entries, _ := os.ReadDir(filepath.Join(r.data, "config"))
		for _, e := range entries {
			t.Errorf("unexpected file %s", e.Name())
		}
	}
}

// ---------------------------------------------------------------------------
// Concurrency and instances

func TestOpLogConcurrentCallersWriteOneMarkerAndWholeLines(t *testing.T) {
	r := newLogRig(t)
	log := tstNewOpLog(r.env, r.clk, nil)
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 25; i++ {
				tstRecord(log, "RECYCLED", fmt.Sprintf(`C:\g%d\i%02d`, g, i), "1.0KB")
			}
		}(g)
	}
	wg.Wait()
	recs, markers := tstParseLog(t, r.read())
	if len(markers) != 1 {
		t.Errorf("%d markers, want 1", len(markers))
	}
	if len(recs) != 200 {
		t.Fatalf("%d records, want 200", len(recs))
	}
	seen := map[string]bool{}
	for _, rec := range recs {
		seen[rec.path] = true
	}
	if len(seen) != 200 {
		t.Errorf("%d distinct paths, want 200: lines were lost or torn", len(seen))
	}
}

func TestOpLogTwoCallersAtTheFirstWriteProduceAtMostOneMarker(t *testing.T) {
	r := newLogRig(t)
	r.app.delay = 20 * time.Millisecond // widens the window of the first write
	log := r.newLog()
	var wg sync.WaitGroup
	for g := 0; g < 2; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			tstRecord(log, "RECYCLED", fmt.Sprintf(`C:\g%d`, g), "1B")
		}(g)
	}
	wg.Wait()
	recs, markers := tstParseLog(t, r.read())
	if len(markers) != 1 || len(recs) != 2 {
		t.Errorf("%d markers and %d records, want 1 and 2", len(markers), len(recs))
	}
}

func TestOpLogEveryRunWritesItsOwnMarker(t *testing.T) {
	r := newLogRig(t)
	tstRecord(tstNewOpLog(r.env, r.clk, nil), "RECYCLED", `C:\a`, "1B")
	r.clk.Advance(time.Minute)
	tstRecord(tstNewOpLog(r.env, r.clk, nil), "RECYCLED", `C:\b`, "1B")
	recs, markers := tstParseLog(t, r.read())
	if len(markers) != 2 || len(recs) != 2 {
		t.Errorf("%d markers and %d records, want 2 and 2", len(markers), len(recs))
	}
}
