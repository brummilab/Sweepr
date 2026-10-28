package main

// The settings file (ST-22): location, format, locking, atomic replacement and
// silent failure.

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

func tstDirNames(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read %s: %v", dir, err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names
}

func tstMustNotExist(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); err == nil {
		t.Errorf("%s exists, but nothing may be created there", path)
	}
}

// ---------------------------------------------------------------------------
// Location

func TestPrefsLiveUnderTheDataFolderWhenSet(t *testing.T) {
	e := tstIsolated(t)
	p := tstOpenPrefs(e.env)
	p.Set("cpu_cores", "4")
	if got := e.readPrefs(t); got != "cpu_cores=4\n" {
		t.Errorf("file = %q, want %q", got, "cpu_cores=4\n")
	}
	tstMustNotExist(t, e.home)
	if names := tstDirNames(t, filepath.Dir(e.prefsFile())); !tstSameStrings(names, []string{"status_prefs", "status_prefs.lock"}) {
		t.Errorf("settings folder holds %q, want the file and its lock file only (no temporary leftovers)", names)
	}
	if fi, err := os.Stat(e.prefsFile() + ".lock"); err != nil || fi.Size() != 0 {
		t.Errorf("lock file: %v, size must be 0", err)
	}
}

func TestPrefsTrimSpacesAroundTheDataFolder(t *testing.T) {
	e := tstIsolated(t)
	p := tstOpenPrefs(e.with("SWEEPR_DATA_DIR", "  "+e.data+" \t").env)
	p.Set("cpu_cores", "8")
	if got := e.readPrefs(t); got != "cpu_cores=8\n" {
		t.Errorf("file = %q", got)
	}
	tstMustNotExist(t, e.home)
}

func TestPrefsFallBackToTheProfileWhenTheDataFolderIsEmpty(t *testing.T) {
	for _, value := range []string{"", "   ", "\t"} {
		e := tstIsolated(t)
		p := tstOpenPrefs(e.with("SWEEPR_DATA_DIR", value).env)
		p.Set("cpu_cores", "4")
		profile := filepath.Join(e.home, ".config", "sweepr", "status_prefs")
		b, err := os.ReadFile(profile)
		if err != nil {
			t.Errorf("SWEEPR_DATA_DIR=%q: no file in the profile: %v", value, err)
			continue
		}
		if string(b) != "cpu_cores=4\n" {
			t.Errorf("SWEEPR_DATA_DIR=%q: profile file = %q", value, b)
		}
		tstMustNotExist(t, e.data)
	}
}

func TestPrefsFallBackToTheProfileWhenTheDataFolderIsAbsent(t *testing.T) {
	e := tstIsolated(t)
	env := map[string]string{"USERPROFILE": e.home, "HOME": e.home}
	tstOpenPrefs(env).Set("cpu_cores", "2")
	if _, err := os.Stat(filepath.Join(e.home, ".config", "sweepr", "status_prefs")); err != nil {
		t.Errorf("no file in the profile: %v", err)
	}
}

func TestPrefsDoNothingWithoutAnyFolder(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)
	t.Setenv("HOME", "")
	t.Setenv("USERPROFILE", "")
	p := tstOpenPrefs(map[string]string{})
	p.Set("cpu_cores", "4")
	if v, ok := p.Get("cpu_cores"); ok && v != "4" {
		t.Errorf("Get = %q, %v", v, ok)
	}
	if names := tstDirNames(t, root); len(names) != 0 {
		t.Errorf("files were created without a folder to put them in: %v", names)
	}
}

// ---------------------------------------------------------------------------
// Reading

func TestPrefsReadOfAMissingFileGivesDefaultsAndCreatesNothing(t *testing.T) {
	e := tstIsolated(t)
	p := tstOpenPrefs(e.env)
	if v, ok := p.Get("cpu_cores"); ok {
		t.Errorf("Get on a missing file = %q, true", v)
	}
	e.assertUntouched(t)
}

func TestPrefsReadFormat(t *testing.T) {
	content := "# comment\r\n" +
		"\r\n" +
		"  cpu_cores = 4  \r\n" +
		"no equals sign here\n" +
		"#hidden=1\n" +
		"cat_hidden=1\n" +
		"formula=a=b=c\n" +
		"last=value"
	e := tstIsolated(t)
	e.writePrefs(t, content)
	p := tstOpenPrefs(e.env)
	want := map[string]string{"cpu_cores": "4", "cat_hidden": "1", "formula": "a=b=c", "last": "value"}
	for k, v := range want {
		if got, ok := p.Get(k); !ok || got != v {
			t.Errorf("Get(%q) = %q, %v; want %q", k, got, ok, v)
		}
	}
	for _, k := range []string{"hidden", "#hidden", "no equals sign here", "comment", "missing"} {
		if got, ok := p.Get(k); ok {
			t.Errorf("Get(%q) = %q, true; want no value", k, got)
		}
	}
}

