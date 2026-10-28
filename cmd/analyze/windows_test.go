//go:build windows

package main

// Checks that need the real sources: the real file system (sizes, junctions,
// identities, resolution, drives) and the real recycle bin. They run only on
// Windows (CI or a test PC) and only inside folders under t.TempDir(); files
// leave a folder only through the recycle bin.
//
// Assumed constructors of the Windows implementation:
//
//	func NewOSFS() FS
//	func NewShellRecycler() Recycler

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func tstRealFS() FS             { return NewOSFS() }
func tstRealRecycler() Recycler { return NewShellRecycler() }

// tstMakeJunction creates a directory junction at link that leads to target.
// A junction needs no special privilege; when it cannot be made here (the
// helper program is missing, the folder does not allow it) the checks that
// depend on it are skipped.
func tstMakeJunction(t *testing.T, link, target string) {
	t.Helper()
	cmd := exec.Command("cmd", "/c", "mklink", "/J", link, target)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("no junction could be created, so this check does not apply (%v): %s", err, strings.TrimSpace(string(out)))
	}
}

func tstWriteFile(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
}

// tstRealEnv builds the environment map from the real variables under the
// names of the environment variables.
func tstRealEnv(t *testing.T) map[string]string {
	t.Helper()
	env := map[string]string{}
	for _, k := range []string{"USERPROFILE", "LOCALAPPDATA", "WINDIR", "SystemRoot", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData", "SystemDrive"} {
		env[k] = os.Getenv(k)
	}
	env["SWEEPR_DATA_DIR"] = filepath.Join(t.TempDir(), "data")
	return env
}

func tstEntryOf(entries []FSEntry, name string) (FSEntry, bool) {
	for _, e := range entries {
		if strings.EqualFold(e.Name, name) {
			return e, true
		}
	}
	return FSEntry{}, false
}

func TestWindowsFSListsLogicalSizesAndKinds(t *testing.T) {
	dir := t.TempDir()
	tstWriteFile(t, filepath.Join(dir, "file.bin"), 12345)
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	entries, err := tstRealFS().ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	f, ok := tstEntryOf(entries, "file.bin")
	if !ok || f.Size != 12345 || f.IsDir || f.Reparse != ReparseNone || f.Online {
		t.Errorf("file.bin = %+v, want a plain local file of 12345 bytes", f)
	}
	s, ok := tstEntryOf(entries, "sub")
	if !ok || !s.IsDir || s.Reparse != ReparseNone {
		t.Errorf("sub = %+v, want a plain folder", s)
	}
}

func TestWindowsFSReportsAJunctionAsALinkAndMeasurementDoesNotEnterIt(t *testing.T) {
	root := t.TempDir()
	tstWriteFile(t, filepath.Join(root, "own.txt"), 5)
	target := t.TempDir()
	tstWriteFile(t, filepath.Join(target, "huge.bin"), 1<<20)
	tstMakeJunction(t, filepath.Join(root, "link"), target)

	f := tstRealFS()
	entries, err := f.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	lk, ok := tstEntryOf(entries, "link")
	if !ok || lk.Reparse != ReparseLink {
		t.Fatalf("link = %+v, want Reparse = ReparseLink", lk)
	}
	l, err := tstMeasureCtx(context.Background(), f, root)
	if err != nil {
		t.Fatal(err)
	}
	if l.TotalSize != 5 || l.TotalFiles != 1 {
		t.Errorf("totals = %d bytes, %d files, want 5 and 1: the junction was followed", l.TotalSize, l.TotalFiles)
	}
	if it := tstMustItem(t, l, "link"); !it.IsLink || it.Size != 0 {
		t.Errorf("link item = %+v", it)
	}
	id, err := f.Identity(filepath.Join(root, "link"))
	if err != nil || id.Reparse != ReparseLink {
		t.Errorf("Identity(junction) = %+v, %v, want its own identity with Reparse = ReparseLink", id, err)
	}
	if tid, err := f.Identity(target); err != nil || tid.Reparse != ReparseNone || tid == id {
		t.Errorf("Identity(target) = %+v, %v, want a plain folder that differs from the junction", tid, err)
	}
}

