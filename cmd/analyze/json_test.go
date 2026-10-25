package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPerformScanForJSONIncludesAllEntriesAndLargeFiles(t *testing.T) {
	root := t.TempDir()

	totalFiles := maxEntries + 6
	for i := 0; i < totalFiles-1; i++ {
		path := filepath.Join(root, fmt.Sprintf("small-%02d.bin", i))
		if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
			t.Fatalf("write small file %d: %v", i, err)
		}
	}
	hugeFile := filepath.Join(root, "huge.bin")
	if err := os.WriteFile(hugeFile, make([]byte, 2<<20), 0o644); err != nil {
		t.Fatalf("write huge file: %v", err)
	}

	result, err := performDirectoryScanForJSON(root)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if result.Overview {
		t.Fatal("expected a directory result")
	}
	if result.ScanStatus != scanComplete {
		t.Fatalf("expected complete scan, got %v", result.ScanStatus)
	}
	if got := len(result.Entries); got != totalFiles {
		t.Fatalf("expected every one of %d entries beyond the TUI cap, got %d", totalFiles, got)
	}
	if result.TotalFiles != int64(totalFiles) {
		t.Fatalf("expected %d total files, got %d", totalFiles, result.TotalFiles)
	}
	if result.Entries[0].Name != "huge.bin" {
		t.Fatalf("expected entries sorted largest first, got %q first", result.Entries[0].Name)
	}
	found := false
	for _, file := range result.LargeFiles {
		if file.Name == "huge.bin" && file.Path == hugeFile {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected huge.bin in large_files, got %#v", result.LargeFiles)
	}
}

func TestDirectoryScanForJSONMarksUnreadableChildUnavailable(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "file.bin"), []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	locked := filepath.Join(root, "locked")
	if err := os.Mkdir(locked, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Skipf("cannot remove permissions here: %v", err)
	}
	defer os.Chmod(locked, 0o755)
	if _, err := os.ReadDir(locked); err == nil {
		t.Skip("the test user can still read a mode 000 folder")
	}

	result, err := performDirectoryScanForJSON(root)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if result.ScanStatus != scanPartial {
		t.Fatalf("a scan that lost a child must be partial, got %v", result.ScanStatus)
	}
	for _, entry := range result.Entries {
		if entry.Path == locked {
			if entry.ScanStatus != scanUnavailable {
				t.Fatalf("unreadable child must be unavailable, got %v", entry.ScanStatus)
			}
			return
		}
	}
	t.Fatalf("unreadable child missing from entries: %#v", result.Entries)
}

func TestRunJSONModeRefusesMissingDirectory(t *testing.T) {
	var out bytes.Buffer
	err := runJSONMode(&out, filepath.Join(t.TempDir(), "missing"), false)
	if err == nil {
		t.Fatal("expected an error for a missing directory")
	}
	if out.Len() != 0 {
		t.Fatalf("nothing may reach stdout on failure, got %q", out.String())
	}
}

func TestRunJSONModeEmitsTheMacOSFieldNames(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a.bin"), []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "node_modules"), 0o755); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	if err := runJSONMode(&out, root, false); err != nil {
		t.Fatalf("runJSONMode: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(out.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not one JSON object: %v\n%s", err, out.String())
	}
	for _, key := range []string{"scan_status", "path", "overview", "entries", "total_size", "total_files"} {
		if _, ok := decoded[key]; !ok {
			t.Fatalf("missing top-level key %q in %s", key, out.String())
		}
	}
	if decoded["scan_status"] != "complete" {
		t.Fatalf("scan_status must be the text state, got %#v", decoded["scan_status"])
	}
	entries := decoded["entries"].([]any)
	for _, raw := range entries {
		entry := raw.(map[string]any)
		for _, key := range []string{"scan_status", "name", "path", "size", "is_dir"} {
			if _, ok := entry[key]; !ok {
				t.Fatalf("entry missing %q: %#v", key, entry)
			}
		}
		if _, ok := entry["insight"]; ok {
			t.Fatalf("insight is overview-only: %#v", entry)
		}
	}
}

func TestJSONEntriesFromDirEntriesIncludesMetadata(t *testing.T) {
	oldAccess := time.Now().AddDate(0, 0, -120)
	// A relative path, so the host temporary directory, which sw clean
	// already covers on Windows, does not hide the cache evidence.
	t.Chdir(t.TempDir())
	cacheDir := "cache"
	if err := os.Mkdir(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}
	tag := "Signature: 8a477f597d28d172789f06886806bc55\n"
	if err := os.WriteFile(filepath.Join(cacheDir, "CACHEDIR.TAG"), []byte(tag), 0o644); err != nil {
		t.Fatal(err)
	}

	entries := jsonEntriesFromDirEntries([]dirEntry{
		{Name: "old.bin", Path: `C:\fixture\old.bin`, Size: 42, LastAccess: oldAccess},
		{Name: "cache", Path: cacheDir, Size: 128, IsDir: true},
	}, false, nil)

	if entries[0].LastAccess != oldAccess.UTC().Format(time.RFC3339) {
		t.Fatalf("expected RFC3339 UTC last_access, got %q", entries[0].LastAccess)
	}
	if !entries[1].Cleanable {
		t.Fatal("expected the tagged cache folder to be marked cleanable")
	}
}

