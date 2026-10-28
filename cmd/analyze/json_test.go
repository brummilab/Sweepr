package main

// The JSON document of a folder and of the overview (schema, values, null for
// "not measured", plain ASCII, one indented document).

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

var (
	tstDocKeys   = []string{"scan_status", "path", "overview", "entries", "large_files", "total_size", "total_online_size", "total_files"}
	tstEntryKeys = []string{"scan_status", "name", "path", "size", "online_size", "is_dir", "is_link", "cloud"}
)

// tstJSONRun runs `--json` (or the given arguments) and returns the parsed document.
func tstJSONRun(t *testing.T, rr *tstRunRig, env map[string]string, args ...string) (map[string]any, tstResult) {
	t.Helper()
	res := rr.run(t, args, env, false)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	return tstDecode(t, res.stdout), res
}

func tstFolderDoc(t *testing.T, rr *tstRunRig, path string) map[string]any {
	t.Helper()
	env, _ := tstQuietEnv(t)
	doc, _ := tstJSONRun(t, rr, env, "--json", path)
	return doc
}

func TestJSONFolderDocumentHasAllKeysAndTheScannedValues(t *testing.T) {
	rr := newDataRig()
	doc := tstFolderDoc(t, rr, `C:\Data`)
	for _, k := range tstDocKeys {
		if _, ok := doc[k]; !ok {
			t.Errorf("key %q is missing", k)
		}
	}
	if doc["scan_status"] != "complete" || doc["path"] != `C:\Data` || doc["overview"] != false {
		t.Errorf("scan_status %v, path %v, overview %v", doc["scan_status"], doc["path"], doc["overview"])
	}
	if n, ok := tstNum(doc["total_size"]); !ok || n != tstSimpleTotal {
		t.Errorf("total_size = %v, want %d", doc["total_size"], tstSimpleTotal)
	}
	if n, ok := tstNum(doc["total_online_size"]); !ok || n != 0 {
		t.Errorf("total_online_size = %v, want 0", doc["total_online_size"])
	}
	if n, ok := tstNum(doc["total_files"]); !ok || n != 5 {
		t.Errorf("total_files = %v, want 5", doc["total_files"])
	}
}

func TestJSONEntriesAreSortedAndHaveEveryKey(t *testing.T) {
	rr := newDataRig()
	doc := tstFolderDoc(t, rr, `C:\Data`)
	if got := tstEntryNames(t, doc); !tstSameStrings(got, []string{"alpha", "beta", "gamma", "notes.txt"}) {
		t.Errorf("entries = %v, want sorted by size", got)
	}
	for _, e := range tstArr(t, doc, "entries") {
		m := e.(map[string]any)
		for _, k := range tstEntryKeys {
			if _, ok := m[k]; !ok {
				t.Errorf("entry %v: key %q is missing", m["name"], k)
			}
		}
	}
}

func TestJSONEntryValues(t *testing.T) {
	rr := newDataRig()
	doc := tstFolderDoc(t, rr, `C:\Data`)
	a := tstEntryByName(t, doc, "alpha")
	if a["path"] != `C:\Data\alpha` || a["scan_status"] != "complete" || a["is_dir"] != true || a["is_link"] != false || a["cloud"] != false {
		t.Errorf("alpha = %v", a)
	}
	if n, ok := tstNum(a["size"]); !ok || n != 5*tstGiB {
		t.Errorf("alpha.size = %v, want %d", a["size"], 5*tstGiB)
	}
	if n, ok := tstNum(a["online_size"]); !ok || n != 0 {
		t.Errorf("alpha.online_size = %v, want 0", a["online_size"])
	}
	n := tstEntryByName(t, doc, "notes.txt")
	if n["is_dir"] != false {
		t.Errorf("notes.txt.is_dir = %v, want false", n["is_dir"])
	}
}

