<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/img/logo-wordmark-dark.svg">
    <img src="docs/img/logo-wordmark-light.svg" alt="Sweepr" width="480">
  </picture>
  <p><b>Windows-PC aufräumen, Apps deinstallieren, optimieren, Speicher analysieren, System überwachen – und Apps mit REA untersuchen. Freies Open-Source-CLI.</b></p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
</div>

## Funktionen

- **Deep Clean** (`sw clean`): Temp-Dateien, Caches, Logs und Browser-Reste entfernen
- **Deinstallieren** (`sw uninstall`): Apps mit ihrem eigenen Uninstaller entfernen und Reste-Ordner aufräumen
- **Optimieren** (`sw optimize`): DNS leeren, Systemlaufwerk optimieren, Datenträgerzustand prüfen
- **Speicheranalyse** (`sw analyze`): interaktiver Disk-Explorer (TUI), große Dateien finden
- **Live-Monitoring** (`sw status`): CPU, RAM, Disk, Netzwerk, Prozesse in Echtzeit
- **Projekt-Purge** (`sw purge`): alte Build-Artefakte (`node_modules`, `bin/obj`, …) entfernen
- **App-Inspektion mit REA** (`sw inspect`): nur lesend in eine installierte App schauen – Laufzeit (Electron, .NET, Unity, Godot, Unreal), Code-Signatur, importierte DLLs, .NET-Metadaten

## Schnellstart

Sweepr läuft auf Windows 10 und 11 mit dem eingebauten Windows PowerShell 5.1. Die Script-Installation braucht **Git** und **Go** (für die beiden TUI-Tools `analyze.exe` und `status.exe`, solange dieses Repo keine Release-Binaries veröffentlicht). Installiert wird nach `%LOCALAPPDATA%\Programs\sweepr-cli`; `sw` und `sweepr` landen im PATH.

```powershell
iwr -useb https://raw.githubusercontent.com/brummilab/sweepr/main/quick-install.ps1 | iex
```

Oder den Code vorher prüfen und lokal installieren (behält `.git`, damit `sw update` funktioniert):

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\sweepr-cli"
git clone https://github.com/brummilab/sweepr.git $installDir
powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
```

`-CreateShortcut` legt zusätzlich einen Startmenü-Eintrag an. Entfernen mit `sw remove`.

## Befehle

```powershell
sw                           # Interaktives Menü
sw clean                     # Aufräumen
sw uninstall                 # Apps + Reste entfernen
sw optimize                  # Caches & Dienste auffrischen
sw analyze                   # Disk-Explorer
sw status                    # Live-Systemmonitor
sw purge                     # Projekt-Build-Artefakte entfernen
sw inspect <App>             # App mit REA untersuchen (nur lesend)

sw update                    # Sweepr aktualisieren (git pull vom main-Branch)
sw remove                    # Sweepr vom PC entfernen
sw --help                    # Hilfe
sw --version                 # Version
```

**Erst ansehen, dann löschen**

```powershell
sw clean --dry-run
sw uninstall --dry-run
sw optimize --dry-run
sw purge --dry-run
sw history                   # Was wurde wann entfernt?
sw history --json

sw clean --dry-run --debug   # Vorschau + Detail-Log
sw clean --whitelist         # Geschützte Pfade verwalten
sw clean --system            # Inkl. System-Bereinigung (als Administrator)
sw purge --paths             # Projekt-Suchordner festlegen
sw analyze D:\               # Anderes Laufwerk analysieren
sw uninstall --list          # Installierte Apps auflisten (JSON, wenn umgeleitet)
sw analyze --json D:\        # Disk-Report als JSON
```

## App-Inspektion mit REA (`sw inspect`)

[REA](https://github.com/morluto/rea) ist ein lokales Reverse-Engineering-Toolkit (CLI + MCP-Server). Sweepr nutzt davon die **statischen, nur lesenden** Analysen, um vor einer Deinstallation oder bei einer unbekannten Software schnell zu sehen, womit man es zu tun hat.

**Voraussetzung:** Node.js 22 oder neuer. Entweder REA global installieren (`npm install --global rea-agents`) oder nichts tun – Sweepr startet REA dann automatisch über `npx -y rea-agents@latest` (der erste Lauf lädt REA herunter).

```powershell
sw inspect Slack                          # App über ihren Namen in der Registry finden
sw inspect "C:\Program Files\App"         # Installationsordner direkt angeben
sw inspect .\tool.exe                     # Einzelne Datei (Signatur)
sw inspect Slack --deep                   # + importierte DLLs und .NET-Metadaten
sw inspect Slack --json                   # Zusammenfassung als JSON
sw inspect --setup                        # REA als MCP-Server bei MCP-Clients registrieren
```

Beispielausgabe:

```text
App
  Path:        C:\Program Files\App
  Executable:  C:\Program Files\App\App.exe
  Arch:        amd64
  Runtime:     electron (inferred), dotnet (derived)
  Signature:   Microsoft Corporation (issuer: Microsoft Code Signing PCA 2024)
  .NET:        dotnet-framework, NuGet 7.9.0.83, .NETFramework,Version=v4.7.2
  Imports:     1 DLLs
               mscoree.dll

  Go deeper with REA:
    rea analyze-javascript-application "C:\Program Files\App\resources\app.asar"
