# Sweepr - Release Guide

A release goes through three steps: CI builds the assets into a draft release, the maintainer signs them on Windows, and the signed files replace the draft's before it is published.

## Tags

| Tag | Result |
|---|---|
| `V0.1.0-windows` | Stable release |
| `V0.2.0-beta.1-windows` | Prerelease (any `-` left after removing `-windows`) |

`sw update` and the update notice read published `V<version>-windows` releases of `brummilab/sweepr`.

## Assets

| File | Purpose |
|---|---|
| `sweepr-<version>-x64.zip` | What winget and Scoop install; `sw.exe` at its root is what they put on PATH |
| `sweepr-<version>-x64-portable.zip` | The same tree plus the `sweepr.portable` marker: unzip and run `sw.exe`, all data in its `data` folder. winget and Scoop use the normal zip, since the marker would switch them into portable mode |
| `analyze-windows-x64.exe`, `status-windows-x64.exe` | TUIs that source installs download on first use |
| `SHA256SUMS.txt` | Checksums of the four files above; the TUI download refuses a file that does not match |

## 1. Prepare

1. CI is green on the `main` commit you will tag: `Check` and `Validation`, including both PowerShell legs.
2. Bump the version in one commit: `VERSION` and `$script:SwFallbackVersion` in `lib/core/version.ps1`. (The transition variable `$script:SweeprDefaultVersion` takes the same value from it until N-14; do not edit it.)
3. Optional: `scripts/e2e_windows.py --host user@address` exits 0 against a real Windows PC at that commit (see `CONTRIBUTING.md`, "Windows e2e").

## 2. Tag

```powershell
git tag V0.1.0-windows
git push origin V0.1.0-windows
```

`.github/workflows/release-windows.yml` runs the tests, runs `scripts/build-release.ps1`, and creates a **draft** release with the unsigned assets.

## 3. Sign

On a Windows machine with the code-signing certificate available:

```powershell
gh release download V0.1.0-windows --repo brummilab/sweepr --dir C:\sweepr-release
$env:SWEEPR_SIGN_PARAMS = "/fd sha256 /tr <timestamp-url> /td sha256 /sha1 <thumbprint>"
.\scripts\sign-release.ps1 -Path C:\sweepr-release
```

The script needs an x64 `signtool.exe` (it finds the Windows SDK build tools, or set `SWEEPR_SIGNTOOL`). It signs every `.ps1` and `.exe` in the zip and both TUI executables, verifies each signature and timestamp against the thumbprint, rebuilds the zip, and rewrites `SHA256SUMS.txt`. A timestamp or HSM hiccup is retried once; a second failure stops the script.

Known gap: `sign-release.ps1` only handles `sweepr-<version>-x64.zip`. The portable zip is neither signed nor listed again when `SHA256SUMS.txt` is rewritten, so a signed release needs the script extended first (board card R-04).

Without a code-signing certificate, the draft can be published unsigned; the checksums still protect the TUI downloads.

## 4. Publish

```powershell
gh release upload V0.1.0-windows C:\sweepr-release\* --repo brummilab/sweepr --clobber
gh release edit V0.1.0-windows --repo brummilab/sweepr --title "V0.1.0-windows" --draft=false
```

Then check that a downloaded asset matches `SHA256SUMS.txt` and, for a signed release, that `Get-AuthenticodeSignature` reports `Valid` for `sw.exe`.

## 5. Package managers

Render and submit the winget and Scoop manifests as described in `packaging/README.md`.
