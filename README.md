<div align="center">
  <h1>freeMole</h1>
  <p><b>Windows-PC aufräumen, Apps deinstallieren, optimieren, Speicher analysieren, System überwachen – und Apps mit REA untersuchen. Freies Open-Source-CLI.</b></p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
</div>

<p align="center">
  <img src="./docs/img/mole-windows.png" alt="freeMole-Menü (Screenshot der Upstream-Version)" width="736" />
</p>

> **freeMole** ist ein eigenständiger Fork des Windows-CLI von [tw93/Mole](https://github.com/tw93/Mole/tree/windows) (GPL-3.0), erweitert um eine Anbindung an [REA – Reverse Engineer Anything](https://github.com/morluto/rea) (MIT).
> freeMole ist **nicht** mit dem Mole-Projekt oder mit „Mole for Windows“ (mole.fit) verbunden oder von diesen unterstützt. Details: [NOTICE.md](NOTICE.md).

## Funktionen

- **Deep Clean** (`fm clean`): Temp-Dateien, Caches, Logs und Browser-Reste entfernen
- **Deinstallieren** (`fm uninstall`): Apps mit ihrem eigenen Uninstaller entfernen und Reste-Ordner aufräumen
- **Optimieren** (`fm optimize`): DNS leeren, Systemlaufwerk optimieren, Datenträgerzustand prüfen
- **Speicheranalyse** (`fm analyze`): interaktiver Disk-Explorer (TUI), große Dateien finden
- **Live-Monitoring** (`fm status`): CPU, RAM, Disk, Netzwerk, Prozesse in Echtzeit
- **Projekt-Purge** (`fm purge`): alte Build-Artefakte (`node_modules`, `bin/obj`, …) entfernen
- **NEU – App-Inspektion mit REA** (`fm inspect`): nur lesend in eine installierte App schauen – Laufzeit (Electron, .NET, Unity, Godot, Unreal), Code-Signatur, importierte DLLs, .NET-Metadaten

## Schnellstart

freeMole läuft auf Windows 10 und 11 mit dem eingebauten Windows PowerShell 5.1. Die Script-Installation braucht **Git** und **Go** (für die beiden TUI-Tools `analyze.exe` und `status.exe`, solange dieses Repo keine Release-Binaries veröffentlicht). Installiert wird nach `%LOCALAPPDATA%\Programs\freemole-cli`; `fm` und `freemole` landen im PATH.

```powershell
iwr -useb https://raw.githubusercontent.com/brummilab/freeMole/main/quick-install.ps1 | iex
```

Oder den Code vorher prüfen und lokal installieren (behält `.git`, damit `fm update` funktioniert):

```powershell
$installDir = "$env:LOCALAPPDATA\Programs\freemole-cli"
git clone https://github.com/brummilab/freeMole.git $installDir
powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
```

`-CreateShortcut` legt zusätzlich einen Startmenü-Eintrag an. Entfernen mit `fm remove`.

freeMole verwendet eigene Ordner und kollidiert daher nicht mit einer parallel installierten Original-Mole-Version (`mo`).

## Befehle

```powershell
fm                           # Interaktives Menü
fm clean                     # Aufräumen
fm uninstall                 # Apps + Reste entfernen
fm optimize                  # Caches & Dienste auffrischen
fm analyze                   # Disk-Explorer
fm status                    # Live-Systemmonitor
fm purge                     # Projekt-Build-Artefakte entfernen
fm inspect <App>             # App mit REA untersuchen (nur lesend)

fm update                    # freeMole aktualisieren (git pull vom main-Branch)
fm remove                    # freeMole vom PC entfernen
fm --help                    # Hilfe
fm --version                 # Version
```

**Erst ansehen, dann löschen**

```powershell
fm clean --dry-run
fm uninstall --dry-run
fm optimize --dry-run
fm purge --dry-run
fm history                   # Was wurde wann entfernt?
fm history --json

fm clean --dry-run --debug   # Vorschau + Detail-Log
fm clean --whitelist         # Geschützte Pfade verwalten
fm clean --system            # Inkl. System-Bereinigung (als Administrator)
fm purge --paths             # Projekt-Suchordner festlegen
fm analyze D:\               # Anderes Laufwerk analysieren
fm uninstall --list          # Installierte Apps auflisten (JSON, wenn umgeleitet)
fm analyze --json D:\        # Disk-Report als JSON
```

## App-Inspektion mit REA (`fm inspect`)

[REA](https://github.com/morluto/rea) ist ein lokales Reverse-Engineering-Toolkit (CLI + MCP-Server). freeMole nutzt davon die **statischen, nur lesenden** Analysen, um vor einer Deinstallation oder bei einer unbekannten Software schnell zu sehen, womit man es zu tun hat.

**Voraussetzung:** Node.js 22 oder neuer. Entweder REA global installieren (`npm install --global rea-agents`) oder nichts tun – freeMole startet REA dann automatisch über `npx -y rea-agents@latest` (der erste Lauf lädt REA herunter).

```powershell
fm inspect Slack                          # App über ihren Namen in der Registry finden
fm inspect "C:\Program Files\App"         # Installationsordner direkt angeben
fm inspect .\tool.exe                     # Einzelne Datei (Signatur)
fm inspect Slack --deep                   # + importierte DLLs und .NET-Metadaten
fm inspect Slack --json                   # Zusammenfassung als JSON
fm inspect --setup                        # REA als MCP-Server bei MCP-Clients registrieren
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

Grenzen: REA liest nur Header und Metadaten, startet die App nicht und **prüft Signaturen nicht kryptografisch** (dafür `Get-AuthenticodeSignature` verwenden). Eine fehlende eingebettete Signatur heißt nicht zwingend „unsigniert“ (Katalog-Signaturen). `fm inspect` löscht oder ändert nie etwas.

Einen eigenen REA-Pfad kann man mit der Umgebungsvariable `MOLE_REA_COMMAND` setzen.

## Sicherheit

freeMole kann Dateien löschen, deshalb werden Pfade validiert und System- sowie Profilordner geschützt. `uninstall`, `purge` und `remove` fragen vor dem Entfernen nach. Was nicht nachweislich sicher ist, wird übersprungen.

- `clean`, `uninstall` und `purge` zuerst mit `--dry-run` ansehen, bei Bedarf `--debug` dazu
- `clean` und `purge` löschen endgültig; verifizierte `uninstall`-Reste und in `fm analyze` gelöschte Dateien gehen in den Papierkorb
- Als normaler Benutzer ausführen; System-Schritte laufen nur in einer Administrator-PowerShell
- Pfade schützen mit `fm clean --whitelist`
- Aktivitäten werden in `%USERPROFILE%\.config\freemole\operations.log` protokolliert (`fm history`; abschalten mit `MO_NO_OPLOG=1`)
- `C:\Windows`, `C:\Program Files`, Windows-Defender-Ordner und das Profil-Stammverzeichnis werden nie angefasst

Sicherheitslücken bitte privat über [GitHub Security Advisories](https://github.com/brummilab/freeMole/security/advisories/new) melden, nicht als öffentliches Issue. Siehe [SECURITY.md](SECURITY.md) und [SECURITY_AUDIT.md](SECURITY_AUDIT.md) (aus dem Upstream übernommen).

## Ordner und Unterschiede zum Original

| | Original Mole CLI | freeMole |
| --- | --- | --- |
| Befehl | `mo`, `mole` | `fm`, `freemole` |
| Installationsordner | `%LOCALAPPDATA%\Programs\mole-cli` | `%LOCALAPPDATA%\Programs\freemole-cli` |
| Konfiguration | `%USERPROFILE%\.config\mole` | `%USERPROFILE%\.config\freemole` |
| Cache | `%USERPROFILE%\.cache\mole` | `%USERPROFILE%\.cache\freemole` |
| Update-Quelle | `tw93/Mole`, Branch `windows` | `brummilab/freeMole`, Branch `main` |
| REA-Inspektion | – | `fm inspect` |

Interne Umgebungsvariablen (`MOLE_DRY_RUN`, `MO_NO_OPLOG`, …) und PowerShell-Funktionsnamen (`*-Mole*`) sind bewusst unverändert geblieben, damit Upstream-Fixes leicht übernommen werden können.

Die Pakete für winget/Scoop sowie die Release-/Signatur-Skripte unter `packaging/` und `scripts/` stammen aus dem Upstream und sind für freeMole noch nicht eingerichtet.

## Entwicklung

```powershell
.\scripts\test.ps1                 # Pester- und Go-Tests
Invoke-Pester -Path .\tests        # Nur PowerShell-Tests
go test ./cmd/...                  # Nur Go-Tests
go build -o bin\analyze.exe .\cmd\analyze
go build -o bin\status.exe .\cmd\status
.\freemole.ps1 clean --dry-run
```

Jeder Push und jeder Pull-Request auf `main` startet die GitHub-Actions-Workflows **Validation** (Pester unter PowerShell 5.1 und 7, Go-Tests, Windows-Builds) und **Check** auf `windows-latest`.

Projektübersicht und Änderungsprotokoll: [Projektinhalt.md](Projektinhalt.md).

## Lizenz

GPL-3.0, wie das Original – siehe [LICENSE](LICENSE). Herkunft und Drittanbieter-Hinweise: [NOTICE.md](NOTICE.md).
