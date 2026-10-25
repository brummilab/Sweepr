//go:build !windows

package main

// touchesDataFolderIdentity has no file-identity comparison off Windows; the
// spelling and resolved-path checks apply.
func touchesDataFolderIdentity(string, []string) bool { return false }
