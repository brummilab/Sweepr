package main

import "testing"

// normalizeWindowsPath(path string) string is a pure string function (no file
// system, no filepath.Abs, same result on every platform). It
//   - rewrites the verbatim and device prefixes \\?\X:\ , \\.\X:\ and \??\X:\ to X:\
//   - rewrites \\?\UNC\h\s\ , \\.\UNC\h\s\ and \??\UNC\h\s\ to \\h\s\
//   - lowercases the result
//
// and changes nothing else: separators, trailing separators, "." and ".." stay.
func TestNormalizeWindowsPath(t *testing.T) {
	cases := []struct{ in, want string }{
		{`C:\Data\Config`, `c:\data\config`},
		{`\\?\C:\Data\Config`, `c:\data\config`},
		{`\\?\c:\Data\Config`, `c:\data\config`},
		{`\\.\D:\Data`, `d:\data`},
		{`\??\E:\Data\x`, `e:\data\x`},
		{`\\?\C:\`, `c:\`},
		{`\\?\UNC\Host\Share\Dir\File`, `\\host\share\dir\file`},
		{`\\?\unc\Host\Share\Dir`, `\\host\share\dir`},
		{`\\.\UNC\Host\Share`, `\\host\share`},
		{`\??\UNC\Host\Share\Dir`, `\\host\share\dir`},
		{`\\Host\Share\Dir`, `\\host\share\dir`},
		{`\\localhost\C$\Data`, `\\localhost\c$\data`},
		{`C:\Data\Config\`, `c:\data\config\`},
		{`\Data\Config`, `\data\config`},
		{`relative\Path`, `relative\path`},
		{``, ``},
	}
	for _, c := range cases {
		if got := normalizeWindowsPath(c.in); got != c.want {
			t.Errorf("normalizeWindowsPath(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestNormalizeWindowsPathLeavesVolumeGuidAndGlobalrootAlone(t *testing.T) {
	// Only drive letters and UNC are rewritten; other device spellings keep their
	// prefix (lowercased), so they never collide with a drive-letter folder.
	for _, in := range []string{
		`\\?\Volume{1234}\Data`,
		`\\?\GLOBALROOT\Device\X\Data`,
	} {
		got := normalizeWindowsPath(in)
		if got[:4] != `\\?\` {
			t.Errorf("normalizeWindowsPath(%q) = %q, expected the \\\\?\\ prefix to stay", in, got)
		}
	}
}

func TestNormalizeWindowsPathMakesSpellingsEqual(t *testing.T) {
	want := normalizeWindowsPath(`C:\Users\Example\Data\config`)
	for _, in := range []string{
		`\\?\C:\Users\Example\Data\config`,
		`\\.\c:\USERS\example\DATA\Config`,
		`\??\C:\Users\Example\Data\config`,
	} {
		if got := normalizeWindowsPath(in); got != want {
			t.Errorf("normalizeWindowsPath(%q) = %q, want %q", in, got, want)
		}
	}
}