func TestJSONNumbersAreWrittenAsIntegers(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{"--json", `C:\Data`}, env, false)
	if res.code != 0 {
		t.Fatalf("exit %d", res.code)
	}
	dec := json.NewDecoder(strings.NewReader(res.stdout))
	dec.UseNumber()
	var doc map[string]any
	if err := dec.Decode(&doc); err != nil {
		t.Fatal(err)
	}
	var walk func(v any, path string)
	walk = func(v any, path string) {
		switch x := v.(type) {
		case json.Number:
			if strings.ContainsAny(x.String(), ".eE") {
				t.Errorf("%s = %s, want an integer", path, x)
			}
		case map[string]any:
			for k, vv := range x {
				walk(vv, path+"."+k)
			}
		case []any:
			for _, vv := range x {
				walk(vv, path+"[]")
			}
		}
	}
	walk(doc, "$")
}

func TestJSONLargeFilesCarryNamePathAndSize(t *testing.T) {
	rr := newDataRig()
	doc := tstFolderDoc(t, rr, `C:\Data`)
	files := tstArr(t, doc, "large_files")
	if len(files) != 4 {
		t.Fatalf("%d large files, want 4: %v", len(files), files)
	}
	first := files[0].(map[string]any)
	if first["name"] != "d1.bin" || first["path"] != `C:\Data\alpha\deep\d1.bin` {
		t.Errorf("first large file = %v", first)
	}
	if n, ok := tstNum(first["size"]); !ok || n != 3*tstGiB {
		t.Errorf("first large file size = %v, want %d", first["size"], 3*tstGiB)
	}
}

func TestJSONEmptyFolderHasEmptyArraysNotNull(t *testing.T) {
	rr := newDataRig()
	rr.fs.dir(`C:\Empty`)
	doc := tstFolderDoc(t, rr, `C:\Empty`)
	if a := tstArr(t, doc, "entries"); len(a) != 0 {
		t.Errorf("entries = %v, want []", a)
	}
	if a := tstArr(t, doc, "large_files"); len(a) != 0 {
		t.Errorf("large_files = %v, want []", a)
	}
	for _, k := range []string{"total_size", "total_online_size", "total_files"} {
		if n, ok := tstNum(doc[k]); !ok || n != 0 {
			t.Errorf("%s = %v, want 0", k, doc[k])
		}
	}
	if doc["scan_status"] != "complete" {
		t.Errorf("scan_status = %v, want complete", doc["scan_status"])
	}
}

func TestJSONModeMeasuresEveryFolderExactlyOnce(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{"--json", `C:\Data`}, env, false)
	if res.code != 0 {
		t.Fatalf("exit %d, stderr %q", res.code, res.stderr)
	}
	for _, p := range []string{`C:\Data`, `C:\Data\alpha`, `C:\Data\alpha\deep`, `C:\Data\beta`, `C:\Data\gamma`} {
		if n := rr.fs.readCount(p); n != 1 {
			t.Errorf("%s was read %d times, want once", p, n)
		}
	}
}

func TestJSONIsOneIndentedDocumentWithoutBOMOrControlCharacters(t *testing.T) {
	rr := newDataRig()
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{"--json", `C:\Data`}, env, true)
	out := res.stdout
	if strings.HasPrefix(out, "\xef\xbb\xbf") {
		t.Errorf("stdout starts with a byte-order mark")
	}
	if strings.ContainsRune(out, 0x1b) {
		t.Errorf("stdout contains an escape character")
	}
	if strings.Contains(out, "\r") {
		t.Errorf("stdout contains carriage returns, want \\n")
	}
	if !strings.HasSuffix(out, "\n") || strings.HasSuffix(out, "\n\n") {
		t.Errorf("stdout must end with exactly one newline")
	}
	if !strings.Contains(out, "\n  \"") {
		t.Errorf("the document is not indented by two spaces:\n%s", out)
	}
	tstDecode(t, out)
	if res.stderr != "" {
		t.Errorf("stderr = %q, want empty", res.stderr)
	}
}

