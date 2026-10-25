package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Every test in this package writes its operation log to a temporary file, so
// a test run never adds rows to the real ~/.config/sweepr/operations.log.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "sweepr-analyze-oplog-")
	if err != nil {
		panic(err)
	}
	operationsLogPath = func() string { return filepath.Join(dir, "operations.log") }
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

func useTestOperationsLog(t *testing.T) string {
	t.Helper()
	file := filepath.Join(t.TempDir(), "sweepr", "operations.log")
	previousPath, previousNow, previousStarted := operationsLogPath, operationsLogNow, operationsLogStarted
	operationsLogPath = func() string { return file }
	operationsLogNow = func() time.Time { return time.Date(2026, 10, 16, 9, 30, 5, 0, time.Local) }
	operationsLogStarted = false
	t.Setenv("SWEEPR_NO_OPLOG", "")
	t.Setenv("_SWEEPR_OPLOG_RUN_COMMAND", "analyze")
	t.Setenv("_SWEEPR_OPLOG_RUN_ID", "run-canary")
	t.Cleanup(func() {
		operationsLogPath, operationsLogNow, operationsLogStarted = previousPath, previousNow, previousStarted
	})
	return file
}

func readLog(t *testing.T, file string) string {
	t.Helper()
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestOperationLogMatchesThePowerShellRecordFormat(t *testing.T) {
	file := useTestOperationsLog(t)

	logDeleteResult(`D:\SteamLibrary`, "312.4 GB", recycledVerified, nil)
	logDeleteResult(`C:\Program Files (x86)\Big`, "80.0 GB", deletedPermanently, nil)
	logDeleteResult(`C:\Users\me\x`, "", recycledUnverified, nil)
	logDeleteResult(`C:\Users\me\locked`, "1.0 KB", recycledVerified, errors.New("move to Recycle Bin was cancelled (by user)"))

	want := "\r\n# ========== analyze run=run-canary session started at 2026-10-16 09:30:05 ==========\r\n" +
		"[2026-10-16 09:30:05] [analyze run=run-canary] RECYCLED D:\\SteamLibrary (312.4 GB)\r\n" +
		"[2026-10-16 09:30:05] [analyze run=run-canary] REMOVED C:\\Program Files (x86)\\Big (80.0 GB; the Recycle Bin did not grow, so the shell probably deleted it permanently)\r\n" +
		"[2026-10-16 09:30:05] [analyze run=run-canary] RECYCLED C:\\Users\\me\\x (Recycle Bin not verified)\r\n" +
		"[2026-10-16 09:30:05] [analyze run=run-canary] FAILED C:\\Users\\me\\locked (1.0 KB; move to Recycle Bin was cancelled [by user])\r\n"
	if got := readLog(t, file); got != want {
		t.Fatalf("log =\n%q\nwant\n%q", got, want)
	}
}

func TestOperationLogEscapesControlCharacters(t *testing.T) {
	if got := logValue("C:\\dir\\x\tname\nforged\x1b"); got != `C:\dir\x\tname\nforged\x1b` {
		t.Fatalf("logValue = %q", got)
	}
}

func TestOperationLogHonorsMoNoOplog(t *testing.T) {
	file := useTestOperationsLog(t)
	t.Setenv("SWEEPR_NO_OPLOG", "1")
	logDeleteResult(`C:\x`, "1 B", recycledVerified, nil)
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatalf("log written with SWEEPR_NO_OPLOG=1: %v", err)
	}
}

func TestOperationLogMovesAnOversizedLogAside(t *testing.T) {
	file := useTestOperationsLog(t)
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte(strings.Repeat("x", 64)), 0o644); err != nil {
		t.Fatal(err)
	}
	previous := operationsLogMaxBytes
	operationsLogMaxBytes = 16
	t.Cleanup(func() { operationsLogMaxBytes = previous })

	writeOperation("RECYCLED", `C:\x`, "")

	if old := readLog(t, file+".old"); old != strings.Repeat("x", 64) {
		t.Fatalf(".old = %q", old)
	}
	if strings.Contains(readLog(t, file), "xxxx") {
		t.Fatal("rotated content left in the live log")
	}
}

// A deletion through the analyzer's own path writes its row, and a refusal
// is recorded as FAILED.
func TestRecyclePathWithProgressRecordsTheOutcome(t *testing.T) {
	file := useTestOperationsLog(t)
	previous := recycleItem
	recycleItem = func(string) (recycleOutcome, error) { return deletedPermanently, nil }
	t.Cleanup(func() { recycleItem = previous })

	target := filepath.Join(t.TempDir(), "gone")
	if err := os.WriteFile(target, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _ = recyclePathWithProgress(target, "1 B", nil)
	_, _ = recyclePathWithProgress(filepath.Join(t.TempDir(), "never-existed"), "", nil)

	log := readLog(t, file)
	if !strings.Contains(log, "] FAILED "+target+" (1 B; ") && !strings.Contains(log, "] REMOVED "+target+" (1 B; the Recycle Bin did not grow") {
		t.Fatalf("no row for %s in\n%s", target, log)
	}
	if strings.Contains(log, "never-existed") {
		t.Fatalf("a path that was never there was recorded:\n%s", log)
	}
}

func TestOperationLogFailureReachesDebugSession(t *testing.T) {
	file := useTestOperationsLog(t)
	home := t.TempDir()
	t.Setenv("USERPROFILE", home)
	t.Setenv("SWEEPR_DEBUG", "1")
	debugFile := filepath.Join(home, ".config", "sweepr", "sweepr_debug_session.log")
	if err := os.MkdirAll(filepath.Dir(debugFile), 0755); err != nil {
		t.Fatal(err)
	}
	// An existing directory cannot be opened as an append-only operation log.
	if err := os.MkdirAll(file, 0755); err != nil {
		t.Fatal(err)
	}
	writeOperation("RECYCLED", "fixture", "")
	text := readLog(t, debugFile)
	if !strings.Contains(text, "[DEBUG] operations.log not written:") || !strings.Contains(text, file) {
		t.Fatalf("missing actionable debug record: %q", text)
	}
	if operationsLogStarted {
		t.Fatal("failed append marked the session started")
	}
}

func TestOperationLogFailureStaysQuietWithoutDebug(t *testing.T) {
	file := useTestOperationsLog(t)
	home := t.TempDir()
	t.Setenv("USERPROFILE", home)
	t.Setenv("SWEEPR_DEBUG", "")
	if err := os.MkdirAll(file, 0755); err != nil {
		t.Fatal(err)
	}
	writeOperation("RECYCLED", "fixture", "")
	if _, err := os.Stat(filepath.Join(home, ".config", "sweepr", "sweepr_debug_session.log")); !os.IsNotExist(err) {
		t.Fatalf("unexpected debug log: %v", err)
	}
}
