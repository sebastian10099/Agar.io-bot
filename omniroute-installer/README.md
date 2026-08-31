# OmniRoute Installer (Windows)

Ein Doppelklick-Setup, das [OmniRoute](https://github.com/diegosouzapw/OmniRoute) installiert
und **Claude Code** sowie **Codex** automatisch darauf umstellt. Danach wählt OmniRoute die
Modelle selbst aus und schaltet bei aufgebrauchtem Kontingent auf einen anderen Anbieter um.

## Loslegen

1. Diesen Ordner herunterladen
2. Doppelklick auf **`OmniRoute-Setup.bat`**
3. Beim Passwort einfach Enter drücken (dann wird eins erzeugt) oder ein eigenes eintippen
4. Warten – der Rest läuft allein
5. **Alle Terminals neu öffnen**, damit Claude Code und Codex die neue Konfiguration sehen

Danach im Dashboard (`http://localhost:20128/dashboard`) unter **Providers** mindestens
einen Anbieter hinzufügen. Ohne Provider hat OmniRoute nichts, wohin es routen kann.

## Was das Setup macht

| Schritt | Aktion |
|---|---|
| 1 | Prüft Node.js (nötig: `>=22.22.2 <23` oder `>=24 <27`), installiert es bei Bedarf per `winget` |
| 2 | `npm install -g omniroute` |
| 3 | `omniroute setup --non-interactive --password …` |
| 4 | Startet den Server und wartet, bis Port 20128 antwortet |
| 5 | `omniroute setup-claude` und `omniroute setup-codex` |
| 6 | Legt eine Verknüpfung im Autostart an, damit der Server nach der Anmeldung läuft |

Schlägt Schritt 5 fehl, öffnet das Skript das Dashboard und sagt dir am Ende genau,
was noch von Hand zu tun ist. Das Setup ist wiederholbar – ein zweiter Durchlauf
überschreibt einfach den ersten.

## Die Dateien

| Datei | Zweck |
|---|---|
| `OmniRoute-Setup.bat` | **Hier draufklicken.** Startet die Installation |
| `omniroute-setup.ps1` | Die eigentliche Logik (PowerShell 5.1+) |
| `OmniRoute-Start.bat` | Server später von Hand starten |
| `OmniRoute-Entfernen.bat` | Autostart und gesetzte Umgebungsvariablen zurücknehmen |
| `Exe-Bauen.bat` | Baut daraus eine echte `OmniRoute-Setup.exe` (siehe unten) |

## Parameter

Das PowerShell-Skript nimmt Argumente entgegen, die `OmniRoute-Setup.bat` durchreicht:

```powershell
.\omniroute-setup.ps1 -Password "geheim"   # Passwort nicht abfragen
.\omniroute-setup.ps1 -NoAutostart         # keine Autostart-Verknüpfung
.\omniroute-setup.ps1 -SkipNodeInstall     # Node nur prüfen, nicht installieren
.\omniroute-setup.ps1 -Remove              # Änderungen zurücknehmen
.\omniroute-setup.ps1 -Remove -Purge       # zusätzlich npm-Paket entfernen
```

## Warum keine fertige `.exe` dabei liegt

Eine unsignierte `.exe` aus dem Internet wird von Windows SmartScreen blockiert und ist
für dich nicht nachprüfbar – du siehst nicht, was drinsteckt. `OmniRoute-Setup.bat` macht
exakt dasselbe per Doppelklick, ist aber lesbar.

Wenn du trotzdem eine `.exe` willst: **`Exe-Bauen.bat`** doppelklicken. Das installiert
`ps2exe` und kompiliert das Skript **auf deinem Rechner** zu `OmniRoute-Setup.exe`.

## Bitte vorher wissen

- OmniRoute leitet deine Prompts und deinen Code an fremde Anbieter weiter. Kostenlose
  Tarife protokollieren häufig mit. Für private oder geschäftliche Projekte lohnt ein
  Blick in die Bedingungen des jeweiligen Anbieters.
- Der Server lauscht auf `localhost:20128`, ist also nur lokal erreichbar.
- Wird ein Zufallspasswort erzeugt, landet es im Klartext in
  `%APPDATA%\omniroute\dashboard-passwort.txt`. Notieren und die Datei danach gern löschen.
- OmniRoute ist ein Drittprojekt (MIT-Lizenz) und gehört nicht zu diesem Repository.
  Dieser Ordner enthält nur das Setup-Skript.
