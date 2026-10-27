# Roadmap

Wohin sich Sweepr entwickelt. Die Reihenfolge kann sich ändern; Sicherheit geht vor Tempo. Wünsche und Fehler bitte als
[Issue](https://github.com/brummilab/Sweepr/issues) melden.

## Erledigt

- **Grundfunktionen:** `sw clean`, `sw uninstall`, `sw optimize`, `sw purge`, Disk-Explorer `sw analyze` und Systemmonitor
  `sw status`
- **Sicherheit:** geschützte System- und Profilordner, Whitelist, `--dry-run` für alles, was löscht, Papierkorb für
  Deinstallationsreste, Protokoll `operations.log` mit `sw history`
- **Portable Version** (läuft vom USB-Stick, ohne Spuren im Profil) und **Installation mit Komponentenauswahl**
- **Windows entschlacken** (`sw features`): geprüfte Liste vorinstallierter Apps und optionaler Features, mit
  `--restore` zum Zurückholen
- **PC einmal prüfen** (`sw check`): nur lesend, mit HTML-Bericht, ohne Installation
- Eigener Launcher `sw.exe`, automatischer Hinweis auf neue Versionen

## Als Nächstes

- **Neues Release** mit fertigen `analyze`- und `status`-Programmen, damit beide wieder ohne Go laufen
- **Bekannte Fehler beheben:** Release-Workflow, Pfade mit Sonderzeichen, `sw analyze` mit OneDrive-Ordnern, kleinere
  Fehler aus der letzten Prüfung
- **Kern überarbeiten:** Verlauf (`sw history`), Schutz- und Löschlogik, Protokoll und Befehlsaufruf neu aufbauen,
  jeweils zuerst mit Tests
- **Abnahme auf echten Windows-10- und -11-PCs** (Installation, Portable, `sw features`, `sw check`)

## Danach

- Befehle `clean`, `purge`, `optimize`, `uninstall` sowie Installation und Update im überarbeiteten Kern
- `sw analyze` und `sw status` schlanker
- Feinschliff für `sw features` und den `sw check`-Bericht, einheitliche Gesundheitsprüfung
- Reste älterer Installationen beim Update sauber aufräumen
- Alle Go- und PowerShell-Tests vollständig in der CI

## Später

- Installation über **winget** und **Scoop**
- Projektseite und Bekanntmachung in der Community
