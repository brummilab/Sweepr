<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/img/logo-wordmark-dark.svg">
    <img src="docs/img/logo-wordmark-light.svg" alt="Sweepr" width="480">
  </picture>
  <p><b>Windows-PC aufräumen, Apps deinstallieren, optimieren, Speicher analysieren, System überwachen. Freies Open-Source-CLI.</b></p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
</div>

## Funktionen

- **Deep Clean** (`sw clean`): Temp-Dateien, Caches, Logs und Browser-Reste entfernen
- **Deinstallieren** (`sw uninstall`): Apps mit ihrem eigenen Uninstaller entfernen und Reste-Ordner aufräumen
- **Optimieren** (`sw optimize`): DNS leeren, Systemlaufwerk optimieren, Datenträgerzustand prüfen
- **Speicheranalyse** (`sw analyze`): interaktiver Disk-Explorer (TUI), große Dateien finden
- **Live-Monitoring** (`sw status`): CPU, RAM, Disk, Netzwerk, Prozesse in Echtzeit
- **Projekt-Purge** (`sw purge`): alte Build-Artefakte (`node_modules`, `bin/obj`, …) entfernen
- **Windows entschlacken** (`sw features`): vorinstallierte Microsoft-Apps und optionale Windows-Features aus einer geprüften Liste entfernen bzw. abschalten

## Schnellstart

