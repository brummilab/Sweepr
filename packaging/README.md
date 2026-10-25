# Package Manager Manifests

Templates for publishing Sweepr to winget and Scoop. They are filled per release by `scripts/render-packaging.ps1`; never submit a template as is.

| Manager | Package | Command on PATH | Update command |
|---|---|---|---|
| winget | `brummilab.Sweepr` | `sw` | `winget upgrade brummilab.Sweepr` |
| Scoop | `sweepr` | `sw`, `sweepr` | `scoop update sweepr` |

Every manager installs the signed `sweepr-<version>-x64.zip` from the GitHub release and starts Sweepr through the `sw.exe` launcher at the archive root. `sw update` recognizes these installs and prints the matching update command instead of pulling from git.

## Render

After the signed release is published:

```powershell
gh release download V1.31.0-windows --repo brummilab/sweepr --pattern SHA256SUMS.txt --dir release
.\scripts\render-packaging.ps1 -Version 1.31.0 -SumsFile release\SHA256SUMS.txt
```

The manifests land in `release\packaging\`.

## Submit

- **winget**: copy `release\packaging\winget\manifests\b\brummilab\Sweepr\<version>\` into a fork of [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) at the same path, check it with `winget validate --manifest <folder>` and `winget install --manifest <folder>`, then open a pull request.
- **Scoop**: `release\packaging\scoop\sweepr.json` goes to a bucket. Its `checkver` and `autoupdate` follow later `V<version>-windows` releases on their own.

The first submission to each registry reserves the name; later releases only bump the version and checksum.