func TestWindowsFSResolveLooksThroughAJunctionInTheParent(t *testing.T) {
	root := t.TempDir()
	target := t.TempDir()
	if err := os.Mkdir(filepath.Join(target, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	tstMakeJunction(t, filepath.Join(root, "j"), target)
	f := tstRealFS()
	want, err := f.Resolve(filepath.Join(target, "sub"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := f.Resolve(filepath.Join(root, "j", "sub"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.EqualFold(strings.TrimPrefix(got, `\\?\`), strings.TrimPrefix(want, `\\?\`)) {
		t.Errorf("Resolve through the junction = %q, want %q", got, want)
	}
}

func TestWindowsFSIdentityIsStableAndDistinguishesFolders(t *testing.T) {
	root := t.TempDir()
	a, b := filepath.Join(root, "a"), filepath.Join(root, "b")
	for _, d := range []string{a, b} {
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	tstWriteFile(t, filepath.Join(a, "f"), 1)
	f := tstRealFS()
	ia1, err1 := f.Identity(a)
	ia2, err2 := f.Identity(a)
	ib, err3 := f.Identity(b)
	if err1 != nil || err2 != nil || err3 != nil {
		t.Fatalf("errors: %v %v %v", err1, err2, err3)
	}
	if ia1 != ia2 {
		t.Errorf("the identity of a folder changed between two reads: %+v and %+v", ia1, ia2)
	}
	if ia1 == ib || ia1.Volume != ib.Volume {
		t.Errorf("identities of two folders: %+v and %+v, want the same volume and different indexes", ia1, ib)
	}
	if fi, err := f.Identity(filepath.Join(a, "f")); err != nil || fi.IsDir {
		t.Errorf("Identity(file) = %+v, %v, want a file", fi, err)
	}
}

func TestWindowsFSMissingPathsAreReportedAsNotExisting(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nope", "deeper")
	f := tstRealFS()
	if _, err := f.ReadDir(missing); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("ReadDir: %v, want a not-exist error", err)
	}
	if _, err := f.Resolve(missing); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("Resolve: %v, want a not-exist error", err)
	}
	if _, err := f.Identity(missing); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("Identity: %v, want a not-exist error", err)
	}
}

func TestWindowsFSDrivesIncludeTheSystemDrive(t *testing.T) {
	sys := os.Getenv("SystemDrive")
	if sys == "" {
		sys = "C:"
	}
	for _, d := range tstRealFS().Drives() {
		if strings.EqualFold(strings.TrimRight(d.Root, `\`), sys) {
			if d.Err != nil || d.Total <= 0 || d.Free < 0 || d.Free > d.Total {
				t.Errorf("system drive = %+v, want sizes with 0 <= free <= total", d)
			}
			return
		}
	}
	t.Errorf("the system drive %s is not among the fixed drives", sys)
}

func TestWindowsRunPrintsJSONForAFixtureWithAJunction(t *testing.T) {
	root := t.TempDir()
	tstWriteFile(t, filepath.Join(root, "a", "one.bin"), 2048)
	tstWriteFile(t, filepath.Join(root, "b.bin"), 100)
	target := t.TempDir()
	tstWriteFile(t, filepath.Join(target, "outside.bin"), 5000)
	tstMakeJunction(t, filepath.Join(root, "link"), target)

	clk := newFakeClock()
	rec := newFakeRecycler(nil, clk)
	rec.failAll = errors.New("must not be called")
	d := Deps{FS: tstRealFS(), Recycler: rec, Clock: clk}
	env := tstRealEnv(t)
	res, code := tstRunReal(t, d, []string{"--json", root}, env)
	if code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, res.stderr)
	}
	doc := tstDecode(t, res.stdout)
	for _, k := range tstDocKeys {
		if _, ok := doc[k]; !ok {
			t.Errorf("key %q is missing", k)
		}
	}
	if n, ok := tstNum(doc["total_size"]); !ok || n != 2148 {
		t.Errorf("total_size = %v, want 2148 (the junction target is not counted)", doc["total_size"])
	}
	if lk := tstEntryByName(t, doc, "link"); lk["is_link"] != true {
		t.Errorf("link = %v, want is_link true", lk)
	}
	if a := tstEntryByName(t, doc, "a"); a["is_dir"] != true {
		t.Errorf("a = %v, want a folder", a)
	}
	if len(rec.recorded()) != 0 {
		t.Errorf("the recycler was called in the JSON mode")
	}
}

func tstRunReal(t *testing.T, d Deps, args []string, env map[string]string) (tstResult, int) {
	t.Helper()
	var out, errOut strings.Builder
	code := tstRunWith(t, d, args, env, false, &out, &errOut)
	return tstResult{code: code, stdout: out.String(), stderr: errOut.String()}, code
}

func TestWindowsProtectionKnowsTheRealSystemFolders(t *testing.T) {
	env := tstRealEnv(t)
	f := tstRealFS()
	sysroot := os.Getenv("SystemRoot")
	if sysroot == "" {
		t.Skip("SystemRoot is not set")
	}
	for _, p := range []string{sysroot, filepath.Join(sysroot, "System32"), env["ProgramFiles"], env["USERPROFILE"]} {
		if p != "" && !IsProtected(p, env, f) {
			t.Errorf("%s is not protected", p)
		}
	}
	if IsProtected(filepath.Join(t.TempDir(), "x"), env, f) {
		// the parent exists, the leaf does not: the rules decide by name
		t.Errorf("a folder below the temporary folder is protected")
	}
}

// ---------------------------------------------------------------------------
// Recycle bin (real): only fixture files below t.TempDir() move, and only into
// the recycle bin.

func TestWindowsRecyclerMovesAFileToTheRecycleBin(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "move-me.bin")
	tstWriteFile(t, file, 64)
	keep := filepath.Join(root, "keep.bin")
	tstWriteFile(t, keep, 64)
	if err := tstRealRecycler().Recycle(file); err != nil {
		t.Fatalf("Recycle: %v", err)
	}
	if _, err := os.Stat(file); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the file still exists after a successful move (%v)", err)
	}
	if _, err := os.Stat(keep); err != nil {
		t.Errorf("a sibling disappeared: %v", err)
	}
}

func TestWindowsRecyclerMovesAFolderAsAWhole(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "folder")
	tstWriteFile(t, filepath.Join(dir, "a", "f1"), 10)
	tstWriteFile(t, filepath.Join(dir, "f2"), 10)
	if err := tstRealRecycler().Recycle(dir); err != nil {
		t.Fatalf("Recycle: %v", err)
	}
	if _, err := os.Stat(dir); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the folder still exists after a successful move (%v)", err)
	}
	if _, err := os.Stat(root); err != nil {
		t.Errorf("the parent folder is gone: %v", err)
	}
}

func TestWindowsRecyclerFailsForAMissingPathAndChangesNothing(t *testing.T) {
	root := t.TempDir()
	keep := filepath.Join(root, "keep.bin")
	tstWriteFile(t, keep, 64)
	if err := tstRealRecycler().Recycle(filepath.Join(root, "missing.bin")); err == nil {
		t.Errorf("Recycle of a missing path returned no error")
	}
	if _, err := os.Stat(keep); err != nil {
		t.Errorf("a sibling disappeared: %v", err)
	}
}

func TestWindowsRecycleItemsMovesAFixtureFileAndLogsIt(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "move-me.bin")
	tstWriteFile(t, file, 2048)
	env := tstRealEnv(t)
	clk := newFakeClock()
	d := Deps{FS: tstRealFS(), Recycler: tstRealRecycler(), Clock: clk}
	log := tstNewOpLog(env, clk, nil)
	res := RecycleItems(context.Background(), d, env, root, []Item{tstFileItem(file, 2048)}, log)
	tstWantOutcomes(t, res, Recycled)
	if _, err := os.Stat(file); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the file still exists (%v)", err)
	}
	recs, markers := tstParseLog(t, tstReadLog(t, filepath.Join(env["SWEEPR_DATA_DIR"], "config", "operations.log")))
	if len(recs) != 1 || len(markers) != 1 || recs[0].action != "RECYCLED" || recs[0].path != file || recs[0].detail != "2.0KB" {
		t.Errorf("log = %+v, markers %v", recs, markers)
	}
}

func TestWindowsRecycleItemsRefusesAJunctionAndAnEntryBelowOneAndTouchesNothing(t *testing.T) {
	root := t.TempDir()
	target := t.TempDir()
	tstWriteFile(t, filepath.Join(target, "inner", "keep.bin"), 10)
	tstMakeJunction(t, filepath.Join(root, "link"), target)
	env := tstRealEnv(t)
	clk := newFakeClock()
	rec := newFakeRecycler(nil, clk) // records, never touches the disk
	rec.keep = true
	d := Deps{FS: tstRealFS(), Recycler: rec, Clock: clk}
	link := tstDirItem(filepath.Join(root, "link"), 0)
	link.IsLink = true
	below := tstDirItem(filepath.Join(root, "link", "inner"), 10)
	res := RecycleItems(context.Background(), d, env, root, []Item{link, below}, tstNewOpLog(env, clk, nil))
	tstWantOutcomes(t, res, Skipped, Skipped)
	if len(rec.recorded()) != 0 {
		t.Errorf("the recycler was called: %q", rec.recorded())
	}
	if _, err := os.Stat(filepath.Join(target, "inner", "keep.bin")); err != nil {
		t.Errorf("the junction target was changed: %v", err)
	}
}

func TestWindowsRecycleItemsRefusesTheSystemFolderWithoutTouchingIt(t *testing.T) {
	sysroot := os.Getenv("SystemRoot")
	if sysroot == "" {
		t.Skip("SystemRoot is not set")
	}
	env := tstRealEnv(t)
	clk := newFakeClock()
	rec := newFakeRecycler(nil, clk)
	rec.keep = true // a recorder: the real recycler is never given a system path in a test
	d := Deps{FS: tstRealFS(), Recycler: rec, Clock: clk}
	parent := filepath.Dir(sysroot)
	res := RecycleItems(context.Background(), d, env, parent, []Item{tstDirItem(sysroot, 1)}, tstNewOpLog(env, clk, nil))
	tstWantOutcomes(t, res, Skipped)
	if len(rec.recorded()) != 0 {
		t.Errorf("the recycler was called for the Windows folder: %q", rec.recorded())
	}
}

func TestWindowsOpLogAppendsWhileAnotherProcessHasTheFileOpenForReading(t *testing.T) {
	data := filepath.Join(t.TempDir(), "data")
	logFile := filepath.Join(data, "config", "operations.log")
	if err := os.MkdirAll(filepath.Dir(logFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(logFile, []byte("existing\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	reader, err := os.Open(logFile) // shares read and write access like a log viewer
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	env := map[string]string{"SWEEPR_DATA_DIR": data}
	tstRecord(tstNewOpLog(env, newFakeClock(), nil), "RECYCLED", `C:\x`, "1B")
	got := tstReadLog(t, logFile)
	if !strings.HasPrefix(got, "existing\r\n") || !strings.Contains(got, "RECYCLED C:\\x (1B)") {
		t.Errorf("log = %q, want the record appended behind the existing line", got)
	}
}
