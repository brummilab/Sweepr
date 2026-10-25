# Projektinhalt – freeMole

## Ziel

Eigene Windows-Version von Mole („freeMole“): ein freies Kommandozeilen-Tool zum Aufräumen, Deinstallieren, Optimieren, Analysieren und Überwachen von Windows-PCs, erweitert um eine App-Inspektion mit REA (Reverse Engineer Anything).

## Basis

| Quelle | Verwendung | Lizenz |
| --- | --- | --- |
| [tw93/Mole](https://github.com/tw93/Mole), Branch `windows`, Commit `fab3742`, v1.38.0 | Komplette Code-Basis (PowerShell 5.1 + Go-TUIs) | GPL-3.0 |
| [morluto/rea](https://github.com/morluto/rea), npm `rea-agents` 6.8.0 | Externes Analyse-Werkzeug für `fm inspect` (nicht eingebettet) | MIT |

## Aufbau

| Pfad | Inhalt |
| --- | --- |
| `freemole.ps1` | Einstiegspunkt, Hilfe, Menü, Befehls-Router |
| `bin/*.ps1` | Befehle: clean, uninstall, optimize, analyze, status, purge, **inspect**, history, update, remove |
| `lib/core/` | Basis (Schutzpfade, Löschen, Logging, UI, Update-Check, TUI-Binaries); **`rea.ps1`** = REA-Anbindung |
| `lib/clean/` | Bereinigungsziele (User, Caches, Dev, Apps, System) |
| `cmd/analyze`, `cmd/status` | Go-TUIs (Disk-Explorer, Systemmonitor) |
| `cmd/fm` | Go-Launcher `fm.exe` (startet `freemole.ps1`) |
| `install.ps1`, `quick-install.ps1` | Installation nach `%LOCALAPPDATA%\Programs\freemole-cli` |
| `tests/` | Pester-Tests (inkl. **`Inspect.Tests.ps1`**) |

## Entscheidungen

- **Fork statt Neuentwicklung:** Mole hat bereits ein ausgereiftes, getestetes Windows-CLI (~35.000 Zeilen). freeMole baut darauf auf.
- **Eigener Name/Befehl:** `fm`/`freemole`, eigene Ordner (`.config\freemole`, `.cache\freemole`, `Programs\freemole-cli`) und eigene Update-Quelle (`brummilab/freeMole`, `main`). So kein Konflikt mit einer Original-Installation und keine Updates vom Original.
- **Interne Namen unverändert:** PowerShell-Funktionen `*-Mole*` und Umgebungsvariablen `MOLE_*`/`MO_NO_OPLOG` bleiben, damit Upstream-Fixes leicht übernommen werden können.
- **REA nur lesend und extern:** `fm inspect` nutzt ausschließlich statische REA-Analysen (Ordner-, Signatur-, Import-, .NET-Inspektion). REA wird über `rea` im PATH oder `npx -y rea-agents@latest` gestartet; `MOLE_REA_COMMAND` überschreibt den Pfad.
- **Übersetzte READMEs entfernt:** README nur auf Deutsch, weil die Upstream-Übersetzungen das Original beschreiben.
- **Marke:** Mole-Markenrichtlinie empfiehlt für Forks einen Namen ohne „Mole“. Für private/interne Nutzung beibehalten; vor einer öffentlichen Verbreitung umbenennen (siehe NOTICE.md).

## Offene Punkte

- [ ] Auf echtem Windows 10/11 testen (Pester-Suite + manuelle Läufe von `fm clean --dry-run`, `fm uninstall --dry-run`, `fm inspect`)
- [ ] Release-Binaries (`analyze.exe`, `status.exe`, `fm.exe`) über GitHub Releases veröffentlichen, damit die Installation ohne Go klappt (Workflow `release-windows.yml` anpassen, Signatur-Secrets)
- [ ] winget/Scoop-Pakete (`packaging/`) für freeMole einrichten oder entfernen
- [ ] Optional: `fm inspect` direkt im Uninstall-Menü anbieten (Signierer vor dem Deinstallieren anzeigen)
- [ ] Optional: eigenes Logo/Screenshots statt der Upstream-Bilder in `docs/img/`

## Änderungsprotokoll

### 2026-10-25 – Erstversion

- Mole-Windows-CLI v1.38.0 übernommen
- Umbenannt: `mo` → `fm`, `mole.ps1` → `freemole.ps1`, `cmd/mo` → `cmd/fm`, Go-Modul `github.com/brummilab/freemole`, Banner/Hilfe/Meldungen „freeMole“
- Eigene Installations-, Konfigurations- und Cache-Ordner; Update/Installation aus `brummilab/freeMole` (`main`)
- Neuer Befehl `fm inspect` (REA-Anbindung) mit `--deep`, `--json`, `--setup`
- Neue Tests `tests/Inspect.Tests.ps1` (25 Fälle, unter Linux/pwsh 7.4 grün)
- README (Deutsch), NOTICE.md, Projektinhalt.md
- Verifikation in der Linux-Sandbox: `go vet`/`go test ./cmd/...` grün, `GOOS=windows go build ./cmd/...` ok, Pester-Gesamtlauf ohne neue Fehler gegenüber dem unveränderten Upstream (die übrigen Fehlschläge benötigen echtes Windows), `fm inspect` live gegen REA 6.8.0 mit einer signierten Microsoft-EXE geprüft
