package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// PowerShell treats these as single-quote characters inside a '...' literal,
// not only the ASCII apostrophe: U+2018, U+2019, U+201A, U+201B.
var singleQuoteLike = []rune{'\'', '\u2018', '\u2019', '\u201A', '\u201B'}

func isSingleQuoteLike(r rune) bool {
	for _, q := range singleQuoteLike {
		if r == q {
			return true
		}
	}
	return false
}

// hostileArguments are values a user, a folder name or a package path can
// carry. Each must reach the script as exactly one unchanged argument.
var hostileArguments = []struct {
	name  string
	value string
}{
	{"ascii apostrophe", "it's"},
	{"left single quotation mark", "a\u2018b"},
	{"right single quotation mark", "Rock\u2019n\u2019Roll"},
	{"single low-9 quotation mark", "a\u201Ab"},
	{"single high-reversed-9 quotation mark", "a\u201Bb"},
	{"all five quote characters", "'\u2018\u2019\u201A\u201B"},
	{"leading and trailing smart quote", "\u2019x\u2019"},
	{"space", "a b  c"},
	{"semicolon", "a;b"},
	{"dollar", "$env:PATH $(Get-Date) ${x}"},
	{"backtick", "a`b`n`$x"},
	{"double quote", `say "hi" ""`},
	{"trailing backslash", `C:\Music\`},
	{"trailing backslash before quote", `C:\Music\"`},
	{"injection with smart quotes", "x\u2019; New-Item marker; \u2019"},
	{"injection with ascii quotes", "x'; New-Item marker; '"},
	{"injection with left quote", "x\u2018; New-Item marker; \u2018"},
	{"injection with low-9 quote", "x\u201A; New-Item marker; \u201A"},
	{"injection with high-reversed-9 quote", "x\u201B; New-Item marker; \u201B"},
	{"injection via subexpression", "\u2019$(New-Item marker)\u2019"},
	{"combination", "O\u2019Neil's \u2018x\u201A \u201By; $z `w\\ \"q\" \\"},
}

// TestQuoteDoublesEveryQuoteLikeCharacter checks the literal itself, without
// PowerShell: inside the outer quotes no quote-like character may stand alone,
// because PowerShell would read it as the end of the string. A run of such
// characters must have even length, which is what doubling produces.
func TestQuoteDoublesEveryQuoteLikeCharacter(t *testing.T) {
	for _, tc := range hostileArguments {
		t.Run(tc.name, func(t *testing.T) {
			got := quote(tc.value)
			if !strings.HasPrefix(got, "'") || !strings.HasSuffix(got, "'") || len(got) < 2 {
				t.Fatalf("quote(%q) = %q, want a single-quoted literal", tc.value, got)
			}
			body := []rune(got[1 : len(got)-1])
			for i := 0; i < len(body); {
				if !isSingleQuoteLike(body[i]) {
					i++
					continue
				}
				// Doubling is per character: a lone character or a pair of
				// different characters would close the literal.
				if i+1 >= len(body) || body[i+1] != body[i] {
					t.Fatalf("quote(%q) = %q: %q at rune %d is not doubled, PowerShell ends the literal there", tc.value, got, body[i], i)
				}
				i += 2
			}
			// Undoubling the literal gives back the original value.
			undoubled := string(body)
			for _, q := range singleQuoteLike {
				undoubled = strings.ReplaceAll(undoubled, string([]rune{q, q}), string(q))
			}
			if undoubled != tc.value {
				t.Fatalf("quote(%q) = %q: undoubled to %q, value changed", tc.value, got, undoubled)
			}
		})
	}
}

func TestQuoteSmartQuotesAreDoubledExactly(t *testing.T) {
	cases := map[string]string{
		"\u2018":      "'\u2018\u2018'",
		"\u2019":      "'\u2019\u2019'",
		"\u201A":      "'\u201A\u201A'",
		"\u201B":      "'\u201B\u201B'",
		"'":           "''''",
		"Rock\u2019n": "'Rock\u2019\u2019n'",
		"a b;$c`d":    "'a b;$c`d'",
		`C:\Music\`:   `'C:\Music\'`,
		`say "hi"`:    `'say "hi"'`,
	}
	for in, want := range cases {
		if got := quote(in); got != want {
			t.Errorf("quote(%q):\n got %s\nwant %s", in, got, want)
		}
	}
}

func TestCommandLineQuotesSmartQuotesInScriptPathAndArguments(t *testing.T) {
	got := commandLine("C:\\Users\\D\u2019Angelo\\sweepr.ps1", []string{"D:\\Musik\\Guns N\u2019 Roses"})
	want := "& 'C:\\Users\\D\u2019\u2019Angelo\\sweepr.ps1' 'D:\\Musik\\Guns N\u2019\u2019 Roses'; exit $LASTEXITCODE"
	if got != want {
		t.Fatalf("commandLine:\n got %s\nwant %s", got, want)
	}
}

// echoScript prints every argument as upper-case hex UTF-16 code units, one
// argument per line, so the comparison is independent of console encodings.
const echoScript = `$lines = foreach ($a in $args) { ($a.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join '' }
[Console]::Out.Write(($lines -join "` + "`n" + `"))
`

func hexUnits(value string) string {
	var b strings.Builder
	for _, u := range utf16Units(value) {
		fmt.Fprintf(&b, "%04X", u)
	}
	return b.String()
}

func utf16Units(value string) []uint16 {
	var units []uint16
	for _, r := range value {
		if r >= 0x10000 {
			r -= 0x10000
			units = append(units, uint16(0xD800+(r>>10)), uint16(0xDC00+(r&0x3FF)))
			continue
		}
		units = append(units, uint16(r))
	}
	return units
}

func testPwsh(t *testing.T) string {
	t.Helper()
	path := os.Getenv("SWEEPR_TEST_PWSH")
	if path == "" {
		t.Skip("SWEEPR_TEST_PWSH not set; skipping the real PowerShell check")
	}
	return path
}

// runThroughPowerShell runs commandLine(script, args) with a real PowerShell
// in dir and returns the hex lines the echo script printed.
func runThroughPowerShell(t *testing.T, pwsh, dir, script string, args []string) []string {
	t.Helper()
	cmd := exec.Command(pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", commandLine(script, args))
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("PowerShell failed: %v\nargs: %q\ncommand: %s\noutput:\n%s", err, args, commandLine(script, args), out)
	}
	text := strings.TrimRight(string(out), "\r\n")
	if len(args) == 0 {
		return nil
	}
	return strings.Split(text, "\n")
}

func TestHostileArgumentsReachScriptUnchangedInPowerShell(t *testing.T) {
	pwsh := testPwsh(t)
	for _, tc := range hostileArguments {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			script := filepath.Join(dir, "echo.ps1")
			if err := os.WriteFile(script, []byte(echoScript), 0o644); err != nil {
				t.Fatal(err)
			}
			got := runThroughPowerShell(t, pwsh, dir, script, []string{"first", tc.value})
			want := []string{hexUnits("first"), hexUnits(tc.value)}
			if strings.Join(got, "|") != strings.Join(want, "|") {
				t.Fatalf("arguments seen by the script:\n got %v\nwant %v", got, want)
			}
			if _, err := os.Stat(filepath.Join(dir, "marker")); err == nil {
				t.Fatalf("injected command ran: %s exists", filepath.Join(dir, "marker"))
			}
		})
	}
}