func TestJSONEntriesFromDirEntriesMarksOverviewInsights(t *testing.T) {
	entry := dirEntry{Name: "Old Downloads (90d+)", Path: `C:\Users\fixture\Downloads`, Size: 256, IsDir: true}
	entries := jsonEntriesFromDirEntries([]dirEntry{entry}, true, map[string]bool{entry.Path: true})
	if len(entries) != 1 || !entries[0].Insight {
		t.Fatalf("expected one insight entry, got %#v", entries)
	}
}

func TestOverviewJSONMapsFailedMeasurementsHonestly(t *testing.T) {
	rows := []dirEntry{
		{Name: "Complete", Path: "complete", IsDir: true, Size: -1},
		{Name: "Timed out", Path: "partial", IsDir: true, Size: -1},
		{Name: "Denied", Path: "denied", IsDir: true, Size: -1},
		{Name: "Empty insight", Path: "empty", IsDir: true, Size: -1},
	}
	measure := func(_ context.Context, path string) (int64, error) {
		switch path {
		case "complete":
			return 1000, nil
		case "partial":
			return 500, context.DeadlineExceeded
		case "denied":
			return 0, os.ErrPermission
		default:
			return 0, nil
		}
	}

	result := performOverviewScanForJSONWithEntries([]dirEntry{rows[3]}, rows, measure)

	if !result.Overview || result.Path != "" {
		t.Fatalf("unexpected overview identity: path=%q overview=%v", result.Path, result.Overview)
	}
	if result.ScanStatus != scanPartial {
		t.Fatalf("an overview with failed rows must be partial, got %v", result.ScanStatus)
	}
	states := map[string]scanState{}
	for _, entry := range result.Entries {
		states[entry.Path] = entry.ScanStatus
	}
	if _, ok := states["empty"]; ok {
		t.Fatal("a completely measured empty row is omitted, as in the TUI")
	}
	want := map[string]scanState{"complete": scanComplete, "partial": scanPartial, "denied": scanUnavailable}
	for path, state := range want {
		if states[path] != state {
			t.Fatalf("%s: want %v, got %v (all %#v)", path, state, states[path], states)
		}
	}
	if result.TotalSize != 1500 {
		t.Fatalf("total keeps the bytes reached, want 1500, got %d", result.TotalSize)
	}
	if result.Entries[0].Path != "complete" {
		t.Fatalf("overview rows sort largest first, got %q first", result.Entries[0].Path)
	}
}

