# Sweepr - Release Guide

A release goes through two steps: CI builds the assets into a draft release, and the maintainer checks them before the draft is published.

## Tags

| Tag | Result |
|---|---|
| `V0.1.0-windows` | Stable release |
| `V0.2.0-beta.1-windows` | Prerelease (any `-` left after removing `-windows`) |

`sw update` and the update notice read published `V<version>-windows` releases of `brummilab/sweepr`.

## Assets

| File | Purpose |
|---|---|
| `sweepr-<version>-x64.zip` | The install archive; `sw.exe` at its root is the command that goes on PATH |
| `sweepr-<version>-x64-portable.zip` | The same tree plus the `sweepr.portable` marker: unzip and run `sw.exe`, all data in its `data` folder |
| `analyze-windows-x64.exe`, `status-windows-x64.exe` | TUIs that source installs download on first use |
| `SHA256SUMS.txt` | Checksums of the four files above; the TUI download refuses a file that does not match |

## 1. Prepare

1. CI is green on the `main` commit you will tag: `Check` and `Validation`, including both PowerShell legs.
2. Bump the version in one commit: `VERSION` and `$script:SweeprDefaultVersion` in `lib/core/version.ps1`.

## 2. Tag

```powershell
git tag V0.1.0-windows
git push origin V0.1.0-windows
```

`.github/workflows/release-windows.yml` runs the tests, runs `scripts/build-release.ps1`, and creates a **draft** release with the unsigned assets.

## 3. Publish

```powershell
gh release edit V0.1.0-windows --repo brummilab/sweepr --title "V0.1.0-windows" --draft=false
```

Then check that a downloaded asset matches `SHA256SUMS.txt`. Releases are not code-signed; the checksums protect the TUI downloads.