func TestPrefsReadOfAnUnreadableFileGivesDefaults(t *testing.T) {
	e := tstIsolated(t)
	if err := os.MkdirAll(e.prefsFile(), 0o755); err != nil { // a folder where the file should be
		t.Fatal(err)
	}
	p := tstOpenPrefs(e.env)
	if v, ok := p.Get("cpu_cores"); ok {
		t.Errorf("Get = %q, true", v)
	}
}

// ---------------------------------------------------------------------------
// Writing

func TestPrefsSetKeepsAllOtherKeysSortedAndDropsEverythingElse(t *testing.T) {
	e := tstIsolated(t)
	e.writePrefs(t, "# note\r\nzeta = 9 \r\n\r\nnoequals\ncpu_cores=4\nx=1\ncat_hidden=1\nformula=a=b\n")
	p := tstOpenPrefs(e.env)
	p.Set("cpu_cores", "8")
	want := "cat_hidden=1\ncpu_cores=8\nformula=a=b\nx=1\nzeta=9\n"
	if got := e.readPrefs(t); got != want {
		t.Errorf("file =\n%q\nwant\n%q", got, want)
	}
}

func TestPrefsSetExampleKeepsTheOrderOfTheFile(t *testing.T) {
	e := tstIsolated(t)
	e.writePrefs(t, "cpu_cores=4\nx=1\n")
	tstOpenPrefs(e.env).Set("cpu_cores", "8")
	if got := e.readPrefs(t); got != "cpu_cores=8\nx=1\n" {
		t.Errorf("file = %q", got)
	}
}

func TestPrefsSetWritesPlainUTF8WithLineFeeds(t *testing.T) {
	e := tstIsolated(t)
	e.writePrefs(t, "a=1\r\nb=2\r\n")
	tstOpenPrefs(e.env).Set("c", "ä€")
	got := e.readPrefs(t)
	if strings.HasPrefix(got, "\xef\xbb\xbf") || strings.Contains(got, "\r") {
		t.Errorf("file has a byte-order mark or carriage returns: %q", got)
	}
	if got != "a=1\nb=2\nc=ä€\n" {
		t.Errorf("file = %q", got)
	}
}

func TestPrefsGetReturnsWhatSetStored(t *testing.T) {
	e := tstIsolated(t)
	p := tstOpenPrefs(e.env)
	p.Set("cpu_cores", "4")
	if v, ok := p.Get("cpu_cores"); !ok || v != "4" {
		t.Errorf("Get = %q, %v; want 4", v, ok)
	}
	p.Set("cpu_cores", "8")
	if v, ok := p.Get("cpu_cores"); !ok || v != "8" {
		t.Errorf("Get = %q, %v; want 8", v, ok)
	}
	if v, ok := tstOpenPrefs(e.env).Get("cpu_cores"); !ok || v != "8" {
		t.Errorf("a new store reads %q, %v; want 8", v, ok)
	}
}

func TestPrefsSetReadsTheFileAfterTakingTheLock(t *testing.T) {
	e := tstIsolated(t)
	a := tstOpenPrefs(e.env) // opened before the other writer saves
	b := tstOpenPrefs(e.env)
	b.Set("from_b", "1")
	a.Set("from_a", "1")
	if got := e.readPrefs(t); got != "from_a=1\nfrom_b=1\n" {
		t.Errorf("file = %q; a key saved by another instance was lost", got)
	}
}

// ---------------------------------------------------------------------------
// Failure is silent