func TestInjectionThroughSmartQuotesRunsNoCommand(t *testing.T) {
	pwsh := testPwsh(t)
	for _, q := range []string{"\u2018", "\u2019", "\u201A", "\u201B", "'"} {
		t.Run(fmt.Sprintf("U+%04X", []rune(q)[0]), func(t *testing.T) {
			dir := t.TempDir()
			script := filepath.Join(dir, "echo.ps1")
			if err := os.WriteFile(script, []byte(echoScript), 0o644); err != nil {
				t.Fatal(err)
			}
			arg := "x" + q + "; New-Item marker; " + q
			got := runThroughPowerShell(t, pwsh, dir, script, []string{arg})
			if len(got) != 1 || got[0] != hexUnits(arg) {
				t.Fatalf("argument seen by the script:\n got %v\nwant [%s]", got, hexUnits(arg))
			}
			if _, err := os.Stat(filepath.Join(dir, "marker")); err == nil {
				t.Fatalf("injected command ran: %s exists", filepath.Join(dir, "marker"))
			}
		})
	}
}

func TestScriptPathWithQuoteLikeCharactersStillRuns(t *testing.T) {
	pwsh := testPwsh(t)
	names := []string{"D\u2019Angelo", "D\u2018Angelo", "D\u201AAngelo", "D\u201BAngelo", "O'Neil", "x\u2019; New-Item marker; \u2019"}
	for _, name := range names {
		t.Run(name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), name)
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Skipf("cannot create folder %q here: %v", name, err)
			}
			script := filepath.Join(dir, "echo.ps1")
			if err := os.WriteFile(script, []byte(echoScript), 0o644); err != nil {
				t.Fatal(err)
			}
			work := t.TempDir()
			got := runThroughPowerShell(t, pwsh, work, script, []string{"ok"})
			if len(got) != 1 || got[0] != hexUnits("ok") {
				t.Fatalf("script in %q did not run correctly: got %v", dir, got)
			}
			if _, err := os.Stat(filepath.Join(work, "marker")); err == nil {
				t.Fatalf("injected command ran from the script path")
			}
		})
	}
}
