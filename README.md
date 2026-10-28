<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/img/logo-wordmark-dark.svg">
    <img src="docs/img/logo-wordmark-light.svg" alt="Sweepr" width="480">
  </picture>
  <p><b>Clean up a Windows PC, uninstall apps, optimize, analyze disk usage, monitor the system. Free and open-source CLI.</b></p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <p><a href="README.de.md">Deutsch</a> · <b>English</b></p>
  <p><a href="https://brummilab.github.io/Sweepr/">Project page</a> · <a href="ROADMAP.md">Roadmap</a></p>
</div>

## Features

- **Deep clean** (`sw clean`): remove temp files, caches, logs and browser leftovers
- **Uninstall** (`sw uninstall`): remove apps with their own uninstaller and clean up leftover folders
- **Optimize** (`sw optimize`): flush DNS, optimize the system drive, check disk health
- **Disk analysis** (`sw analyze`): interactive disk explorer (TUI), find large files
- **Live monitoring** (`sw status`): CPU, RAM, disk, network and processes in real time
- **Project purge** (`sw purge`): remove old build artifacts (`node_modules`, `bin/obj`, ...)
- **Debloat Windows** (`sw features`): remove or turn off preinstalled Microsoft apps and optional Windows features from a reviewed list

## Quick start

Sweepr runs on Windows 10 and 11 with the built-in Windows PowerShell 5.1. Release files are at [github.com/brummilab/Sweepr/releases](https://github.com/brummilab/Sweepr/releases):

| File | Purpose |
| --- | --- |
| `sweepr-<version>-x64.zip` | Program files with `install.ps1`, `sw.exe` and the prebuilt TUI tools; regular installation |
| `sweepr-<version>-x64-portable.zip` | The same plus the marker file `sweepr.portable`; runs without installation, see [Portable version](#portable-version) |
| `analyze-windows-x64.exe`, `status-windows-x64.exe` | The two TUI tools on their own; Sweepr downloads them when needed and checks them against `SHA256SUMS.txt` |
| `SHA256SUMS.txt` | SHA-256 checksums of both ZIPs and both TUI tools |

Three ways to get Sweepr:

1. **Portable ZIP**: install nothing, unzip the folder and run `sw.exe` ([details](#portable-version)).
2. **Install ZIP**: unzip `sweepr-<version>-x64.zip` and run the installer in it. Needs neither Git nor Go, because the TUI tools are in the ZIP:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddToPath
   ```

   It installs to `%LOCALAPPDATA%\Programs\sweepr-cli`. A copy installed this way has no `.git`; `sw update` cannot update it and points to a reinstall (remove or rename the folder, then use Quick install or a new release ZIP with a different `-InstallDir`).
3. **Quick install from source**: clones `main` to `%LOCALAPPDATA%\Programs\sweepr-cli` and runs the installer. Needs **Git**. For `analyze.exe` and `status.exe` the installer uses the verified release binary only when the cloned source matches the release tag; otherwise it builds them with **Go**. Without Go the tool stays unavailable for now (the installer warns).

   ```powershell
   iwr -useb https://raw.githubusercontent.com/brummilab/Sweepr/main/quick-install.ps1 | iex
   ```

   Or review the code first and install locally (keeps `.git`, so `sw update` works):

   ```powershell
   $installDir = "$env:LOCALAPPDATA\Programs\sweepr-cli"
   git clone https://github.com/brummilab/Sweepr.git $installDir
   powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
   ```

With the install ZIP and Quick install, `sw` and `sweepr` go on the user PATH when the component `path` is selected (see [Installation with component selection](#installation-with-component-selection)). A Start menu entry is the component `shortcut`. Remove with `sw remove`.

Compare the checksum of a download:

```powershell
Get-FileHash .\sweepr-<version>-x64.zip -Algorithm SHA256   # compare with SHA256SUMS.txt
```

## Installation with component selection

`install.ps1` has four selectable components; the core (program files, `sw.cmd`, `sweepr.cmd`) is always installed:

| Component | Effect |
| --- | --- |
| `path` | Add the install folder to the user PATH |
| `shortcut` | Create the Start menu entry "Sweepr CLI" |
| `analyze` | Provide `analyze.exe` during installation |
| `status` | Provide `status.exe` during installation |

Selecting `analyze` and `status` matters for source installs: TUI tools that are not selected are not provided up front, but downloaded or built on the first `sw analyze` or `sw status`. The install ZIP and the portable ZIP already carry both tools in `bin\`; the installer copies them in any case.

The first matching rule decides the selection:

1. `-Components path,shortcut,analyze,status` (comma-separated, case-insensitive): exactly these components.
2. Environment variable `SWEEPR_COMPONENTS` (same format): exactly these components. With rules 1 and 2, `-AddToPath` and `-CreateShortcut` do not count.
3. A real console (input and output not redirected) and no `-NoPrompt`: a menu. Up/Down moves, Space toggles, Enter installs, Esc or Q cancels (message "Installation cancelled", nothing is installed, exit code 3).
4. Otherwise the default: `analyze` and `status`, plus `path` with `-AddToPath` and `shortcut` with `-CreateShortcut`.

The menu starts with the same default as rule 4 preselected. Because `quick-install.ps1` calls the installer with `-AddToPath`, `path`, `analyze` and `status` are preselected there. An unknown component name stops with exit code 2 before anything is copied.

```powershell
# Without a menu: only PATH and the status tool
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Components path,status -NoPrompt

# The same through the environment (for scripts)
$env:SWEEPR_COMPONENTS = "path,status"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The selection is not saved. `sw update` runs the installer with `-NoPrompt` (never a menu) and keeps the PATH entry when the folder is already on the user PATH. Cancelling the menu in `quick-install.ps1` reports "Installation cancelled" (exit code 1) and removes the folder cloned in this run; an existing folder is not deleted. An existing source install has, however, already been updated with `git fetch` and `git pull --ff-only` before the installer runs.

## Portable version

The portable version needs no installation. It stores none of its own files in the user profile and does not change PATH or the Start menu.

1. Unzip `sweepr-<version>-x64-portable.zip` from the [releases](https://github.com/brummilab/Sweepr/releases) into a writable folder (for example on a USB stick).
2. Run `sw.exe` in that folder (`.\sw.exe`, `.\sw.exe clean --dry-run`, ...). It starts `sweepr.ps1` from the same folder.

Portable mode is recognized by the file `sweepr.portable` next to `sweepr.ps1`. All of Sweepr's own files then live in the `data` subfolder of the program folder: settings, whitelist and the log `operations.log` in `data\config`, caches (update check, app scan cache) in `data\cache`. The log therefore moves with the folder; `sw history` shows it, `SWEEPR_NO_OPLOG=1` turns it off. The update check runs as usual and points out new versions.

- **Update:** `sw update` updates nothing; it names the download (`sweepr-<version>-x64-portable.zip`) and exits with code 1. Download the new ZIP, replace the program files and keep the `data` folder.
- **Remove:** `sw remove` deletes nothing and exits with code 1. To remove, delete the folder itself; your own data is in `data`. `install.ps1 -Uninstall` refuses a portable folder as well.
- **Folder not writable:** If Sweepr cannot create or write its data folder, it stops with the message `Sweepr data folder is not writable: <path>. Sweepr does not fall back to your user profile.` and exit code 1. It never falls back to the user profile.
- **Other data folder:** The environment variable `SWEEPR_DATA_DIR` (also usable without the portable ZIP) sets the data folder; see [Folders](#folders). It takes precedence over `data`.

The cleanup targets of `sw clean` and the other commands are still the folders of the Windows profile; only Sweepr's own data is portable.

## Check a PC once (`sw check`)

Look at someone else's PC without installing or changing anything:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; iwr -useb https://raw.githubusercontent.com/brummilab/Sweepr/main/check.ps1 | iex
```

`check.ps1` downloads the latest portable release into its own folder under `%TEMP%`, checks it against `SHA256SUMS.txt` (nothing runs on a mismatch), runs `sw check --report` in it (read-only, nothing is deleted) and then removes the folder. Only the HTML report remains in `%TEMP%`. In Constrained Language Mode, or when a group policy sets the execution policy to `Restricted` or `AllSigned`, it stops before the download with a message. Needs Sweepr 0.2 or later.

## Commands

```powershell
sw                           # Interactive menu
sw clean                     # Clean up
sw uninstall                 # Remove apps and leftovers
sw optimize                  # Refresh caches and services
sw analyze                   # Disk explorer
sw status                    # Live system monitor
sw purge                     # Remove project build artifacts
sw features                  # Remove preinstalled apps / Windows features

sw update                    # Update a source install (git pull from main)
sw remove                    # Remove Sweepr from the PC (portable: deletes nothing)
sw --help                    # Help
sw --version                 # Version
```

**Look first, then delete**

```powershell
sw clean --dry-run
sw uninstall --dry-run
sw optimize --dry-run
sw purge --dry-run
sw features --dry-run        # Shows the exact commands, changes nothing
sw features --list           # List only (JSON when redirected)
sw features --restore        # Restore what was removed earlier (preview only with --dry-run)
sw history                   # What was removed, and when?
sw history --json

sw clean --dry-run --debug   # Preview plus detailed log
sw clean --whitelist         # Manage protected paths
sw clean --system            # Include system cleanup (as administrator)
sw purge --paths             # Set project search folders
sw analyze D:\               # Analyze another drive
sw uninstall --list          # List installed apps (JSON when redirected)
sw analyze --json D:\        # Disk report as JSON
```

## Debloat Windows (`sw features`)

`sw features` offers only entries from a **reviewed list** (preinstalled Microsoft apps such as Weather, News, Solitaire, Xbox apps, and optional features such as PowerShell 2.0, XPS services, Internet Explorer 11, Windows Media Player). What Windows needs to run (Store, App Installer, security, Edge, WebView2, runtimes, Hyper-V, WSL, SMB, .NET) is never offered.

- Menu with arrow keys, Space selects, Enter confirms, Esc/Q cancels. **Nothing is preselected**; Sweepr asks `(y/N)` before removing.
- Apps are removed for the current user (no administrator needed). `--all-users-future` also removes them for future users (administrator needed).
- Optional features are only turned off (not deleted) and need an administrator PowerShell. Sweepr does not request rights and never restarts; when Windows needs a restart, the last line reads "Restart Windows to finish."
- Each entry is checked again right before removal; every action is in the log (`sw history`).
- Undo with `sw features --restore`: before each removal Sweepr saves an entry in `features-removed.json` in the data folder (profile, portable or `SWEEPR_DATA_DIR`). If the list cannot be read or saved, nothing is removed; `sw remove` keeps the file like `operations.log`. `--restore` shows the saved entries in the menu (nothing preselected), `--restore --dry-run` shows the exact commands, then Sweepr asks `(y/N)`.
  - Optional features: `Enable-WindowsOptionalFeature -Online -FeatureName <Name> -NoRestart` (needs an administrator PowerShell; a restart is only reported, never performed).
  - Apps: `winget install --id <Store ID> --source msstore`; without a known Store ID or without winget, Sweepr names the Microsoft Store. If the app is already installed, only the entry is removed.
  - Entries restored successfully leave the list; failed ones stay for another attempt. `--restore` cannot be combined with `--list` or `--all-users-future`.

## Safety

Sweepr can delete files, so paths are validated and system and profile folders are protected. `uninstall`, `purge` and `remove` ask before removing. Whatever is not shown to be safe is skipped.

- Look at `clean`, `uninstall` and `purge` with `--dry-run` first, add `--debug` when needed
- `clean` and `purge` delete permanently; verified `uninstall` leftovers and files deleted in `sw analyze` go to the Recycle Bin
- Run as a normal user; system steps run only in an administrator PowerShell
- Protect paths with `sw clean --whitelist`. Entries may be in quotes (like "Copy as path"), contain `/` instead of `\` and use `%VAR%` and `~` (profile folder). Entries with `*` or `?` also protect all subfolders. The file is written as UTF-8 (with BOM); non-ASCII characters work. The same spellings apply to `purge_paths.txt`.
- Activity is logged in `%USERPROFILE%\.config\sweepr\operations.log` (portable: `data\config\operations.log`; `sw history`; turn off with `SWEEPR_NO_OPLOG=1`)
- `C:\Windows`, `C:\Program Files`, Windows Defender folders and the profile root are never touched

Please report security issues privately through [GitHub Security Advisories](https://github.com/brummilab/Sweepr/security/advisories/new), not as a public issue. Details: [SECURITY.md](SECURITY.md).

## Folders

| | Installed (default) | Portable | with `SWEEPR_DATA_DIR=<folder>` |
| --- | --- | --- | --- |
| Command | `sw`, `sweepr` | `sw.exe` in the program folder | as installed |
| Programs (incl. TUI tools in `bin\`) | `%LOCALAPPDATA%\Programs\sweepr-cli` | the unzipped folder | as installed |
| Configuration and log | `%USERPROFILE%\.config\sweepr` | `<program folder>\data\config` | `<folder>\config` |
| Cache | `%USERPROFILE%\.cache\sweepr` | `<program folder>\data\cache` | `<folder>\cache` |
| Update source | `brummilab/Sweepr`, branch `main` (source install) | new ZIP from the releases | as installed |

- **Configuration and log** hold the whitelist (`whitelist.txt`), `operations.log`, the search folders of `sw purge` (`purge_paths.txt`), the list of the last `sw clean` (`clean-list.txt`), the debug log (`--debug`) and the settings of `sw status`.
- **Cache** holds the app scan cache of `sw uninstall` and the update check data. The TUI tools `analyze.exe` and `status.exe` are not here but in the program folder under `bin\`.
- **`SWEEPR_DATA_DIR`** takes precedence over portable mode and the profile. A relative path is resolved against the current folder. If the folder is not writable, Sweepr stops instead of falling back to the profile. `sw remove` and `install.ps1 -Uninstall` remove only the installation, name the data folder and never delete it.
- The active data and cache folder is always protected like a whitelist entry, even when it lies inside a cleanup target.

Sweepr is not yet available through winget or Scoop. Releases are not code-signed.

## Development

```powershell
.\scripts\test.ps1                 # Pester and Go tests
Invoke-Pester -Path .\tests        # PowerShell tests only
go test ./cmd/...                  # Go tests only
go build -o bin\analyze.exe .\cmd\analyze
go build -o bin\status.exe .\cmd\status
.\sweepr.ps1 clean --dry-run
```

Every push and pull request to `main` runs the GitHub Actions workflows **Validation** (Pester under PowerShell 5.1 and 7, Go tests, Windows builds) and **Check** on `windows-latest`, plus the gate on Linux.

The gate must be green before every merge:

```bash
./scripts/gate.sh                  # gofmt, go vet/test, Windows build, PowerShell syntax, Pester
```

On Windows (Git Bash) all Pester tests run; elsewhere the full suite runs and only the known Windows-only failures are allowed.

Rules for changes (safety, compatibility, CI, release): [docs/engineering-rules.md](docs/engineering-rules.md). Planned work: [ROADMAP.md](ROADMAP.md). The project page (GitHub Pages) lives in `site/` and is published automatically when it changes.

## License

GPL-3.0, see [LICENSE](LICENSE).