func TestPrefsSetIgnoresFailures(t *testing.T) {
	cases := map[string]func(t *testing.T, e tstEnv){
		"data folder is a file": func(t *testing.T, e tstEnv) {
			if err := os.WriteFile(e.data, []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
		},
		"config folder is a file": func(t *testing.T, e tstEnv) {
			if err := os.MkdirAll(e.data, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(e.data, "config"), []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
		},
		"lock file is a folder": func(t *testing.T, e tstEnv) {
			if err := os.MkdirAll(e.prefsFile()+".lock", 0o755); err != nil {
				t.Fatal(err)
			}
		},
		"settings file is a folder": func(t *testing.T, e tstEnv) {
			if err := os.MkdirAll(e.prefsFile(), 0o755); err != nil {
				t.Fatal(err)
			}
		},
	}
	for name, setup := range cases {
		setup := setup
		t.Run(name, func(t *testing.T) {
			e := tstIsolated(t)
			setup(t, e)
			p := tstOpenPrefs(e.env)
			done := make(chan struct{})
			go func() {
				defer close(done)
				defer func() {
					if r := recover(); r != nil {
						t.Errorf("Set panicked: %v", r)
					}
				}()
				p.Set("cpu_cores", "4")
			}()
			select {
			case <-done:
			case <-time.After(10 * time.Second):
				t.Fatal("Set did not return")
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Two writers

func tstAssertCompleteKeys(t *testing.T, e tstEnv, prefixes []string, count int) {
	t.Helper()
	b, err := os.ReadFile(e.prefsFile())
	if err != nil {
		t.Fatalf("settings file: %v", err)
	}
	got := map[string]string{}
	var order []string
	for _, line := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			t.Fatalf("line %q is not key=value", line)
		}
		got[k] = v
		order = append(order, k)
	}
	if !sort.StringsAreSorted(order) {
		t.Errorf("keys are not sorted: %q", order)
	}
	for _, prefix := range prefixes {
		for i := 0; i < count; i++ {
			k := fmt.Sprintf("%s%02d", prefix, i)
			if got[k] != fmt.Sprint(i) {
				t.Errorf("key %s = %q, want %d: an update was lost", k, got[k], i)
			}
		}
	}
	if len(got) != len(prefixes)*count {
		t.Errorf("file has %d keys, want %d", len(got), len(prefixes)*count)
	}
}

func TestPrefsTwoStoresInOneProcessLoseNoKey(t *testing.T) {
	e := tstIsolated(t)
	const count = 25
	var wg sync.WaitGroup
	for _, prefix := range []string{"a", "b"} {
		wg.Add(1)
		go func(prefix string) {
			defer wg.Done()
			p := tstOpenPrefs(e.env)
			for i := 0; i < count; i++ {
				p.Set(fmt.Sprintf("%s%02d", prefix, i), fmt.Sprint(i))
			}
		}(prefix)
	}
	wg.Wait()
	tstAssertCompleteKeys(t, e, []string{"a", "b"}, count)
}

func TestPrefsTwoProcessesSavingDifferentKeysLoseNone(t *testing.T) {
	e := tstIsolated(t)
	const count = 30
	prefixes := []string{"a", "b"}
	var cmds []*exec.Cmd
	for _, prefix := range prefixes {
		cmd := exec.Command(os.Args[0])
		cmd.Env = append(os.Environ(),
			tstModeEnv+"=prefs",
			"SWEEPR_STATUS_TEST_DATA="+e.data,
			"SWEEPR_STATUS_TEST_PREFIX="+prefix,
			fmt.Sprintf("SWEEPR_STATUS_TEST_COUNT=%d", count),
		)
		if err := cmd.Start(); err != nil {
			t.Fatalf("start child: %v", err)
		}
		cmds = append(cmds, cmd)
	}

	// While the children save, every state of the file seen by a reader is complete.
	stop := make(chan struct{})
	var readerErr string
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			b, err := os.ReadFile(e.prefsFile())
			if err != nil {
				time.Sleep(200 * time.Microsecond) // not there yet, or briefly held during replacement
				continue
			}
			s := string(b)
			if s == "" || !strings.HasSuffix(s, "\n") {
				readerErr = fmt.Sprintf("a reader saw an incomplete file: %q", s)
				return
			}
			var keys []string
			for _, line := range strings.Split(strings.TrimSuffix(s, "\n"), "\n") {
				k, _, ok := strings.Cut(line, "=")
				if !ok {
					readerErr = fmt.Sprintf("a reader saw a broken line %q", line)
					return
				}
				keys = append(keys, k)
			}
			if !sort.StringsAreSorted(keys) {
				readerErr = fmt.Sprintf("a reader saw unsorted keys %q", keys)
				return
			}
		}
	}()
	for i, cmd := range cmds {
		if err := cmd.Wait(); err != nil {
			t.Errorf("child %d: %v", i, err)
		}
	}
	close(stop)
	wg.Wait()
	if readerErr != "" {
		t.Error(readerErr)
	}
	tstAssertCompleteKeys(t, e, prefixes, count)
}
