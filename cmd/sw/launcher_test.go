package main

// Tests for the native launcher (behaviour rules V-1 to V-15).
//
// Two layers:
//   - psLiteral / psCommandText (test seams decided in L7) are checked as pure
//     functions on every platform.
//   - The built launcher is run as a black box. %SystemRoot% points at a
//     temporary folder that holds a fake powershell.exe (a tiny Go program built
//     by the tests), which records its arguments, working folder and selected
//     environment variables and exits with a chosen code.
//
// Tests that need a real PowerShell run only when SWEEPR_TEST_PWSH names one
// (L7-9); otherwise they are skipped, not failed.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

// The five characters that end a single-quoted PowerShell literal (V-7).
const launcherQuoteChars = "'\u2018\u2019\u201A\u201B"

// V-9 mandatory hostile values.
var launcherHostileCases = []string{
	"it's",
	"a\u2018b",
	"Rock\u2019n\u2019Roll",
	"a\u201Ab",
	"a\u201Bb",
	"'\u2018\u2019\u201A\u201B",
	"\u2019x\u2019",
	"a b  c",
	"a;b",
	"$env:PATH $(Get-Date) ${x}",
	"a`b`n`$x",
	`say "hi" ""`,
	`C:\Music\`,
	`C:\Music\"`,
	"x\u2019; New-Item marker; \u2019",
	"x'; New-Item marker; '",
	"x\u2018; New-Item marker; \u2018",
	"x\u201A; New-Item marker; \u201A",
	"x\u201B; New-Item marker; \u201B",
	"\u2019$(New-Item marker)\u2019",
	"O\u2019Neil's \u2018x\u201A \u201By; $z `w\\ \"q\" \\",
}

// Extra values that must arrive unchanged: empty, option-like, non-ASCII.
var launcherEdgeCases = []string{
	"",
	"-h",
	"--version",
	"--debug",
	"Gr\u00fc\u00dfe \u65e5\u672c \U0001F600",
	"line1\nline2",
}

// V-10 program folder names.
var launcherHostileFolders = []string{
	"D\u2019Angelo",
	"D\u2018Angelo",
	"D\u201AAngelo",
	"D\u201BAngelo",
	"O'Neil",
	"x\u2019; New-Item marker; \u2019",
}

const launcherCommandTail = "; exit $LASTEXITCODE"

// ---------------------------------------------------------------------------
// Test-side decoder: an independent reading of a single-quoted literal as the
// spec describes it (V-6, V-7). A quote character inside the literal must be
// doubled with itself; an unpaired U+0027 closes it; any other unpaired quote
// character would close it in PowerShell and is reported as an error.

func launcherIsQuote(r rune) bool { return strings.ContainsRune(launcherQuoteChars, r) }

func launcherDecodeLiteral(s string) (value, rest string, err error) {
	if !strings.HasPrefix(s, "'") {
		return "", s, fmt.Errorf("literal does not start with U+0027: %q", s)
	}
	var b strings.Builder
	i := 1
	for i < len(s) {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size <= 1 {
			return "", s, fmt.Errorf("invalid UTF-8 at %d in %q", i, s)
		}
		if !launcherIsQuote(r) {
			b.WriteRune(r)
			i += size
			continue
		}
		next, nsize := utf8.DecodeRuneInString(s[i+size:])
		if i+size < len(s) && next == r {
			b.WriteRune(r)
			i += size + nsize
			continue
		}
		if r == '\'' {
			return b.String(), s[i+size:], nil
		}
		return "", s, fmt.Errorf("unpaired %U at %d would end the literal early in %q", r, i, s)
	}
	return "", s, fmt.Errorf("literal is not closed: %q", s)
}

// launcherParseCommandText splits "& <lit>( <lit>)*; exit $LASTEXITCODE".
func launcherParseCommandText(text string) (script string, args []string, err error) {
	if !strings.HasPrefix(text, "& ") {
		return "", nil, fmt.Errorf("command text does not start with the call operator: %q", text)
	}
	rest := text[2:]
	script, rest, err = launcherDecodeLiteral(rest)
	if err != nil {
		return "", nil, err
	}
	args = []string{}
	for rest != launcherCommandTail {
		if !strings.HasPrefix(rest, " ") {
			return "", nil, fmt.Errorf("expected a single space before the next literal, got %q", rest)
		}
		var v string
		v, rest, err = launcherDecodeLiteral(rest[1:])
		if err != nil {
			return "", nil, err
		}
		args = append(args, v)
	}
	return script, args, nil
}

