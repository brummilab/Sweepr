# Package Manager Manifests

Templates for publishing Mole CLI for Windows to winget and Scoop. They are filled per release by `scripts/render-packaging.ps1`; never submit a template as is.

| Manager | Package | Command on PATH | Update command |
|---|---|---|---|
| winget | `tw93.MoleCLI` | `mo` | `winget upgrade tw93.MoleCLI` |
| Scoop | `mole` | `mo`, `mole` | `scoop update mole` |

Every manager installs the signed `mole-<version>-x64.zip` from the GitHub release and starts Mole through the `mo.exe` launcher at the archive root. `mo update` recognizes these installs and prints the matching update command instead of pulling from git.

## Render

After the signed release is published:

```powershell
gh release download V1.31.0-windows --repo tw93/Mole --pattern SHA256SUMS.txt --dir release
.\scripts\render-packaging.ps1 -Version 1.31.0 -SumsFile release\SHA256SUMS.txt
```

The manifests land in `release\packaging\`.

## Submit

- **winget**: copy `release\packaging\winget\manifests\t\tw93\MoleCLI\<version>\` into a fork of [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) at the same path, check it with `winget validate --manifest <folder>` and `winget install --manifest <folder>`, then open a pull request.
- **Scoop**: `release\packaging\scoop\mole.json` goes to a bucket. Its `checkver` and `autoupdate` follow later `V<version>-windows` releases on their own.

The first submission to each registry reserves the name; later releases only bump the version and checksum.
