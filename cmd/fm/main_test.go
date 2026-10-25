package main

import "testing"

func TestCommandLineQuotesEveryArgument(t *testing.T) {
	got := commandLine(`C:\Program Files\freeMole\freemole.ps1`, []string{"clean", "--dry-run", "it's", "$env:USERPROFILE", "a b"})
	want := `& 'C:\Program Files\freeMole\freemole.ps1' 'clean' '--dry-run' 'it''s' '$env:USERPROFILE' 'a b'; exit $LASTEXITCODE`
	if got != want {
		t.Fatalf("commandLine:\n got %s\nwant %s", got, want)
	}
}

func TestCommandLineWithoutArgumentsOpensTheMenu(t *testing.T) {
	got := commandLine(`C:\freeMole\freemole.ps1`, nil)
	want := `& 'C:\freeMole\freemole.ps1'; exit $LASTEXITCODE`
	if got != want {
		t.Fatalf("commandLine:\n got %s\nwant %s", got, want)
	}
}