func launcherEqualArgs(a, b []string) bool {
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

// ---------------------------------------------------------------------------
// psLiteral (V-6 to V-8)

func TestPsLiteralSpecExamples(t *testing.T) {
	cases := []struct{ in, want string }{
		{"it's", "'it''s'"},
		{"Rock\u2019n", "'Rock\u2019\u2019n'"},
		{"\u2018", "'\u2018\u2018'"},
		{"\u2019", "'\u2019\u2019'"},
		{"\u201A", "'\u201A\u201A'"},
		{"\u201B", "'\u201B\u201B'"},
		{"'", "''''"},
		{"a b;$c`d", "'a b;$c`d'"},
		{`C:\Music\`, `'C:\Music\'`},
		{`say "hi"`, `'say "hi"'`},
		{"", "''"},
		{"--version", "'--version'"},
		{"Gr\u00fc\u00dfe \u65e5\u672c \U0001F600", "'Gr\u00fc\u00dfe \u65e5\u672c \U0001F600'"},
		{"line1\nline2", "'line1\nline2'"},
	}
	for _, c := range cases {
		if got := psLiteral(c.in); got != c.want {
			t.Errorf("psLiteral(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestPsLiteralDoublesEachQuoteCharacterWithItself(t *testing.T) {
	for _, q := range launcherQuoteChars {
		in := "a" + string(q) + "b"
		want := "'a" + string(q) + string(q) + "b'"
		got := psLiteral(in)
		if got != want {
			t.Errorf("psLiteral(%q) = %q, want %q", in, got, want)
		}
		if q != '\'' && strings.Contains(got, string(q)+"'b") {
			t.Errorf("psLiteral(%q) = %q doubles %U with an ASCII apostrophe", in, got, q)
		}
	}
}

func TestPsLiteralUsesAsciiApostrophesAsDelimiters(t *testing.T) {
	for _, v := range append(append([]string{}, launcherHostileCases...), launcherEdgeCases...) {
		got := psLiteral(v)
		if len(got) < 2 || got[0] != '\'' || got[len(got)-1] != '\'' {
			t.Errorf("psLiteral(%q) = %q is not delimited by U+0027", v, got)
		}
	}
}

func TestPsLiteralChangesNothingButQuoteDoubling(t *testing.T) {
	for _, v := range append(append([]string{}, launcherHostileCases...), launcherEdgeCases...) {
		got := psLiteral(v)
		quotes := 0
		for _, r := range v {
			if launcherIsQuote(r) {
				quotes++
			}
		}
		if utf8.RuneCountInString(got) != utf8.RuneCountInString(v)+quotes+2 {
			t.Errorf("psLiteral(%q) = %q adds or removes characters beyond doubling %d quote(s)", v, got, quotes)
		}
	}
}

func TestPsLiteralRoundTripsHostileCases(t *testing.T) {
	for _, v := range append(append([]string{}, launcherHostileCases...), launcherEdgeCases...) {
		lit := psLiteral(v)
		got, rest, err := launcherDecodeLiteral(lit)
		if err != nil {
			t.Errorf("psLiteral(%q) = %q is not a well-formed literal: %v", v, lit, err)
			continue
		}
		if rest != "" {
			t.Errorf("psLiteral(%q) = %q ends early; trailing text %q would be code", v, lit, rest)
		}
		if got != v {
			t.Errorf("psLiteral(%q) decodes to %q", v, got)
		}
	}
}

func TestPsLiteralRoundTripsGeneratedValues(t *testing.T) {
	alphabet := []rune("ab $;`\"\\(){}-#\n\t'\u2018\u2019\u201A\u201B\u201C\u201D\u00e4\U0001F600")
	rng := rand.New(rand.NewSource(20261027))
	for n := 0; n < 3000; n++ {
		runes := make([]rune, rng.Intn(14))
		for i := range runes {
			runes[i] = alphabet[rng.Intn(len(alphabet))]
		}
		v := string(runes)
		lit := psLiteral(v)
		got, rest, err := launcherDecodeLiteral(lit)
		if err != nil || rest != "" || got != v {
			t.Fatalf("psLiteral(%q) = %q: decoded %q, rest %q, err %v", v, lit, got, rest, err)
		}
	}
}

// ---------------------------------------------------------------------------
// psCommandText (section 2.2, V-9, V-10)

func TestPsCommandTextSpecExample(t *testing.T) {
	got := psCommandText(`C:\Program Files\Sweepr\sweepr.ps1`,
		[]string{"clean", "--dry-run", "it's", "$env:USERPROFILE", "a b"})
	want := `& 'C:\Program Files\Sweepr\sweepr.ps1' 'clean' '--dry-run' 'it''s' '$env:USERPROFILE' 'a b'; exit $LASTEXITCODE`
	if got != want {
		t.Errorf("psCommandText =\n  %q\nwant\n  %q", got, want)
	}
}

func TestPsCommandTextWithoutArgumentsOpensMenuForm(t *testing.T) {
	want := `& 'C:\Sweepr\sweepr.ps1'; exit $LASTEXITCODE`
	if got := psCommandText(`C:\Sweepr\sweepr.ps1`, nil); got != want {
		t.Errorf("psCommandText(nil) = %q, want %q", got, want)
	}
	if got := psCommandText(`C:\Sweepr\sweepr.ps1`, []string{}); got != want {
		t.Errorf("psCommandText(empty) = %q, want %q", got, want)
	}
}

func TestPsCommandTextHostileScriptPathExample(t *testing.T) {
	got := psCommandText("C:\\Users\\D\u2019Angelo\\sweepr.ps1", []string{"D:\\Musik\\Guns N\u2019 Roses"})
	want := "& 'C:\\Users\\D\u2019\u2019Angelo\\sweepr.ps1' 'D:\\Musik\\Guns N\u2019\u2019 Roses'; exit $LASTEXITCODE"
	if got != want {
		t.Errorf("psCommandText =\n  %q\nwant\n  %q", got, want)
	}
}

func TestPsCommandTextKeepsEmptyArgument(t *testing.T) {
	got := psCommandText(`C:\S\sweepr.ps1`, []string{"a", "", "b"})
	want := `& 'C:\S\sweepr.ps1' 'a' '' 'b'; exit $LASTEXITCODE`
	if got != want {
		t.Errorf("psCommandText = %q, want %q", got, want)
	}
}

func TestPsCommandTextQuotesEachArgumentSeparately(t *testing.T) {
	script := `C:\Program Files\Sweepr\sweepr.ps1`
	for _, v := range append(append([]string{}, launcherHostileCases...), launcherEdgeCases...) {
		args := []string{"first", v}
		text := psCommandText(script, args)
		want := "& " + psLiteral(script) + " " + psLiteral("first") + " " + psLiteral(v) + launcherCommandTail
		if text != want {
			t.Errorf("psCommandText(%q) = %q, want %q", args, text, want)
		}
		gotScript, gotArgs, err := launcherParseCommandText(text)
		if err != nil {
			t.Errorf("psCommandText(%q) = %q does not parse: %v", args, text, err)
			continue
		}
		if gotScript != script || !launcherEqualArgs(gotArgs, args) {
			t.Errorf("psCommandText(%q) parses to script %q args %q", args, gotScript, gotArgs)
		}
	}
}

func TestPsCommandTextHostileScriptFolders(t *testing.T) {
	for _, folder := range launcherHostileFolders {
		script := `C:\Users\` + folder + `\sweepr.ps1`
		args := []string{"first", "x\u2019; New-Item marker; \u2019"}
		text := psCommandText(script, args)
		gotScript, gotArgs, err := launcherParseCommandText(text)
		if err != nil {
			t.Errorf("folder %q: %q does not parse: %v", folder, text, err)
			continue
		}
		if gotScript != script || !launcherEqualArgs(gotArgs, args) {
			t.Errorf("folder %q: parses to script %q args %q", folder, gotScript, gotArgs)
		}
	}
}

func TestPsCommandTextRoundTripsGeneratedArguments(t *testing.T) {
	alphabet := []rune("ab $;&|`\"\\'\u2018\u2019\u201A\u201B -")
	rng := rand.New(rand.NewSource(27102026))
	for n := 0; n < 1000; n++ {
		args := make([]string, rng.Intn(5))
		for i := range args {
			runes := make([]rune, rng.Intn(8))
			for j := range runes {
				runes[j] = alphabet[rng.Intn(len(alphabet))]
			}
			args[i] = string(runes)
		}
		script := `C:\Users\D` + string(alphabet[rng.Intn(len(alphabet))]) + `Angelo\sweepr.ps1`
		text := psCommandText(script, args)
		gotScript, gotArgs, err := launcherParseCommandText(text)
		if err != nil || gotScript != script || !launcherEqualArgs(gotArgs, args) {
			t.Fatalf("psCommandText(%q, %q) = %q: script %q args %q err %v", script, args, text, gotScript, gotArgs, err)
		}
	}
}

// ---------------------------------------------------------------------------
// Real PowerShell, literal level (optional, SWEEPR_TEST_PWSH, L7-9)

// Prints every argument as UTF-16 code units, the PowerShell major version,
// then exits 7.
const launcherDumpScript = "foreach ($a in $args) {\r\n" +
	"    $units = foreach ($c in $a.ToCharArray()) { '{0:X4}' -f [int]$c }\r\n" +
	"    [Console]::Out.WriteLine('ARG:' + ($units -join ' '))\r\n" +
	"}\r\n" +
	"[Console]::Out.WriteLine('PSV:' + $PSVersionTable.PSVersion.Major)\r\n" +
	"exit 7\r\n"

func launcherRealPwsh(t *testing.T) string {
	t.Helper()
	p := os.Getenv("SWEEPR_TEST_PWSH")
	if p == "" {
		t.Skip("SWEEPR_TEST_PWSH not set; real PowerShell tests are optional (L7-9)")
	}
	return p
}

func launcherUnitsLine(v string) string {
	units := utf16.Encode([]rune(v))
	parts := make([]string, len(units))
	for i, u := range units {
		parts[i] = fmt.Sprintf("%04X", u)
	}
	return "ARG:" + strings.Join(parts, " ")
}

func launcherArgLines(out string) []string {
	var lines []string
	for _, l := range strings.Split(strings.ReplaceAll(out, "\r\n", "\n"), "\n") {
		if strings.HasPrefix(l, "ARG:") {
			lines = append(lines, l)
		}
	}
	return lines
}

func launcherAssertArgsArrived(t *testing.T, out string, args []string) {
	t.Helper()
	got := launcherArgLines(out)
	if len(got) != len(args) {
		t.Errorf("script saw %d arguments, want %d; output:\n%s", len(got), len(args), out)
		return
	}
	for i, a := range args {
		if got[i] != launcherUnitsLine(a) {
			t.Errorf("argument %d: script saw %q, want %q (%q)", i, got[i], launcherUnitsLine(a), a)
		}
	}
}

func launcherAssertNoMarker(t *testing.T, root string) {
	t.Helper()
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err == nil && strings.EqualFold(d.Name(), "marker") {
			t.Errorf("code from an argument or path ran: %s exists", p)
		}
		return nil
	})
}

func launcherWriteDumpScript(t *testing.T, dir string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(dir, "sweepr.ps1")
	if err := os.WriteFile(script, []byte(launcherDumpScript), 0o644); err != nil {
		t.Fatal(err)
	}
	return script
}

func launcherRunPwshText(t *testing.T, pwsh, workDir, text string) (string, int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, pwsh, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", text)
	cmd.Dir = workDir
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	code := 0
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("start %s: %v", pwsh, err)
	}
	return stdout.String() + stderr.String(), code
}

func TestPsCommandTextRealPowerShellPassesHostileArgumentsUnchanged(t *testing.T) {
	pwsh := launcherRealPwsh(t)
	for i, v := range append(append([]string{}, launcherHostileCases...), launcherEdgeCases...) {
		v := v
		t.Run(fmt.Sprintf("case%02d", i), func(t *testing.T) {
			root := t.TempDir()
			work := filepath.Join(root, "work")
			if err := os.MkdirAll(work, 0o755); err != nil {
				t.Fatal(err)
			}
			script := launcherWriteDumpScript(t, filepath.Join(root, "app"))
			args := []string{"first", v}
			out, code := launcherRunPwshText(t, pwsh, work, psCommandText(script, args))
			launcherAssertArgsArrived(t, out, args)
			if code != 7 {
				t.Errorf("exit code %d, want 7 from the script; output:\n%s", code, out)
			}
			launcherAssertNoMarker(t, root)
		})
	}
}

func TestPsCommandTextRealPowerShellHostileScriptFolders(t *testing.T) {
	pwsh := launcherRealPwsh(t)
	for i, folder := range launcherHostileFolders {
		folder := folder
		t.Run(fmt.Sprintf("folder%02d", i), func(t *testing.T) {
			root := t.TempDir()
			work := filepath.Join(root, "work")
			if err := os.MkdirAll(work, 0o755); err != nil {
				t.Fatal(err)
			}
			script := launcherWriteDumpScript(t, filepath.Join(root, folder))
			args := []string{"first", "D:\\Musik\\Guns N\u2019 Roses"}
			out, code := launcherRunPwshText(t, pwsh, work, psCommandText(script, args))
			launcherAssertArgsArrived(t, out, args)
			if code != 7 {
				t.Errorf("exit code %d, want 7; output:\n%s", code, out)
			}
			launcherAssertNoMarker(t, root)
		})
	}
}

func TestPsCommandTextRealPowerShellReturnsLastExitCode(t *testing.T) {
	pwsh := launcherRealPwsh(t)
	scripts := []struct {
		name, body string
		want       int
	}{
		{"explicit exit", "exit 2\r\n", 2},
		{"no exit", "$null = 1\r\n", 0},
		{"last native program", "& $env:SWEEPR_TEST_PWSH -NoLogo -NoProfile -Command 'exit 4'\r\n", 4},
	}
	for _, s := range scripts {
		s := s
		t.Run(s.name, func(t *testing.T) {
			root := t.TempDir()
			script := filepath.Join(root, "sweepr.ps1")
			if err := os.WriteFile(script, []byte(s.body), 0o644); err != nil {
				t.Fatal(err)
			}
			out, code := launcherRunPwshText(t, pwsh, root, psCommandText(script, nil))
			if code != s.want {
				t.Errorf("exit code %d, want %d; output:\n%s", code, s.want, out)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Black-box launcher tests: build sw.exe and a fake powershell.exe once.

var launcherBuild struct {
	dir string
	err error
}

func TestMain(m *testing.M) {
	code := m.Run()
	if launcherBuild.dir != "" {
		_ = os.RemoveAll(launcherBuild.dir)
	}
	os.Exit(code)
}

const launcherFakeSource = `package main

import (
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"strconv"
	"time"
)

func main() {
	if target := os.Getenv("FAKEPS_EXEC"); target != "" {
		cmd := exec.Command(target, os.Args[1:]...)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		err := cmd.Run()
		if ee, ok := err.(*exec.ExitError); ok {
			os.Exit(ee.ExitCode())
		}
		if err != nil {
			os.Exit(99)
		}
		os.Exit(0)
	}
	rec := map[string]interface{}{"args": os.Args[1:]}
	if wd, err := os.Getwd(); err == nil {
		rec["cwd"] = wd
	}
	env := map[string]string{}
	for _, k := range []string{"SWEEPR_DATA_DIR", "SWEEPR_DRY_RUN", "SWEEPR_DEBUG", "NO_COLOR", "PSModulePath"} {
		env[k] = os.Getenv(k)
	}
	rec["env"] = env
	if os.Getenv("FAKEPS_READ_STDIN") == "1" {
		b, _ := io.ReadAll(os.Stdin)
		rec["stdin"] = string(b)
	}
	if p := os.Getenv("FAKEPS_RECORD"); p != "" {
		b, _ := json.Marshal(rec)
		_ = os.WriteFile(p+".tmp", b, 0o644)
		_ = os.Rename(p+".tmp", p)
	}
	os.Stdout.WriteString("fake-stdout\n")
	os.Stderr.WriteString("fake-stderr\n")
	if ms, err := strconv.Atoi(os.Getenv("FAKEPS_SLEEP_MS")); err == nil {
		time.Sleep(time.Duration(ms) * time.Millisecond)
	}
	if p := os.Getenv("FAKEPS_DONE"); p != "" {
		_ = os.WriteFile(p, []byte("done"), 0o644)
	}
	code, _ := strconv.Atoi(os.Getenv("FAKEPS_EXIT"))
	os.Exit(code)
}
`

func launcherGoTool() string {
	if p, err := exec.LookPath("go"); err == nil {
		return p
	}
	exe := "go"
	if runtime.GOOS == "windows" {
		exe = "go.exe"
	}
	return filepath.Join(runtime.GOROOT(), "bin", exe)
}

func launcherBuildBinaries() (string, error) {
	dir, err := os.MkdirTemp("", "sweepr-launcher-test-")
	if err != nil {
		return "", err
	}
	goTool := launcherGoTool()
	build := exec.Command(goTool, "build", "-o", filepath.Join(dir, "sw.exe"), ".")
	if out, err := build.CombinedOutput(); err != nil {
		return dir, fmt.Errorf("build launcher: %v\n%s", err, out)
	}
	fakeDir := filepath.Join(dir, "fakeps")
	if err := os.MkdirAll(fakeDir, 0o755); err != nil {
		return dir, err
	}
	if err := os.WriteFile(filepath.Join(fakeDir, "main.go"), []byte(launcherFakeSource), 0o644); err != nil {
		return dir, err
	}
	fake := exec.Command(goTool, "build", "-o", filepath.Join(dir, "fakeps.exe"), "main.go")
	fake.Dir = fakeDir
	fake.Env = append(os.Environ(), "GOFLAGS=", "GOWORK=off")
	if out, err := fake.CombinedOutput(); err != nil {
		return dir, fmt.Errorf("build fake powershell: %v\n%s", err, out)
	}
	return dir, nil
}

func launcherBinaries(t *testing.T) (launcher, fake string) {
	t.Helper()
	if launcherBuild.dir == "" && launcherBuild.err == nil {
		launcherBuild.dir, launcherBuild.err = launcherBuildBinaries()
	}
	if launcherBuild.err != nil {
		t.Fatal(launcherBuild.err)
	}
	return filepath.Join(launcherBuild.dir, "sw.exe"), filepath.Join(launcherBuild.dir, "fakeps.exe")
}

func launcherCopyExecutable(t *testing.T, src, dst string) {
	t.Helper()
	b, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, b, 0o755); err != nil {
		t.Fatal(err)
	}
}

// launcherInstall places sw.exe (and, if withScript, a sweepr.ps1) in dir.
func launcherInstall(t *testing.T, dir string, withScript bool) string {
	t.Helper()
	launcher, _ := launcherBinaries(t)
	exe := filepath.Join(dir, "sw.exe")
	launcherCopyExecutable(t, launcher, exe)
	if withScript {
		if err := os.WriteFile(filepath.Join(dir, "sweepr.ps1"), []byte("# test\r\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return exe
}

// launcherSystemRoot returns a fake %SystemRoot% whose
// System32\WindowsPowerShell\v1.0\powershell.exe is the fake PowerShell.
// Off Windows the backslash spellings are files too, so the launcher may build
// the path with filepath.Join or with literal backslashes.
func launcherSystemRoot(t *testing.T) string {
	t.Helper()
	_, fake := launcherBinaries(t)
	root := filepath.Join(t.TempDir(), "WinRoot")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	launcherCopyExecutable(t, fake, filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"))
	if runtime.GOOS != "windows" {
		launcherCopyExecutable(t, fake, root+`\System32\WindowsPowerShell\v1.0\powershell.exe`)
		launcherCopyExecutable(t, fake, filepath.Join(root, `System32\WindowsPowerShell\v1.0\powershell.exe`))
	}
	return root
}

type launcherRun struct {
	dir      string
	env      map[string]string // set; empty value means "remove"
	stdin    string
	readFrom bool
}

type launcherResult struct {
	stdout, stderr string
	code           int
}

func launcherEnv(overrides map[string]string) []string {
	var env []string
	for _, kv := range os.Environ() {
		key := kv
		if i := strings.Index(kv, "="); i > 0 {
			key = kv[:i]
		}
		drop := false
		for k := range overrides {
			if strings.EqualFold(k, key) {
				drop = true
			}
		}
		if !drop {
			env = append(env, kv)
		}
	}
	for k, v := range overrides {
		if v != "" {
			env = append(env, k+"="+v)
		}
	}
	return env
}

func launcherStart(t *testing.T, exe string, args []string, r launcherRun) (*exec.Cmd, *bytes.Buffer, *bytes.Buffer, context.CancelFunc) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	cmd := exec.CommandContext(ctx, exe, args...)
	cmd.Dir = r.dir
	cmd.Env = launcherEnv(r.env)
	cmd.Stdin = strings.NewReader(r.stdin)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Start(); err != nil {
		cancel()
		t.Fatalf("start %s: %v", exe, err)
	}
	return cmd, &stdout, &stderr, cancel
}

func launcherWait(t *testing.T, cmd *exec.Cmd, stdout, stderr *bytes.Buffer, cancel context.CancelFunc) launcherResult {
	t.Helper()
	defer cancel()
	err := cmd.Wait()
	code := 0
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("wait: %v", err)
	}
	return launcherResult{stdout: stdout.String(), stderr: stderr.String(), code: code}
}

func launcherExec(t *testing.T, exe string, args []string, r launcherRun) launcherResult {
	t.Helper()
	cmd, out, errOut, cancel := launcherStart(t, exe, args, r)
	return launcherWait(t, cmd, out, errOut, cancel)
}

type launcherRecord struct {
	Args  []string          `json:"args"`
	Cwd   string            `json:"cwd"`
	Env   map[string]string `json:"env"`
	Stdin string            `json:"stdin"`
}

func launcherReadRecord(t *testing.T, path string) launcherRecord {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("fake powershell.exe was not started (no record): %v", err)
	}
	var rec launcherRecord
	if err := json.Unmarshal(b, &rec); err != nil {
		t.Fatalf("record: %v", err)
	}
	return rec
}

func launcherAssertNotStarted(t *testing.T, record string) {
	t.Helper()
	if _, err := os.Stat(record); err == nil {
		t.Errorf("a PowerShell was started, but none should have been")
	}
}

// launcherAssertOneErrorLine checks V-3/V-14 style failures: exit 1, nothing on
// stdout, exactly one stderr line starting with the program name.
func launcherAssertOneErrorLine(t *testing.T, res launcherResult) {
	t.Helper()
	if res.code != 1 {
		t.Errorf("exit code %d, want 1", res.code)
	}
	if res.stdout != "" {
		t.Errorf("launcher wrote to stdout: %q", res.stdout)
	}
	line := strings.TrimRight(res.stderr, "\r\n")
	if line == "" || strings.ContainsAny(line, "\r\n") {
		t.Errorf("stderr must be exactly one line, got %q", res.stderr)
	}
	if !strings.HasPrefix(strings.ToLower(line), "sw") {
		t.Errorf("stderr line must start with the program name, got %q", line)
	}
}

// launcherScenario is a ready installation with fake PowerShell.
type launcherScenario struct {
	root, installDir, exe, systemRoot, work, record string
}

func newLauncherScenario(t *testing.T) launcherScenario {
	t.Helper()
	root := t.TempDir()
	s := launcherScenario{
		root:       root,
		installDir: filepath.Join(root, "Sweepr"),
		work:       filepath.Join(root, "work"),
		record:     filepath.Join(root, "record.json"),
	}
	for _, d := range []string{s.installDir, s.work} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	s.exe = launcherInstall(t, s.installDir, true)
	s.systemRoot = launcherSystemRoot(t)
	return s
}

func (s launcherScenario) run(t *testing.T, args []string, extra map[string]string) launcherResult {
	t.Helper()
	env := map[string]string{"SystemRoot": s.systemRoot, "FAKEPS_RECORD": s.record}
	for k, v := range extra {
		env[k] = v
	}
	return launcherExec(t, s.exe, args, launcherRun{dir: s.work, env: env})
}

func launcherSameFile(t *testing.T, a, b string) bool {
	t.Helper()
	ia, err := os.Stat(a)
	if err != nil {
		return false
	}
	ib, err := os.Stat(b)
	if err != nil {
		return false
	}
	return os.SameFile(ia, ib)
}

// launcherCheckCommand checks the recorded PowerShell arguments against
// section 2.2 and returns the script path from the -Command text.
func launcherCheckCommand(t *testing.T, rec launcherRecord, wantArgs []string) string {
	t.Helper()
	a := rec.Args
	if len(a) < 2 || a[len(a)-2] != "-Command" {
		t.Fatalf("PowerShell arguments must end with -Command <text>, got %q", a)
	}
	switches := a[:len(a)-2]
	for _, s := range switches {
		ls := strings.ToLower(s)
		if ls == "-noninteractive" || ls == "-file" || ls == "-command" {
			t.Errorf("forbidden switch %q in %q", s, a)
		}
	}
	want := map[string]bool{"-NoLogo": false, "-NoProfile": false}
	policy := false
	for i, s := range switches {
		if _, ok := want[s]; ok {
			want[s] = true
		}
		if s == "-ExecutionPolicy" && i+1 < len(switches) && switches[i+1] == "Bypass" {
			policy = true
		}
	}
	for k, seen := range want {
		if !seen {
			t.Errorf("switch %s missing in %q", k, a)
		}
	}
	if !policy {
		t.Errorf("-ExecutionPolicy Bypass missing in %q", a)
	}
	if len(switches) != 4 {
		t.Errorf("want exactly -NoLogo -NoProfile -ExecutionPolicy Bypass before -Command, got %q", switches)
	}
	text := a[len(a)-1]
	script, args, err := launcherParseCommandText(text)
	if err != nil {
		t.Fatalf("-Command text %q: %v", text, err)
	}
	if !launcherEqualArgs(args, wantArgs) {
		t.Errorf("-Command text carries arguments %q, want %q", args, wantArgs)
	}
	if text != psCommandText(script, wantArgs) {
		t.Errorf("-Command text %q differs from psCommandText(%q, %q) = %q", text, script, wantArgs, psCommandText(script, wantArgs))
	}
	return script
}

// ---------------------------------------------------------------------------
// Section 2.1/2.2: call form, pass-through

func TestLauncherStartsPowerShellWithCommandForm(t *testing.T) {
	s := newLauncherScenario(t)
	args := []string{"clean", "--dry-run", "it's", "$env:USERPROFILE", "a b"}
	res := s.run(t, args, nil)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	script := launcherCheckCommand(t, launcherReadRecord(t, s.record), args)
	if !launcherSameFile(t, script, filepath.Join(s.installDir, "sweepr.ps1")) {
		t.Errorf("script path %q is not the sweepr.ps1 beside sw.exe", script)
	}
}

func TestLauncherWithoutArgumentsUsesMenuForm(t *testing.T) {
	s := newLauncherScenario(t)
	res := s.run(t, nil, nil)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	rec := launcherReadRecord(t, s.record)
	launcherCheckCommand(t, rec, []string{})
	if text := rec.Args[len(rec.Args)-1]; !strings.HasSuffix(text, "sweepr.ps1'"+launcherCommandTail) {
		t.Errorf("-Command text %q should end right after the script literal", text)
	}
}

func TestLauncherHasNoOptionsOfItsOwn(t *testing.T) {
	for _, args := range [][]string{{"--help"}, {"--version"}, {"-h"}, {"--debug", "status"}, {"/?"}} {
		s := newLauncherScenario(t)
		res := s.run(t, args, nil)
		if res.code != 0 {
			t.Errorf("%q: exit code %d, stderr %q", args, res.code, res.stderr)
			continue
		}
		if res.stdout != "fake-stdout\n" {
			t.Errorf("%q: stdout %q, want only the script's output", args, res.stdout)
		}
		launcherCheckCommand(t, launcherReadRecord(t, s.record), args)
	}
}

// V-6, V-9, V-11: every argument reaches PowerShell as its own literal; the
// -Command text survives process creation as one argument.
func TestLauncherPassesHostileArgumentsAsSingleLiterals(t *testing.T) {
	for i, v := range append(append([]string{}, launcherHostileCases...), launcherEdgeCases...) {
		v := v
		t.Run(fmt.Sprintf("case%02d", i), func(t *testing.T) {
			s := newLauncherScenario(t)
			args := []string{"first", v}
			res := s.run(t, args, nil)
			if res.code != 0 {
				t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
			}
			launcherCheckCommand(t, launcherReadRecord(t, s.record), args)
			launcherAssertNoMarker(t, s.root)
		})
	}
}

func TestLauncherPassesThroughStdioUnchanged(t *testing.T) {
	s := newLauncherScenario(t)
	res := launcherExec(t, s.exe, []string{"analyze", "--json"}, launcherRun{
		dir:   s.work,
		stdin: "input-line\n",
		env: map[string]string{
			"SystemRoot":        s.systemRoot,
			"FAKEPS_RECORD":     s.record,
			"FAKEPS_READ_STDIN": "1",
		},
	})
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	if res.stdout != "fake-stdout\n" {
		t.Errorf("stdout %q, want exactly the PowerShell stdout", res.stdout)
	}
	if res.stderr != "fake-stderr\n" {
		t.Errorf("stderr %q, want exactly the PowerShell stderr", res.stderr)
	}
	if rec := launcherReadRecord(t, s.record); rec.Stdin != "input-line\n" {
		t.Errorf("PowerShell stdin %q, want %q", rec.Stdin, "input-line\n")
	}
}

func TestLauncherKeepsCallerWorkingDirectory(t *testing.T) {
	s := newLauncherScenario(t)
	res := s.run(t, []string{"status"}, nil)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	rec := launcherReadRecord(t, s.record)
	if !launcherSameFile(t, rec.Cwd, s.work) {
		t.Errorf("PowerShell ran in %q, want the caller's folder %q", rec.Cwd, s.work)
	}
}

func TestLauncherInheritsEnvironment(t *testing.T) {
	s := newLauncherScenario(t)
	want := map[string]string{
		"SWEEPR_DATA_DIR": filepath.Join(s.root, "data dir"),
		"SWEEPR_DRY_RUN":  "1",
		"SWEEPR_DEBUG":    "1",
		"NO_COLOR":        "1",
		"PSModulePath":    filepath.Join(s.root, "modules"),
	}
	res := s.run(t, []string{"clean"}, want)
	if res.code != 0 {
		t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
	}
	rec := launcherReadRecord(t, s.record)
	for k, v := range want {
		if rec.Env[k] != v {
			t.Errorf("%s = %q in PowerShell, want %q", k, rec.Env[k], v)
		}
	}
}

// ---------------------------------------------------------------------------
// V-1 to V-3: finding sweepr.ps1

func TestLauncherFindsScriptBesideLinkTarget(t *testing.T) {
	for _, decoy := range []bool{false, true} {
		decoy := decoy
		t.Run(fmt.Sprintf("decoy=%v", decoy), func(t *testing.T) {
			s := newLauncherScenario(t)
			links := filepath.Join(s.root, "WinGet", "Links")
			if err := os.MkdirAll(links, 0o755); err != nil {
				t.Fatal(err)
			}
			link := filepath.Join(links, "sw.exe")
			if err := os.Symlink(s.exe, link); err != nil {
				t.Skipf("cannot create symbolic link here: %v", err)
			}
			if decoy {
				if err := os.WriteFile(filepath.Join(links, "sweepr.ps1"), []byte("# decoy\r\n"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			res := launcherExec(t, link, []string{"status"}, launcherRun{
				dir: s.work,
				env: map[string]string{"SystemRoot": s.systemRoot, "FAKEPS_RECORD": s.record},
			})
			if res.code != 0 {
				t.Fatalf("exit code %d, stderr %q", res.code, res.stderr)
			}
			script := launcherCheckCommand(t, launcherReadRecord(t, s.record), []string{"status"})
			if !launcherSameFile(t, script, filepath.Join(s.installDir, "sweepr.ps1")) {
				t.Errorf("script %q, want the sweepr.ps1 beside the link target in %q", script, s.installDir)
			}
		})
	}
}

func TestLauncherFailsWithoutScript(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "NoScript")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	exe := launcherInstall(t, dir, false)
	record := filepath.Join(root, "record.json")
	res := launcherExec(t, exe, []string{"status"}, launcherRun{
		dir: root,
		env: map[string]string{"SystemRoot": launcherSystemRoot(t), "FAKEPS_RECORD": record},
	})
	launcherAssertOneErrorLine(t, res)
	if !strings.Contains(res.stderr, "sweepr.ps1") {
		t.Errorf("error %q does not name sweepr.ps1", res.stderr)
	}
	if !strings.Contains(res.stderr, "NoScript") {
		t.Errorf("error %q does not name the folder that was checked", res.stderr)
	}
	launcherAssertNotStarted(t, record)
}

// ---------------------------------------------------------------------------
// V-4, V-5, V-14: which PowerShell starts

func TestLauncherNeverStartsPowerShellFromPathOrWorkingDirectory(t *testing.T) {
	s := newLauncherScenario(t)
	_, fake := launcherBinaries(t)
	emptyRoot := filepath.Join(s.root, "EmptyRoot")
	pathDir := filepath.Join(s.root, "pathdir")
	for _, d := range []string{emptyRoot, pathDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"powershell.exe", "powershell", "pwsh.exe", "pwsh"} {
		launcherCopyExecutable(t, fake, filepath.Join(pathDir, name))
		launcherCopyExecutable(t, fake, filepath.Join(s.work, name))
	}
	res := s.run(t, []string{"status"}, map[string]string{
		"SystemRoot":   emptyRoot,
		"PATH":         pathDir + string(os.PathListSeparator) + os.Getenv("PATH"),
		"PSModulePath": filepath.Join(s.root, "PowerShell", "7", "Modules"),
	})
	launcherAssertOneErrorLine(t, res)
	launcherAssertNotStarted(t, s.record)
}

func TestLauncherDoesNotSearchPathWhenSystemRootIsUnset(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("on Windows the default C:\\Windows path is a real absolute path")
	}
	s := newLauncherScenario(t)
	_, fake := launcherBinaries(t)
	pathDir := filepath.Join(s.root, "pathdir")
	defaultName := `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
	for _, dir := range []string{pathDir, s.work} {
		launcherCopyExecutable(t, fake, filepath.Join(dir, defaultName))
		launcherCopyExecutable(t, fake, filepath.Join(dir, "powershell.exe"))
		launcherCopyExecutable(t, fake, filepath.Join(dir, `C:\Windows`, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"))
	}
	res := launcherExec(t, s.exe, []string{"status"}, launcherRun{
		dir: s.work,
		env: map[string]string{
			"SystemRoot":    "",
			"SYSTEMROOT":    "",
			"PATH":          pathDir + string(os.PathListSeparator) + os.Getenv("PATH"),
			"FAKEPS_RECORD": s.record,
		},
	})
	launcherAssertOneErrorLine(t, res)
	launcherAssertNotStarted(t, s.record)
}

func TestLauncherReportsOverlongCommandLine(t *testing.T) {
	s := newLauncherScenario(t)
	var args []string
	if runtime.GOOS == "windows" {
		// Fits the 32 767 limit as input, exceeds it once every quote is doubled.
		for i := 0; i < 18; i++ {
			args = append(args, strings.Repeat("'", 1700))
		}
	} else {
		// Linux limits one argument to 128 KiB; doubling pushes the text past it.
		args = []string{strings.Repeat("'", 70000)}
	}
	res := s.run(t, args, nil)
	launcherAssertOneErrorLine(t, res)
	launcherAssertNotStarted(t, s.record)
}

// ---------------------------------------------------------------------------
// V-12, V-13, V-15: waiting and exit codes

func TestLauncherPropagatesExitCode(t *testing.T) {
	codes := []int{0, 1, 2, 7, 255}
	if runtime.GOOS == "windows" {
		codes = append(codes, 256, 1000, -1073741510) // 0xC000013A STATUS_CONTROL_C_EXIT
	}
	for _, c := range codes {
		c := c
		t.Run(fmt.Sprint(c), func(t *testing.T) {
			s := newLauncherScenario(t)
			res := s.run(t, []string{"status"}, map[string]string{"FAKEPS_EXIT": fmt.Sprint(c)})
			want := c
			if runtime.GOOS == "windows" && c < 0 {
				want = int(uint32(int32(c)))
			}
			if res.code != want {
				t.Errorf("exit code %d, want %d", res.code, want)
			}
			if res.stdout != "fake-stdout\n" {
				t.Errorf("stdout %q, want only the PowerShell output", res.stdout)
			}
		})
	}
}

func TestLauncherWaitsForPowerShell(t *testing.T) {
	s := newLauncherScenario(t)
	done := filepath.Join(s.root, "done")
	res := s.run(t, []string{"status"}, map[string]string{
		"FAKEPS_SLEEP_MS": "500",
		"FAKEPS_DONE":     done,
		"FAKEPS_EXIT":     "3",
	})
	if _, err := os.Stat(done); err != nil {
		t.Errorf("launcher returned before PowerShell finished")
	}
	if res.code != 3 {
		t.Errorf("exit code %d, want 3", res.code)
	}
}

func TestLauncherSurvivesInterruptAndReturnsPowerShellExitCode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("os.Interrupt cannot be sent to a process on Windows; covered by CI-06")
	}
	s := newLauncherScenario(t)
	done := filepath.Join(s.root, "done")
	cmd, out, errOut, cancel := launcherStart(t, s.exe, []string{"clean"}, launcherRun{
		dir: s.work,
		env: map[string]string{
			"SystemRoot":      s.systemRoot,
			"FAKEPS_RECORD":   s.record,
			"FAKEPS_SLEEP_MS": "1500",
			"FAKEPS_DONE":     done,
			"FAKEPS_EXIT":     "5",
		},
	})
	deadline := time.Now().Add(30 * time.Second)
	for {
		if _, err := os.Stat(s.record); err == nil {
			break
		}
		if time.Now().After(deadline) {
			_ = cmd.Process.Kill()
			t.Fatal("PowerShell did not start")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := cmd.Process.Signal(os.Interrupt); err != nil {
		t.Fatalf("signal: %v", err)
	}
	res := launcherWait(t, cmd, out, errOut, cancel)
	if _, err := os.Stat(done); err != nil {
		t.Errorf("launcher ended before PowerShell finished after an interrupt")
	}
	if res.code != 5 {
		t.Errorf("exit code %d after interrupt, want PowerShell's 5", res.code)
	}
}

// ---------------------------------------------------------------------------
// End to end with a real PowerShell (optional, SWEEPR_TEST_PWSH)

// Off Windows: sw.exe -> fake powershell.exe -> real pwsh with the exact
// switches and -Command text the launcher produced.
// On Windows: sw.exe -> the real %SystemRoot% Windows PowerShell 5.1.
func TestLauncherRealPowerShellEndToEnd(t *testing.T) {
	pwsh := launcherRealPwsh(t)
	for i, folder := range launcherHostileFolders {
		folder := folder
		t.Run(fmt.Sprintf("folder%02d", i), func(t *testing.T) {
			root := t.TempDir()
			dir := filepath.Join(root, folder)
			launcherWriteDumpScript(t, dir)
			exe := launcherInstall(t, dir, false)
			work := filepath.Join(root, "work")
			if err := os.MkdirAll(work, 0o755); err != nil {
				t.Fatal(err)
			}
			env := map[string]string{}
			if runtime.GOOS != "windows" {
				env["SystemRoot"] = launcherSystemRoot(t)
				env["FAKEPS_EXEC"] = pwsh
			}
			for _, v := range launcherHostileCases {
				args := []string{"first", v}
				res := launcherExec(t, exe, args, launcherRun{dir: work, env: env})
				launcherAssertArgsArrived(t, res.stdout, args)
				if res.code != 7 {
					t.Errorf("%q: exit code %d, want 7; stderr %q", args, res.code, res.stderr)
				}
				if runtime.GOOS == "windows" && !strings.Contains(res.stdout, "PSV:5") {
					t.Errorf("%q: not Windows PowerShell 5.1; output %q", args, res.stdout)
				}
			}
			launcherAssertNoMarker(t, root)
		})
	}
}
