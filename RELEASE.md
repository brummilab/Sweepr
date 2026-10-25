# Sweepr - Release Guide

A release goes through three steps: CI builds the assets into a draft release, the maintainer signs them on Windows, and the signed files replace the draft's before it is published.

## Tags

| Tag | Result |
|---|---|
| `V1.0.0-windows` | Stable release |
| `V1.0.0-beta.1-windows` | Prerelease (any `-` left after removing `-windows`) |

`sw update` and the update notice read published `V<version>-windows` releases of `brummilab/sweepr`.

## Assets

| File | Purpose |
|---|---|
| `sweepr-<version>-x64.zip` | What winget and Scoop install; `sw.exe` at its root is what they put on PATH |
| `analyze-windows-x64.exe`, `status-windows-x64.exe` | TUIs that source installs download on first use |
| `SHA256SUMS.txt` | Checksums of the three files above; the TUI download refuses a file that does not match |

## 1. Prepare

1. CI is green on the `main` commit you will tag: `Check` and `Validation`, including both PowerShell legs.
2. Bump the version in one commit: `VERSION` and `$script:SweeprDefaultVersion` in `lib/core/version.ps1`.
3. Optional: `scripts/e2e_windows.py --host user@address` exits 0 against a real Windows PC at that commit (see `CONTRIBUTING.md`, "Windows e2e").

## 2. Tag

```powershell
git tag V1.0.0-windows
git push origin V1.0.0-windows
```

`.github/workflows/release-windows.yml` runs the tests, runs `scripts/build-release.ps1`, and creates a **draft** release with the unsigned assets.

## 3. Sign

On a Windows machine with the code-signing certificate available:

```powershell
gh release download V1.0.0-windows --repo brummilab/sweepr --dir C:\sweepr-release
$env:SWEEPR_SIGN_PARAMS = "/fd sha256 /tr <timestamp-url> /td sha256 /sha1 <thumbprint>"
.\scripts\sign-release.ps1 -Path C:\sweepr-release
```

The script needs an x64 `signtool.exe` (it finds the Windows SDK build tools, or set `SWEEPR_SIGNTOOL`). It signs every `.ps1` and `.exe` in the zip and both TUI executables, verifies each signature and timestamp against the thumbprint, rebuilds the zip, and rewrites `SHA256SUMS.txt`. A timestamp or HSM hiccup is retried once; a second failure stops the script.

Without a code-signing certificate, the draft can be published unsigned; the checksums still protect the TUI downloads.

## 4. Publish

```powershell
gh release upload V1.0.0-windows C:\sweepr-release\* --repo brummilab/sweepr --clobber
gh release edit V1.0.0-windows --repo brummilab/sweepr --title "V1.0.0-windows" --draft=false
```

Then check that a downloaded asset matches `SHA256SUMS.txt` and, for a signed release, that `Get-AuthenticodeSignature` reports `Valid` for `sw.exe`.

## 5. Package managers

Render and submit the winget and Scoop manifests as described in `packaging/README.md`.
