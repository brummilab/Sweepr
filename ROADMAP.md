# Roadmap

[Deutsch](ROADMAP.de.md) · **English**

Planned work. The order may change. Please report wishes and bugs as an [issue](https://github.com/brummilab/Sweepr/issues).

## Done

- **Core features:** `sw clean`, `sw uninstall`, `sw optimize`, `sw purge`, disk explorer `sw analyze` and system monitor
  `sw status`
- **Safety:** protected system and profile folders, whitelist, `--dry-run` for everything that deletes, Recycle Bin for
  uninstall leftovers, log `operations.log` with `sw history`
- **Portable version** (runs from a USB stick, for example; data stays in the program folder) and **installation with component selection**
- **Debloat Windows** (`sw features`): reviewed list of preinstalled apps and optional features, with `--restore` to bring
  them back
- **Check a PC once** (`sw check`): read-only, with an HTML report, no installation
- Launcher `sw.exe`, notice about new versions

## Next

- **New release** with prebuilt `analyze` and `status` tools, so both run without Go again
- **Fix known bugs:** release workflow, paths with special characters, `sw analyze` with OneDrive folders, smaller bugs from
  the last review
- **Rework the core:** rebuild history (`sw history`), protection and deletion logic, log and command dispatch, each with
  tests first
- **Acceptance on real Windows 10 and 11 PCs** (installation, portable, `sw features`, `sw check`)

## After that

- Commands `clean`, `purge`, `optimize`, `uninstall` and installation and update on the reworked core
- Leaner `sw analyze` and `sw status`
- Polish for `sw features` and the `sw check` report, one health check for all commands
- Clean up leftovers of older installations on update
- All Go and PowerShell tests fully in CI

## Later

- Installation through **winget** and **Scoop**
- Introduction on Reddit