func TestJSONIsPlainASCIIAndKeepsTheText(t *testing.T) {
	rr := newDataRig()
	names := []string{"Übung", "\U0001F4C1 Ordner", "日本語"}
	for _, n := range names {
		rr.fs.file(`C:\Üb\`+n+`\f`, 10)
	}
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{"--json", `C:\Üb`}, env, false)
	if res.code != 0 {
		t.Fatalf("exit %d, stderr %q", res.code, res.stderr)
	}
	for i := 0; i < len(res.stdout); i++ {
		if res.stdout[i] >= 0x80 {
			t.Fatalf("stdout holds a byte >= 0x80 at offset %d: %q", i, res.stdout)
		}
	}
	for _, want := range []string{`\u00dcbung`, `\ud83d\udcc1`, `\u65e5\u672c\u8a9e`, `C:\\\u00dcb`} {
		if !strings.Contains(res.stdout, want) {
			t.Errorf("stdout does not contain %s", want)
		}
	}
	for _, m := range regexp.MustCompile(`\\u[0-9A-Fa-f]{4}`).FindAllString(res.stdout, -1) {
		if m != strings.ToLower(m) {
			t.Errorf("escape %s is not lower case", m)
		}
	}
	doc := tstDecode(t, res.stdout)
	if doc["path"] != `C:\Üb` {
		t.Errorf("parsed path = %q, want C:\\Üb", doc["path"])
	}
	got := tstEntryNames(t, doc)
	for _, n := range names {
		found := false
		for _, g := range got {
			if g == n {
				found = true
			}
		}
		if !found {
			t.Errorf("parsed names %v lack %q", got, n)
		}
	}
}

func TestJSONNeverReplacesNotMeasuredByZero(t *testing.T) {
	rr := newDataRig()
	rr.fs.file(`C:\M\readable\f`, 10)
	rr.fs.file(`C:\M\partial\f`, 10)
	rr.fs.failDir(`C:\M\partial\locked`, errTstAccess)
	rr.fs.dir(`C:\M\onlyfail`)
	rr.fs.failDir(`C:\M\onlyfail\locked`, errTstAccess)
	rr.fs.failDir(`C:\M\unavailable`, errTstAccess)
	rr.fs.dir(`C:\M\empty`)
	doc := tstFolderDoc(t, rr, `C:\M`)
	if doc["scan_status"] != "partial" {
		t.Errorf("scan_status = %v, want partial", doc["scan_status"])
	}

	p := tstEntryByName(t, doc, "partial")
	if p["scan_status"] != "partial" {
		t.Errorf("partial.scan_status = %v", p["scan_status"])
	}
	if n, ok := tstNum(p["size"]); !ok || n != 10 {
		t.Errorf("partial.size = %v, want the known 10", p["size"])
	}

	of := tstEntryByName(t, doc, "onlyfail")
	if of["scan_status"] != "partial" || of["size"] != nil {
		t.Errorf("onlyfail = scan_status %v, size %v, want partial and null", of["scan_status"], of["size"])
	}
	if n, ok := tstNum(of["online_size"]); !ok || n != 0 {
		t.Errorf("onlyfail.online_size = %v, want the number 0", of["online_size"])
	}

	u := tstEntryByName(t, doc, "unavailable")
	if u["scan_status"] != "unavailable" || u["size"] != nil || u["online_size"] != nil {
		t.Errorf("unavailable = %v, want scan_status unavailable, size null, online_size null", u)
	}

	e := tstEntryByName(t, doc, "empty")
	if n, ok := tstNum(e["size"]); !ok || n != 0 || e["scan_status"] != "complete" {
		t.Errorf("empty = %v, want size 0 and complete: a readable empty folder is measured", e)
	}
	if n, ok := tstNum(doc["total_size"]); !ok || n != 20 {
		t.Errorf("total_size = %v, want the known lower bound 20", doc["total_size"])
	}
}

func TestJSONLinkEntryIsAnUnfollowedLinkOfSizeZero(t *testing.T) {
	rr := newDataRig()
	rr.fs.file(`C:\L\own.txt`, 5)
	rr.fs.link(`C:\L\link`, `D:\big`)
	rr.fs.file(`D:\big\huge.bin`, 50*tstGiB)
	doc := tstFolderDoc(t, rr, `C:\L`)
	lk := tstEntryByName(t, doc, "link")
	if lk["is_link"] != true || lk["name"] != "link" {
		t.Errorf("link = %v, want is_link true and the plain name", lk)
	}
	if n, ok := tstNum(lk["size"]); !ok || n != 0 {
		t.Errorf("link.size = %v, want 0", lk["size"])
	}
	if n, ok := tstNum(doc["total_size"]); !ok || n != 5 {
		t.Errorf("total_size = %v, want 5", doc["total_size"])
	}
	if n, ok := tstNum(doc["total_files"]); !ok || n != 1 {
		t.Errorf("total_files = %v, want 1", doc["total_files"])
	}
	rr.fs.assertNoLinkFollowed(t)
}

func TestJSONCloudEntryReportsLocalAndOnlineBytesApart(t *testing.T) {
	rr := newDataRig()
	rr.fs.file(`C:\C\D\local.bin`, 100)
	rr.fs.cloudFile(`C:\C\D\online.bin`, tstGiB, true)
	rr.fs.file(`C:\C\plain\f`, 1)
	doc := tstFolderDoc(t, rr, `C:\C`)
	d := tstEntryByName(t, doc, "D")
	if n, ok := tstNum(d["size"]); !ok || n != 100 {
		t.Errorf("D.size = %v, want 100", d["size"])
	}
	if n, ok := tstNum(d["online_size"]); !ok || n != tstGiB {
		t.Errorf("D.online_size = %v, want %d", d["online_size"], tstGiB)
	}
	if d["cloud"] != true {
		t.Errorf("D.cloud = %v, want true", d["cloud"])
	}
	if p := tstEntryByName(t, doc, "plain"); p["cloud"] != false {
		t.Errorf("plain.cloud = %v, want false", p["cloud"])
	}
	if n, ok := tstNum(doc["total_online_size"]); !ok || n != tstGiB {
		t.Errorf("total_online_size = %v, want %d", doc["total_online_size"], tstGiB)
	}
	if n, ok := tstNum(doc["total_size"]); !ok || n != 101 {
		t.Errorf("total_size = %v, want 101", doc["total_size"])
	}
	if files := tstArr(t, doc, "large_files"); len(files) != 0 {
		t.Errorf("large_files = %v, want the online file absent", files)
	}
}

func TestJSONKeepsLongNamesAndPathsUnshortened(t *testing.T) {
	rr := newDataRig()
	long := strings.Repeat("n", 150)
	rr.fs.file(`C:\Long\`+long+`\f`, 1)
	doc := tstFolderDoc(t, rr, `C:\Long`)
	e := tstEntryByName(t, doc, long)
	if e["path"] != `C:\Long\`+long {
		t.Errorf("path = %v, want it unshortened", e["path"])
	}
}

func TestJSONModeWritesNothingAndRecyclesNothing(t *testing.T) {
	rr := newDataRig()
	env, root := tstQuietEnv(t)
	delete(env, "SWEEPR_NO_OPLOG")
	for _, args := range [][]string{{"--json", `C:\Data`}, {"--json"}, {`C:\Data`}} {
		if res := rr.run(t, args, env, false); res.code != 0 {
			t.Errorf("%q: exit %d, stderr %q", args, res.code, res.stderr)
		}
	}
	tstAssertNothingWritten(t, root)
	if calls := rr.rec.recorded(); len(calls) != 0 {
		t.Errorf("the recycler was called: %q", calls)
	}
}

func TestJSONOutputGoesToStdoutOnlyAndStderrStaysQuiet(t *testing.T) {
	rr := newDataRig()
	rr.fs.failDir(`C:\Data\gamma`, errTstAccess)
	env, _ := tstQuietEnv(t)
	res := rr.run(t, []string{"--json", `C:\Data`}, env, false)
	if res.code != 0 {
		t.Fatalf("exit %d", res.code)
	}
	tstDecode(t, res.stdout)
	if res.stderr != "" {
		t.Errorf("stderr = %q, want empty even for a partial measurement", res.stderr)
	}
}

// ---------------------------------------------------------------------------
// Overview

func tstOverviewRig() *tstRunRig {
	rr := newDataRig()
	rr.fs.file(`C:\Users\Example\Downloads\f.bin`, 1000)
	rr.fs.drives = []Drive{
		{Root: `D:\`, Label: "Data", Total: 500 * tstGiB, Free: 100 * tstGiB},
		{Root: `C:\`, Label: "System", Total: 100 * tstGiB, Free: 60 * tstGiB},
	}
	return rr
}

func tstEntryPaths(t *testing.T, doc map[string]any) []string {
	t.Helper()
	var out []string
	for _, e := range tstArr(t, doc, "entries") {
		out = append(out, e.(map[string]any)["path"].(string))
	}
	return out
}

func TestJSONOverviewHasItsOwnKeysAndOmitsTheTotals(t *testing.T) {
	rr := tstOverviewRig()
	env, _ := tstQuietEnv(t)
	doc, _ := tstJSONRun(t, rr, env)
	if doc["overview"] != true || doc["path"] != "" {
		t.Errorf("overview %v, path %v, want true and an empty string", doc["overview"], doc["path"])
	}
	for _, k := range []string{"scan_status", "path", "overview", "entries"} {
		if _, ok := doc[k]; !ok {
			t.Errorf("key %q is missing", k)
		}
	}
	for _, k := range []string{"large_files", "total_size", "total_online_size", "total_files"} {
		if _, ok := doc[k]; ok {
			t.Errorf("key %q must be absent from the overview", k)
		}
	}
	for _, e := range tstArr(t, doc, "entries") {
		m := e.(map[string]any)
		for _, k := range tstEntryKeys {
			if _, ok := m[k]; !ok {
				t.Errorf("entry %v: key %q is missing", m["path"], k)
			}
		}
	}
}

func TestJSONOverviewListsHomeThenTheFixedDrivesInLetterOrder(t *testing.T) {
	rr := tstOverviewRig()
	env, _ := tstQuietEnv(t)
	doc, _ := tstJSONRun(t, rr, env)
	want := []string{`C:\Users\Example`, `C:\`, `D:\`}
	if got := tstEntryPaths(t, doc); !tstSameStrings(got, want) {
		t.Errorf("entries = %v, want %v", got, want)
	}
}

func TestJSONOverviewDriveSizeIsTheOccupiedSpaceOfTheVolume(t *testing.T) {
	rr := tstOverviewRig()
	env, _ := tstQuietEnv(t)
	doc, _ := tstJSONRun(t, rr, env)
	var c map[string]any
	for _, e := range tstArr(t, doc, "entries") {
		if m := e.(map[string]any); m["path"] == `C:\` {
			c = m
		}
	}
	if c == nil {
		t.Fatal("no entry for C:\\")
	}
	if n, ok := tstNum(c["size"]); !ok || n != 40*tstGiB {
		t.Errorf("C:\\ size = %v, want %d (total minus free)", c["size"], 40*tstGiB)
	}
	if n, ok := tstNum(c["online_size"]); !ok || n != 0 {
		t.Errorf("C:\\ online_size = %v, want 0", c["online_size"])
	}
	if c["cloud"] != false || c["is_link"] != false || c["scan_status"] != "complete" {
		t.Errorf("C:\\ = %v", c)
	}
}

func TestJSONOverviewMeasuresHomeLikeAFolder(t *testing.T) {
	rr := tstOverviewRig()
	rr.fs.cloudFile(`C:\Users\Example\OneDrive\big.bin`, tstGiB, true)
	env, _ := tstQuietEnv(t)
	doc, _ := tstJSONRun(t, rr, env)
	home := tstArr(t, doc, "entries")[0].(map[string]any)
	if home["path"] != `C:\Users\Example` {
		t.Fatalf("first entry = %v, want Home", home["path"])
	}
	if n, ok := tstNum(home["size"]); !ok || n != 1000 {
		t.Errorf("Home size = %v, want 1000 (local bytes only)", home["size"])
	}
	if n, ok := tstNum(home["online_size"]); !ok || n != tstGiB {
		t.Errorf("Home online_size = %v, want %d", home["online_size"], tstGiB)
	}
	if home["cloud"] != true {
		t.Errorf("Home cloud = %v, want true", home["cloud"])
	}
}

func TestJSONOverviewReadsNoDriveTree(t *testing.T) {
	rr := tstOverviewRig()
	env, _ := tstQuietEnv(t)
	tstJSONRun(t, rr, env)
	if n := rr.fs.readCount(`C:\`) + rr.fs.readCount(`D:\`); n != 0 {
		t.Errorf("the drive roots were read %d times, want the volume sizes without a walk", n)
	}
}

func TestJSONOverviewDriveThatCannotBeReadIsNotMeasured(t *testing.T) {
	rr := tstOverviewRig()
	rr.fs.drives[0].Err = errTstBoom
	env, _ := tstQuietEnv(t)
	doc, _ := tstJSONRun(t, rr, env)
	var d map[string]any
	for _, e := range tstArr(t, doc, "entries") {
		if m := e.(map[string]any); m["path"] == `D:\` {
			d = m
		}
	}
	if d == nil {
		t.Fatal("no entry for D:\\")
	}
	if d["size"] != nil || d["online_size"] != nil || d["scan_status"] != "unavailable" {
		t.Errorf("D:\\ = %v, want size null, online_size null, unavailable", d)
	}
	if doc["scan_status"] != "partial" {
		t.Errorf("scan_status = %v, want partial", doc["scan_status"])
	}
}

func TestJSONOverviewOmitsHomeThatIsNoFolder(t *testing.T) {
	rr := tstOverviewRig()
	env, _ := tstQuietEnv(t)
	env["USERPROFILE"] = `C:\Users\Nobody`
	doc, _ := tstJSONRun(t, rr, env)
	if got := tstEntryPaths(t, doc); !tstSameStrings(got, []string{`C:\`, `D:\`}) {
		t.Errorf("entries = %v, want only the drives", got)
	}
}

func TestJSONOverviewHomeFallsBackToTheHomeFolderOfTheRuntime(t *testing.T) {
	home := `D:\Profiles\Fallback`
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	rr := tstOverviewRig()
	rr.fs.file(home+`\f`, 7)
	env, _ := tstQuietEnv(t)
	env["USERPROFILE"] = ""
	doc, _ := tstJSONRun(t, rr, env)
	if got := tstEntryPaths(t, doc); len(got) == 0 || got[0] != home {
		t.Errorf("entries = %v, want Home %s first", got, home)
	}
}

func TestJSONOverviewHomeThatCannotBeReadIsUnavailable(t *testing.T) {
	rr := tstOverviewRig()
	rr.fs.failDir(`C:\Users\Example`, errTstAccess)
	env, _ := tstQuietEnv(t)
	doc, _ := tstJSONRun(t, rr, env)
	home := tstArr(t, doc, "entries")[0].(map[string]any)
	if home["scan_status"] != "unavailable" || home["size"] != nil {
		t.Errorf("Home = %v, want unavailable with size null", home)
	}
}

func TestJSONOverviewWritesNothing(t *testing.T) {
	rr := tstOverviewRig()
	env, root := tstQuietEnv(t)
	delete(env, "SWEEPR_NO_OPLOG")
	tstJSONRun(t, rr, env)
	tstAssertNothingWritten(t, root)
	if calls := rr.rec.recorded(); len(calls) != 0 {
		t.Errorf("the recycler was called: %q", calls)
	}
}

func TestJSONOverviewIsOneDocumentWithoutControlCharacters(t *testing.T) {
	rr := tstOverviewRig()
	env, _ := tstQuietEnv(t)
	_, res := tstJSONRun(t, rr, env)
	if bytes.ContainsRune([]byte(res.stdout), 0x1b) || strings.HasPrefix(res.stdout, "\xef\xbb\xbf") {
		t.Errorf("stdout has an escape character or a byte-order mark")
	}
}
