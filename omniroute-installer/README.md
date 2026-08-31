# OmniRoute Installer (Windows)

Ein Doppelklick-Setup, das [OmniRoute](https://github.com/diegosouzapw/OmniRoute) installiert
und **Claude Code** sowie **Codex** automatisch darauf umstellt. Danach wählt OmniRoute die
Modelle selbst aus und schaltet bei aufgebrauchtem Kontingent auf einen anderen Anbieter um.

## Loslegen

**Nur eine Datei nötig: [`OmniRoute.bat`](OmniRoute.bat).** Herunterladen, doppelklicken, fertig.

Darin stecken alle Skripte als eingebettetes Archiv. Beim Start entpacken sie sich in ein
temporäres Verzeichnis, ein Menü geht auf, und danach wird wieder aufgeräumt. Es kann also
nicht passieren, dass eine Datei ihre Nachbardatei nicht findet.

Im Menü:

| | |
|---|---|
| **1** | Installieren / reparieren |
| **2** | Desktop-App starten – erst Server, dann App |
| **3** | Nur das Dashboard im Browser |
| **4** | Diagnose – Bericht auf den Desktop |
| **5** | Server im Vordergrund, mit sichtbaren Meldungen |

Beim Passwort einfach Enter drücken, dann wird eins erzeugt. Danach **alle Terminals neu
öffnen**, damit Claude Code und Codex die neue Konfiguration sehen.

Wer die Einzeldateien lieber mag: den ganzen Ordner herunterladen und `OmniRoute-Setup.bat`
starten. Dann müssen aber **alle** Dateien zusammen in einem Ordner liegen – jede `.bat`
sucht die gleichnamige `.ps1` direkt neben sich.

Danach im Dashboard (`http://localhost:20128/dashboard`) unter **Providers** mindestens
einen Anbieter hinzufügen. Ohne Provider hat OmniRoute nichts, wohin es routen kann – das
ist der Punkt, an dem es sonst aussieht, als würde nichts funktionieren.

## Die Desktop-App startet schwarz

**Dafür ist `OmniRoute-Desktop.bat` da.** Nicht die App direkt starten, sondern diese Datei.

Der Grund: Die App ist nicht kaputt, sie startet nur zu früh. Sie lädt beim Start
`http://localhost:20128`, bekommt keine Antwort, landet auf einer Fehlerseite – und die ist
schwarz. In den Fehlerberichten des Projekts steht genau das als Konsolenfehler:

```
Unsafe attempt to load URL http://localhost:20128/ from frame
with URL chrome-error://chromewebdata/
```

([#1253](https://github.com/diegosouzapw/OmniRoute/issues/1253),
[#1270](https://github.com/diegosouzapw/OmniRoute/issues/1270) – beide geschlossen, betrafen 3.6.5)

`OmniRoute-Desktop.bat` dreht die Reihenfolge um: erst den Server starten, warten bis Port
20128 wirklich antwortet, **dann** die App öffnen. Antwortet der Server nicht, wird die App
gar nicht erst gestartet – stattdessen steht im Fenster, woran es liegt.

Es gibt drei Optionen im Menü:

| | |
|---|---|
| **1** | Normal starten |
| **2** | Mit `--disable-gpu` – falls das Fenster *trotz* laufendem Server schwarz bleibt (Grafiktreiber) |
| **3** | Nur den Browser öffnen – dieselbe Oberfläche, ohne App |

## Wenn es nicht läuft

Doppelklick auf **`Diagnose.bat`**. Das schreibt `OmniRoute-Diagnose.txt` auf den Desktop
und öffnet sie: Windows- und Node-Version, ob OmniRoute installiert ist, wer auf Port 20128
lauscht, ob die Desktop-App gefunden wird, die Datenverzeichnisse, `omniroute doctor` und die
letzten 60 Zeilen des Setup-Protokolls.

Passwörter und API-Schlüssel stehen **nicht** darin – nur ob sie gesetzt sind. Die Datei
kann also weitergegeben werden.

Jeder Setup-Durchlauf protokolliert außerdem nach
`%LOCALAPPDATA%\OmniRouteInstaller\logs`.

Von Hand eingrenzen geht auch:

```powershell
omniroute doctor                    # eingebauter Selbsttest
omniroute                           # Server starten und Ausgabe lesen
netstat -ano | findstr :20128       # lauscht überhaupt etwas auf dem Port?
```

Läuft der Server und das Dashboard bleibt trotzdem leer, hilft laut Issue-Tracker als letztes
Mittel das Löschen von `%USERPROFILE%\.omniroute\storage.sqlite` – **damit sind die
Provider-Einstellungen weg.**

Der allererste Aufruf des Dashboards dauert übrigens lange. OmniRoute baut seine Oberfläche
beim ersten Start, das kann ein paar Minuten brauchen.

## Die Dateien

| Datei | Zweck |
|---|---|
| `OmniRoute.bat` | **Hier anfangen.** Enthält alles andere, Menü für alle Aufgaben |
| `OmniRoute-Setup.bat` | Installiert alles (Einzeldatei-Variante) |
| `OmniRoute-Desktop.bat` | Desktop-App in der richtigen Reihenfolge starten |
| `Diagnose.bat` | Bericht erzeugen, wenn etwas klemmt |
| `OmniRoute-Start.bat` | Server von Hand starten, mit sichtbarer Ausgabe |
| `OmniRoute-Entfernen.bat` | Autostart und gesetzte Umgebungsvariablen zurücknehmen |
| `Exe-Bauen.bat` | Baut daraus eine echte `OmniRoute-Setup.exe` |
| `omniroute-common.ps1` | Gemeinsame Funktionen der Skripte |
| `omniroute-setup.ps1` | Die Installationslogik |
| `omniroute-desktop.ps1` | Die Startlogik der Desktop-App |
| `omniroute-diagnose.ps1` | Die Diagnoselogik |
| `omniroute-menu.ps1` | Das Menü der Alles-in-einem-Datei |
| `tools/Build-Standalone.ps1` | Baut `OmniRoute.bat` aus den Skripten |
| `tests/Run-Tests.ps1` | Syntaxprüfung und Logiktests |
| `tests/Test-Standalone.ps1` | Prüft die gebaute `OmniRoute.bat` |

`OmniRoute.bat` wird erzeugt, nicht von Hand gepflegt. Nach einer Änderung an den `.ps1`
neu bauen:

```powershell
pwsh -NoProfile -File .\tools\Build-Standalone.ps1
pwsh -NoProfile -File .\tests\Test-Standalone.ps1
```

`Test-Standalone.ps1` vergleicht die eingebetteten Dateien per SHA256 mit den Quelldateien
und schlägt fehl, wenn das Bauen vergessen wurde.

Die `.bat`-Dateien sind nur Starthilfen für die gleichnamigen `.ps1`-Dateien. Sie müssen
deshalb im selben Ordner liegen.

## Was das Setup macht

| Schritt | Aktion |
|---|---|
| 1 | Prüft Node.js (nötig: `>=22.22.2 <23` oder `>=24 <27`), installiert es bei Bedarf per `winget` |
| 2 | `npm install -g omniroute` |
| 3 | `omniroute setup --non-interactive --password …` |
| 4 | Startet den Server und wartet, bis Port 20128 antwortet |
| 5 | `omniroute setup-claude` und `omniroute setup-codex` |
| 6 | Legt eine Verknüpfung im Autostart an |

Schlägt Schritt 5 fehl, bricht nichts ab: das Setup läuft zu Ende, öffnet das Dashboard und
sagt am Schluss genau, was noch von Hand fehlt. Ein zweiter Durchlauf überschreibt einfach
den ersten.

## Parameter

```powershell
.\omniroute-setup.ps1 -Password "geheim"   # Passwort nicht abfragen
.\omniroute-setup.ps1 -NoAutostart         # keine Autostart-Verknüpfung
.\omniroute-setup.ps1 -SkipNodeInstall     # Node nur prüfen, nicht installieren
.\omniroute-setup.ps1 -Remove              # Änderungen zurücknehmen
.\omniroute-setup.ps1 -Remove -Purge       # zusätzlich npm-Paket entfernen

.\omniroute-desktop.ps1 -DisableGpu        # App ohne GPU-Beschleunigung
.\omniroute-desktop.ps1 -BrowserOnly       # nur Dashboard im Browser
```

## Warum keine fertige `.exe` dabei liegt

Eine unsignierte `.exe` aus dem Internet wird von Windows SmartScreen blockiert und ist für
dich nicht nachprüfbar – du siehst nicht, was drinsteckt. `OmniRoute-Setup.bat` macht exakt
dasselbe per Doppelklick, ist aber lesbar.

Wenn du trotzdem eine `.exe` willst: **`Exe-Bauen.bat`** doppelklicken. Das installiert
`ps2exe` und kompiliert das Skript **auf deinem Rechner**.

## Bitte vorher wissen

- OmniRoute leitet deine Prompts und deinen Code an fremde Anbieter weiter. Kostenlose
  Tarife protokollieren häufig mit. Für private oder geschäftliche Projekte lohnt ein Blick
  in die Bedingungen des jeweiligen Anbieters.
- Der Server lauscht auf `localhost:20128`, ist also nur lokal erreichbar.
- Wird ein Zufallspasswort erzeugt, landet es im Klartext in
  `%APPDATA%\omniroute\dashboard-passwort.txt`. Notieren und die Datei danach gern löschen.
- OmniRoute ist ein Drittprojekt (MIT-Lizenz) und gehört nicht zu diesem Repository. Dieser
  Ordner enthält nur die Setup-Skripte.