Sweepr läuft auf Windows 10 und 11 mit dem eingebauten Windows PowerShell 5.1. Die Release-Dateien (z. B. Release `V0.1.0-windows`) liegen unter [github.com/brummilab/Sweepr/releases](https://github.com/brummilab/Sweepr/releases):

| Datei | Zweck |
| --- | --- |
| `sweepr-<version>-x64.zip` | Programmdateien mit `install.ps1`, `sw.exe` und den fertigen TUI-Tools; normale Installation |
| `sweepr-<version>-x64-portable.zip` | dasselbe plus Markierungsdatei `sweepr.portable`; läuft ohne Installation, siehe [Portable Version](#portable-version) |
| `analyze-windows-x64.exe`, `status-windows-x64.exe` | die beiden TUI-Tools einzeln; Sweepr lädt sie bei Bedarf selbst nach und prüft sie gegen `SHA256SUMS.txt` |
| `SHA256SUMS.txt` | SHA-256-Prüfsummen der beiden ZIPs und der beiden TUI-Tools |

Drei Wege, Sweepr zu bekommen:

1. **Portable ZIP** – nichts installieren, Ordner entpacken und `sw.exe` starten ([Details](#portable-version)).
2. **Install-ZIP** – `sweepr-<version>-x64.zip` entpacken und darin den Installer starten. Braucht weder Git noch Go, weil die TUI-Tools im ZIP liegen:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddToPath
   ```

   Installiert wird nach `%LOCALAPPDATA%\Programs\sweepr-cli`. Eine so installierte Kopie hat kein `.git`; `sw update` kann sie nicht aktualisieren und verweist auf eine Neuinstallation (Ordner entfernen oder umbenennen, dann Quick-Install oder ein neues Release-ZIP mit anderem `-InstallDir`).
3. **Quick-Install aus dem Quellcode** – klont `main` nach `%LOCALAPPDATA%\Programs\sweepr-cli` und startet den Installer. Braucht **Git**. Für `analyze.exe` und `status.exe` nutzt der Installer die geprüfte Release-Binärdatei nur, wenn der geklonte Quellstand dem Release-Tag entspricht; sonst baut er sie mit **Go**. Ohne Go bleibt das jeweilige Tool zunächst aus (der Installer warnt).

   ```powershell
   iwr -useb https://raw.githubusercontent.com/brummilab/Sweepr/main/quick-install.ps1 | iex
   ```

   Oder den Code vorher prüfen und lokal installieren (behält `.git`, damit `sw update` funktioniert):

   ```powershell
   $installDir = "$env:LOCALAPPDATA\Programs\sweepr-cli"
   git clone https://github.com/brummilab/Sweepr.git $installDir
   powershell -ExecutionPolicy Bypass -File "$installDir\install.ps1" -InstallDir $installDir -AddToPath
   ```

Bei Install-ZIP und Quick-Install landen `sw` und `sweepr` im Benutzer-PATH, wenn die Komponente `path` gewählt ist (siehe [Installation mit Komponentenauswahl](#installation-mit-komponentenauswahl)). Ein Startmenü-Eintrag ist die Komponente `shortcut`. Entfernen mit `sw remove`.

Prüfsumme eines Downloads vergleichen:

```powershell
Get-FileHash .\sweepr-<version>-x64.zip -Algorithm SHA256   # mit SHA256SUMS.txt vergleichen
```

## Installation mit Komponentenauswahl

`install.ps1` kennt vier wählbare Komponenten; der Kern (Programmdateien, `sw.cmd`, `sweepr.cmd`) wird immer installiert:

| Komponente | Wirkung |
| --- | --- |
| `path` | Installationsordner in den Benutzer-PATH eintragen |
| `shortcut` | Startmenü-Eintrag „Sweepr CLI“ anlegen |
| `analyze` | `analyze.exe` bei der Installation bereitstellen |
| `status` | `status.exe` bei der Installation bereitstellen |

Die Auswahl von `analyze` und `status` wirkt bei Quell-Installationen: Nicht gewählte TUI-Tools werden nicht vorab bereitgestellt, sondern beim ersten `sw analyze` bzw. `sw status` nachgeladen oder gebaut. Install-ZIP und portables ZIP bringen beide Tools in `bin\` schon mit; der Installer kopiert sie in jedem Fall mit.

Die Auswahl entscheidet die erste zutreffende Regel:

1. `-Components path,shortcut,analyze,status` (kommagetrennt, Groß-/Kleinschreibung egal): genau diese Komponenten.
2. Umgebungsvariable `SWEEPR_COMPONENTS` (gleiches Format): genau diese Komponenten. Bei Regel 1 und 2 zählen `-AddToPath` und `-CreateShortcut` nicht.
3. Echte Konsole (Ein- und Ausgabe nicht umgeleitet) und kein `-NoPrompt`: ein Menü. Pfeil hoch/runter bewegt, Leertaste schaltet um, Enter installiert, Esc oder Q bricht ab (Meldung „Installation cancelled“, nichts wird installiert, Exit-Code 3).
4. Sonst der Standard: `analyze` und `status`, dazu `path` mit `-AddToPath` und `shortcut` mit `-CreateShortcut`.

Das Menü startet mit demselben Standard wie Regel 4 vorausgewählt. Weil `quick-install.ps1` den Installer mit `-AddToPath` aufruft, sind dort `path`, `analyze` und `status` vorausgewählt. Ein unbekannter Komponentenname bricht mit Exit-Code 2 ab, bevor etwas kopiert wird.

```powershell
# Ohne Menü: nur PATH und das Status-Tool
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Components path,status -NoPrompt

# Dasselbe über die Umgebung (z. B. für Skripte)
$env:SWEEPR_COMPONENTS = "path,status"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Die Auswahl wird nicht gespeichert. `sw update` startet den Installer mit `-NoPrompt` (nie ein Menü) und behält den PATH-Eintrag, wenn der Ordner schon im Benutzer-PATH steht. Bricht man in `quick-install.ps1` das Menü ab, meldet es „Installation cancelled“ (Exit-Code 1) und entfernt den in diesem Lauf frisch geklonten Ordner wieder; ein schon vorhandener Ordner wird nicht gelöscht. Eine vorhandene Quell-Installation wurde allerdings schon vor dem Installer per `git fetch` und `git pull --ff-only` aktualisiert.

## Portable Version

Die portable Version braucht keine Installation. Sie legt ihre eigenen Dateien weder im Benutzerprofil ab noch ändert sie den PATH oder das Startmenü.

1. `sweepr-<version>-x64-portable.zip` aus den [Releases](https://github.com/brummilab/Sweepr/releases) in einen beschreibbaren Ordner entpacken (z. B. auf einen USB-Stick).
2. `sw.exe` in diesem Ordner starten (`.\sw.exe`, `.\sw.exe clean --dry-run`, …). Es startet `sweepr.ps1` aus demselben Ordner.

Erkannt wird der Portable-Modus an der Datei `sweepr.portable` neben `sweepr.ps1`. Alle Sweepr-eigenen Dateien liegen dann im Unterordner `data` des Programmordners: Einstellungen, Whitelist und das Protokoll `operations.log` in `data\config`, Zwischenspeicher (Update-Prüfung, App-Scan-Cache) in `data\cache`. Das Protokoll wandert also mit dem Ordner; `sw history` zeigt es an, `SWEEPR_NO_OPLOG=1` schaltet es ab. Die Update-Prüfung läuft wie sonst und weist auf neue Versionen hin.

- **Update:** `sw update` aktualisiert nichts, sondern nennt den Download (`sweepr-<version>-x64-portable.zip`) und beendet sich mit Exit-Code 1. Neues ZIP laden, die Programmdateien ersetzen und den Ordner `data` behalten.
- **Entfernen:** `sw remove` löscht nichts und beendet sich mit Exit-Code 1. Zum Entfernen den Ordner selbst löschen; die eigenen Daten liegen in `data`. `install.ps1 -Uninstall` verweigert einen portablen Ordner ebenfalls.
- **Nicht beschreibbarer Ort:** Kann Sweepr den Datenordner nicht anlegen oder beschreiben, endet es mit der Meldung `Sweepr data folder is not writable: <Pfad>. Sweepr does not fall back to your user profile.` und Exit-Code 1. Es weicht nie ins Benutzerprofil aus.
- **Anderer Datenordner:** Mit der Umgebungsvariable `SWEEPR_DATA_DIR` (auch ohne Portable-ZIP nutzbar) legt man den Datenordner selbst fest; siehe [Ordner](#ordner). Sie hat Vorrang vor `data`.

Die Bereinigungsziele von `sw clean` & Co. sind unabhängig davon weiterhin die Ordner des Windows-Profils; portabel sind nur Sweeprs eigene Daten.

## Befehle

```powershell
sw                           # Interaktives Menü
sw clean                     # Aufräumen
sw uninstall                 # Apps + Reste entfernen
sw optimize                  # Caches & Dienste auffrischen
sw analyze                   # Disk-Explorer
sw status                    # Live-Systemmonitor
sw purge                     # Projekt-Build-Artefakte entfernen
sw features                  # Vorinstallierte Apps / Windows-Features entfernen

sw update                    # Quell-Installation aktualisieren (git pull vom main-Branch)
sw remove                    # Sweepr vom PC entfernen (portabel: löscht nichts)
sw --help                    # Hilfe
sw --version                 # Version
```

**Erst ansehen, dann löschen**

```powershell
sw clean --dry-run
sw uninstall --dry-run
sw optimize --dry-run
sw purge --dry-run
sw features --dry-run        # Zeigt die exakten Befehle, ändert nichts
sw features --list           # Nur auflisten (JSON, wenn umgeleitet)
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

## Windows entschlacken (`sw features`)

`sw features` bietet nur Einträge aus einer **geprüften Liste** an (vorinstallierte Microsoft-Apps wie Wetter, News, Solitaire, Xbox-Apps sowie optionale Features wie PowerShell 2.0, XPS-Dienste, Internet Explorer 11, Windows Media Player). Was Windows zum Laufen braucht (Store, App Installer, Sicherheit, Edge, WebView2, Laufzeiten, Hyper-V, WSL, SMB, .NET), wird nie angeboten.

- Menü mit Pfeiltasten, Leertaste wählt, Enter bestätigt, Esc/Q bricht ab. **Nichts ist vorausgewählt**; vor dem Entfernen fragt Sweepr `(y/N)`.
- Apps werden für den aktuellen Benutzer entfernt (ohne Administrator). `--all-users-future` entfernt sie zusätzlich für künftige Benutzer (Administrator nötig).
- Optionale Features werden nur abgeschaltet (nicht gelöscht) und brauchen eine Administrator-PowerShell. Sweepr fordert keine Rechte an und startet nie neu; braucht Windows einen Neustart, steht am Ende „Restart Windows to finish.“
- Direkt vor dem Entfernen wird jeder Eintrag noch einmal geprüft; jede Aktion steht im Protokoll (`sw history`).
- Rückgängig: Apps aus dem Microsoft Store neu installieren, Features unter „Windows-Features aktivieren oder deaktivieren“ wieder einschalten. `sw features --restore` ist in Arbeit.

## Sicherheit

Sweepr kann Dateien löschen, deshalb werden Pfade validiert und System- sowie Profilordner geschützt. `uninstall`, `purge` und `remove` fragen vor dem Entfernen nach. Was nicht nachweislich sicher ist, wird übersprungen.

- `clean`, `uninstall` und `purge` zuerst mit `--dry-run` ansehen, bei Bedarf `--debug` dazu
- `clean` und `purge` löschen endgültig; verifizierte `uninstall`-Reste und in `sw analyze` gelöschte Dateien gehen in den Papierkorb
- Als normaler Benutzer ausführen; System-Schritte laufen nur in einer Administrator-PowerShell
- Pfade schützen mit `sw clean --whitelist`
- Aktivitäten werden in `%USERPROFILE%\.config\sweepr\operations.log` protokolliert (portabel: `data\config\operations.log`; `sw history`; abschalten mit `SWEEPR_NO_OPLOG=1`)
- `C:\Windows`, `C:\Program Files`, Windows-Defender-Ordner und das Profil-Stammverzeichnis werden nie angefasst

Sicherheitslücken bitte privat über [GitHub Security Advisories](https://github.com/brummilab/Sweepr/security/advisories/new) melden, nicht als öffentliches Issue. Details: [SECURITY.md](SECURITY.md).

## Ordner

| | Installiert (Standard) | Portable | mit `SWEEPR_DATA_DIR=<Ordner>` |
| --- | --- | --- | --- |
| Befehl | `sw`, `sweepr` | `sw.exe` im Programmordner | wie die Installation |
| Programme (inkl. TUI-Tools in `bin\`) | `%LOCALAPPDATA%\Programs\sweepr-cli` | der entpackte Ordner | wie die Installation |
| Konfiguration und Protokoll | `%USERPROFILE%\.config\sweepr` | `<Programmordner>\data\config` | `<Ordner>\config` |
| Cache | `%USERPROFILE%\.cache\sweepr` | `<Programmordner>\data\cache` | `<Ordner>\cache` |
| Update-Quelle | `brummilab/Sweepr`, Branch `main` (Quell-Installation) | neues ZIP aus den Releases | wie die Installation |

- **Konfiguration und Protokoll** enthalten Whitelist (`whitelist.txt`), `operations.log`, die Suchordner von `sw purge` (`purge_paths.txt`), die Liste des letzten `sw clean` (`clean-list.txt`), das Debug-Protokoll (`--debug`) und die Einstellungen von `sw status`.
- **Cache** enthält den App-Scan-Cache von `sw uninstall` und die Daten der Update-Prüfung. Die TUI-Tools `analyze.exe` und `status.exe` liegen nicht hier, sondern im Programmordner unter `bin\`.
- **`SWEEPR_DATA_DIR`** gilt vor dem Portable-Modus und vor dem Profil. Ein relativer Pfad wird gegen das aktuelle Verzeichnis aufgelöst. Ist der Ordner nicht beschreibbar, bricht Sweepr ab, statt ins Profil auszuweichen. `sw remove` und `install.ps1 -Uninstall` entfernen nur die Installation, nennen den Datenordner und löschen ihn nie.
- Der aktive Daten- und Cache-Ordner steht automatisch unter dem Schutz der Whitelist, auch wenn er in einem Bereinigungsziel liegt.

Die Vorlagen für winget/Scoop (`packaging/`) sind vorbereitet, aber noch nicht veröffentlicht. Die Releases sind noch nicht code-signiert.

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

Vor jedem Merge muss das Gate grün sein:

```bash
./scripts/gate.sh                  # gofmt, go vet/test, Windows-Build, PowerShell-Syntax, Pester
```

Unter Windows (Git Bash) laufen dabei alle Pester-Tests, sonst die plattformneutralen.

Projektübersicht und Änderungsprotokoll: [Projektinhalt.md](Projektinhalt.md).

## Lizenz

GPL-3.0 – siehe [LICENSE](LICENSE). Lizenz- und Drittanbieter-Hinweise: [NOTICE.md](NOTICE.md).