func TestOverviewJSONEntriesIsAListWhenEmpty(t *testing.T) {
	result := performOverviewScanForJSONWithEntries(nil, nil, func(context.Context, string) (int64, error) { return 0, nil })
	var out bytes.Buffer
	encoder := json.NewEncoder(&out)
	if err := encoder.Encode(result); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"entries":[]`) {
		t.Fatalf("entries must encode as [], got %s", out.String())
	}
}

func TestScanStateMarshalTextRejectsUnknownState(t *testing.T) {
	if _, err := scanState(9).MarshalText(); err == nil {
		t.Fatal("expected an error for an unknown scan state")
	}
	for state, text := range map[scanState]string{scanComplete: "complete", scanPartial: "partial", scanUnavailable: "unavailable"} {
		got, err := state.MarshalText()
		if err != nil || string(got) != text {
			t.Fatalf("%d: got %q, %v", state, got, err)
		}
	}
}

func TestParseArgsJSONFlagBeforePath(t *testing.T) {
	var stdout, stderr bytes.Buffer
	opts, code, keepGoing := parseArgs([]string{"--json", `D:\`}, &stdout, &stderr)
	if !keepGoing || code != 0 {
		t.Fatalf("expected to run, got code=%d keepGoing=%v stderr=%q", code, keepGoing, stderr.String())
	}
	if !opts.jsonMode || len(opts.args) != 1 || opts.args[0] != `D:\` {
		t.Fatalf("unexpected options %#v", opts)
	}

	opts, _, _ = parseArgs([]string{`D:\`}, &stdout, &stderr)
	if opts.jsonMode {
		t.Fatal("JSON mode must be opt-in")
	}
}

func TestParseArgsHelpAndUnknownFlag(t *testing.T) {
	var stdout, stderr bytes.Buffer
	_, code, keepGoing := parseArgs([]string{"--help"}, &stdout, &stderr)
	if keepGoing || code != 0 || !strings.Contains(stdout.String(), "--json") {
		t.Fatalf("help: code=%d keepGoing=%v stdout=%q", code, keepGoing, stdout.String())
	}

	stdout.Reset()
	_, code, keepGoing = parseArgs([]string{"--bogus"}, &stdout, &stderr)
	if keepGoing || code != 1 || stdout.Len() != 0 || stderr.Len() == 0 {
		t.Fatalf("unknown flag: code=%d keepGoing=%v stdout=%q stderr=%q", code, keepGoing, stdout.String(), stderr.String())
	}
}

// Windows PowerShell 5.1 decodes a native command's stdout with the console
// code page, so raw UTF-8 garbles a Chinese folder name before ConvertFrom-Json
// sees it. Every byte must be ASCII, and the names must still decode exactly.
func TestRunJSONModeEscapesNonASCIIAsUnicodeEscapes(t *testing.T) {
	root := t.TempDir()
	names := []string{"测试目录", "Ünïcode", "😀.txt"}
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(root, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	var out bytes.Buffer
	if err := runJSONMode(&out, root, false); err != nil {
		t.Fatalf("runJSONMode: %v", err)
	}
	for i, b := range out.Bytes() {
		if b > 0x7f {
			t.Fatalf("byte %d is not ASCII (0x%02x) in %s", i, b, out.String())
		}
	}
	for _, escape := range []string{`\u6d4b\u8bd5\u76ee\u5f55`, `\u00dcn\u00efcode`, `\ud83d\ude00.txt`} {
		if !strings.Contains(out.String(), escape) {
			t.Fatalf("expected %s in %s", escape, out.String())
		}
	}
	var decoded struct {
		Entries []struct {
			Name string `json:"name"`
		} `json:"entries"`
	}
	if err := json.Unmarshal(out.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not JSON: %v", err)
	}
	got := map[string]bool{}
	for _, entry := range decoded.Entries {
		got[entry.Name] = true
	}
	for _, name := range names {
		if !got[name] {
			t.Fatalf("%q did not round-trip, got %#v", name, got)
		}
	}
}

// Every overview row on Windows lies on a drive the overview also lists, so
// adding the folders to the drives' used bytes counted the same files twice.
func TestOverviewJSONTotalCountsNestedRowsOnce(t *testing.T) {
	home := filepath.Join(string(filepath.Separator), "fixture", "Users", "me")
	t.Setenv("USERPROFILE", home)
	drive := filepath.Join(string(filepath.Separator), "fixture")
	appData := filepath.Join(home, "AppData")
	rows := []dirEntry{
		{Name: "Home", Path: home, IsDir: true, Size: -1},
		{Name: "User AppData", Path: appData, IsDir: true, Size: -1},
		{Name: "npm Cache", Path: filepath.Join(appData, "Local", "npm-cache"), IsDir: true, Size: -1},
		{Name: "Old Downloads (90d+)", Path: filepath.Join(home, "Downloads"), IsDir: true, Size: -1},
		{Name: "Local Disk", Path: drive, IsDir: true, Size: -1},
	}
	sizes := map[string]int64{home: 300, appData: 200, rows[2].Path: 50, rows[3].Path: 40, drive: 1000}
	measure := func(_ context.Context, path string) (int64, error) { return sizes[path], nil }

	result := performOverviewScanForJSONWithEntries(nil, rows, measure)
	if result.TotalSize != 1000 {
		t.Fatalf("the drive already holds every folder row, want 1000, got %d", result.TotalSize)
	}
	if len(result.Entries) != len(rows) {
		t.Fatalf("every row is still listed, want %d, got %d", len(rows), len(result.Entries))
	}

	// Without a drive row, Home (measured without AppData) and AppData are
	// disjoint, and the caches inside them are already counted.
	result = performOverviewScanForJSONWithEntries(nil, rows[:4], measure)
	if result.TotalSize != 500 {
		t.Fatalf("Home plus AppData, want 500, got %d", result.TotalSize)
	}

	// A drive whose measurement failed holds nothing in the total, so the
	// rows on it still count.
	failing := func(ctx context.Context, path string) (int64, error) {
		if path == drive {
			return 0, os.ErrPermission
		}
		return measure(ctx, path)
	}
	result = performOverviewScanForJSONWithEntries(nil, rows, failing)
	if result.TotalSize != 500 {
		t.Fatalf("rows on an unmeasured drive still count, want 500, got %d", result.TotalSize)
	}
}
