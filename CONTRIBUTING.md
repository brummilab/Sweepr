# Contributing to Sweepr

Thanks for helping. Development happens on `main`.

## Setup

- Windows 10 or 11 with the built-in Windows PowerShell 5.1
- [Pester](https://pester.dev) 5 or newer: `Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck`
- Go, for the `analyze` and `status` TUIs and the `sw.exe` launcher; the version is pinned by `toolchain` in `go.mod`
- Git

## Development

```powershell
.\scripts\test.ps1                 # Pester tests and Go tests
Invoke-Pester -Path .\tests        # PowerShell tests only
go test ./cmd/...                  # Go tests only
gofmt -l cmd                       # Must print nothing
.\sweepr.ps1 clean --dry-run       # Try a change without deleting anything
```

CI runs the Pester tests under both Windows PowerShell 5.1 and pwsh 7, so avoid syntax that only pwsh 7 understands, such as `??`, `?.`, the ternary operator, or `ForEach-Object -Parallel`. Keep scripts ASCII, or UTF-8 with a BOM.

## Safety Rules

- Delete only through the helpers in `lib/core/file_ops.ps1` (`Remove-SafeItem`, `Remove-SafeItems`, `Remove-OldFiles`, `Clear-DirectoryContents`). They check protected paths and the whitelist and honor dry-run mode. Never call `Remove-Item -Recurse` directly.
- Every command that deletes or uninstalls must do nothing but report in `--dry-run` mode.
- Never touch `C:\Windows`, `C:\Program Files`, Windows Defender folders, or the user profile root. Add protections to `lib/core/base.ps1` rather than working around them.
- Prefer leaving something behind over deleting something that might be in use.

## Pull Requests

1. Branch from `main`.
2. Add or update Pester tests for the behavior you change, and confirm a new test fails without your change.
3. Run `.\scripts\test.ps1`.
4. Describe what changed and how you verified it, including any `--dry-run` output.

By contributing you agree that your work is released under the [GPL-3.0](LICENSE) license.
