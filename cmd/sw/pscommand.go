package main

import (
	"strings"
	"unicode/utf8"
)

// PowerShell closes a single-quoted string not only at the ASCII apostrophe
// but also at the four typographic single quotes U+2018..U+201B (5.1 and 7).
// Inside such a literal every other character is taken verbatim, so doubling
// these five characters is the only escaping needed.
func endsPsLiteral(r rune) bool {
	switch r {
	case '\'', '‘', '’', '‚', '‛':
		return true
	}
	return false
}

// psLiteral returns value as one single-quoted PowerShell string literal.
// Each quote-like character is doubled with itself (not with an ASCII
// apostrophe), because PowerShell only treats a pair of the same character as
// an escaped quote. Bytes are copied as they are, including invalid UTF-8, so
// the value arrives unchanged.
func psLiteral(value string) string {
	var b strings.Builder
	b.Grow(len(value) + 2)
	b.WriteByte('\'')
	for i := 0; i < len(value); {
		r, size := utf8.DecodeRuneInString(value[i:])
		chunk := value[i : i+size]
		b.WriteString(chunk)
		if endsPsLiteral(r) {
			b.WriteString(chunk)
		}
		i += size
	}
	b.WriteByte('\'')
	return b.String()
}

// psCommandText builds the -Command text that runs script with args through
// the call operator. Every element is its own literal, so nothing from a path
// or an argument is ever parsed as code; the trailing exit hands the script's
// exit status back as the status of powershell.exe.
func psCommandText(script string, args []string) string {
	var b strings.Builder
	b.WriteString("& ")
	b.WriteString(psLiteral(script))
	for _, a := range args {
		b.WriteByte(' ')
		b.WriteString(psLiteral(a))
	}
	b.WriteString("; exit $LASTEXITCODE")
	return b.String()
}