```

Was dabei passiert:

| Schritt | REA-Befehl | Ergebnis |
| --- | --- | --- |
| Ordner untersuchen | `rea inspect-desktop-application` | Laufzeit-Kandidaten (Electron, .NET, Unity, Godot, Unreal, GameMaker) und vorgeschlagene nächste Analysen |
| Signatur lesen | `rea inspect-pe-certificates` | Signierer und Aussteller des Authenticode-Zertifikats der Haupt-EXE |
| `--deep`: Importe | `rea inspect-pe-imports` | Liste der importierten DLLs |
| `--deep` oder .NET erkannt | `rea inspect-managed-artifact` | .NET-Laufzeit, Assembly-Name/-Version, Ziel-Framework |

Grenzen: REA liest nur Header und Metadaten, startet die App nicht und **prüft Signaturen nicht kryptografisch** (dafür `Get-AuthenticodeSignature` verwenden). Eine fehlende eingebettete Signatur heißt nicht zwingend „unsigniert“ (Katalog-Signaturen). `sw inspect` löscht oder ändert nie etwas.

Einen eigenen REA-Pfad kann man mit der Umgebungsvariable `SWEEPR_REA_COMMAND` setzen.

## Sicherheit

Sweepr kann Dateien löschen, deshalb werden Pfade validiert und System- sowie Profilordner geschützt. `uninstall`, `purge` und `remove` fragen vor dem Entfernen nach. Was nicht nachweislich sicher ist, wird übersprungen.

- `clean`, `uninstall` und `purge` zuerst mit `--dry-run` ansehen, bei Bedarf `--debug` dazu
- `clean` und `purge` löschen endgültig; verifizierte `uninstall`-Reste und in `sw analyze` gelöschte Dateien gehen in den Papierkorb
- Als normaler Benutzer ausführen; System-Schritte laufen nur in einer Administrator-PowerShell
- Pfade schützen mit `sw clean --whitelist`
- Aktivitäten werden in `%USERPROFILE%\.config\sweepr\operations.log` protokolliert (`sw history`; abschalten mit `SWEEPR_NO_OPLOG=1`)
- `C:\Windows`, `C:\Program Files`, Windows-Defender-Ordner und das Profil-Stammverzeichnis werden nie angefasst

Sicherheitslücken bitte privat über [GitHub Security Advisories](https://github.com/brummilab/sweepr/security/advisories/new) melden, nicht als öffentliches Issue. Details: [SECURITY.md](SECURITY.md).

## Ordner

| | Pfad |
| --- | --- |
| Befehl | `sw`, `sweepr` |
| Installation | `%LOCALAPPDATA%\Programs\sweepr-cli` |
| Konfiguration und Protokoll | `%USERPROFILE%\.config\sweepr` |
| Cache (TUI-Binaries, Scan-Caches) | `%USERPROFILE%\.cache\sweepr` |
| Update-Quelle | `brummilab/sweepr`, Branch `main` |

Die Vorlagen für winget/Scoop (`packaging/`) und die Release-/Signatur-Skripte (`scripts/`) sind vorbereitet, aber noch nicht veröffentlicht.

## Entwicklung

```powershell
.\scripts\test.ps1                 # Pester- und Go-Tests
Invoke-Pester -Path .\tests        # Nur PowerShell-Tests
go test ./cmd/...                  # Nur Go-Tests
go build -o bin\analyze.exe .\cmd\analyze
go build -o bin\status.exe .\cmd\status
.\sweepr.ps1 clean --dry-run
```

Jeder Push und jeder Pull-Request auf `main` startet die GitHub-Actions-Workflows **Validation** (Pester unter PowerShell 5.1 und 7, Go-Tests, Windows-Builds) und **Check** auf `windows-latest`, dazu das Gate unter Linux.

### Gate

Vor jedem Merge muss das Gate grün sein:

```bash
./scripts/gate.sh                  # gofmt, go vet/test, Windows-Build, PowerShell-Syntax, Pester
```

Unter Windows (Git Bash) laufen dabei alle Pester-Tests, sonst die plattformneutralen.

Projektübersicht und Änderungsprotokoll: [Projektinhalt.md](Projektinhalt.md).

## Lizenz

GPL-3.0 – siehe [LICENSE](LICENSE). Lizenz- und Drittanbieter-Hinweise: [NOTICE.md](NOTICE.md).
