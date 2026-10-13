# GoMining Bot Pro (macOS)

Papierhandel-Bot für **GOMINING/USDT** auf BingX Spot, mit echten Marktdaten (Orderbuch, Trades, Kerzen) und
**ausschließlich simulierten Orders**. Die App sendet keine Orders an BingX – auch dann nicht, wenn ein API-Schlüssel
verbunden ist (der wird nur zum Anzeigen von Guthaben und Gebührensatz benutzt).

Dieses Verzeichnis enthält den **Quellcode** der App. Von Version 3.9 gab es nur die fertige `GoMining Bot.app`;
der Quellcode wurde daraus rekonstruiert (Datenmodell, Einstellungen, Endpunkte, Texte, Handelslogik) und
weiterentwickelt. Er ist deshalb *nicht* Byte für Byte identisch mit 3.9 – die Strategie ist dieselbe Familie
(adaptiver Kauf- und Verkaufsabstand aus Spread, Gebühren und Volatilität), aber mit Verbesserungen, siehe unten.

![Übersicht](docs/screens/1-uebersicht.png)

*Die Oberfläche mit Live-Daten von BingX (automatisch von der CI aufgenommen).*

## App bekommen

**Neueste Version direkt herunterladen:**
https://github.com/sebastian10099/Agar.io-bot/releases/latest/download/GoMining-Bot.zip
(alle Versionen und Neuerungen: https://github.com/sebastian10099/Agar.io-bot/releases)

Mit einem Befehl auf den Desktop legen und starten (Programm *Terminal* öffnen, einfügen, Enter). Eine vorhandene
„GoMining Bot Pro“ wird beendet und durch die neueste ersetzt; eine alte „GoMining Bot“-App bleibt unberührt:

```bash
pkill -x GoMiningBotPro; T="$(mktemp -d)" && curl -fL -o "$T/app.zip" https://github.com/sebastian10099/Agar.io-bot/releases/latest/download/GoMining-Bot.zip && ditto -x -k "$T/app.zip" "$T" && rm -rf ~/Desktop/"GoMining Bot Pro.app" && mv "$T/GoMining Bot Pro.app" ~/Desktop/ && { xattr -cr ~/Desktop/"GoMining Bot Pro.app"; open ~/Desktop/"GoMining Bot Pro.app"; }
```

Oder von Hand: ZIP im Browser laden, per Doppelklick entpacken, App auf den Desktop oder in *Programme* ziehen. Die App
ist nicht notarisiert (kein Apple-Entwicklerkonto), deshalb blockiert macOS den ersten Start und bietet nur *In den
Papierkorb legen* an. So geht es trotzdem:

- **macOS 15 und neuer:** *Fertig* klicken → *Systemeinstellungen → Datenschutz & Sicherheit* → ganz unten bei
  „GoMining Bot Pro wurde blockiert“ auf **Dennoch öffnen** → mit Passwort bestätigen → **Trotzdem öffnen**.
- **macOS 14:** Rechtsklick auf die App → **Öffnen** → **Öffnen**.
- **Meldung „ist beschädigt“:** im Terminal `xattr -cr ` eingeben (mit Leerzeichen am Ende), die App ins
  Terminal-Fenster ziehen, Enter drücken, App normal öffnen.

Der Terminal-Befehl oben umgeht das alles, weil `curl` keine Download-Sperre setzt. Updates aus der App heraus sind
ebenfalls nicht betroffen.

**Updates:** Ab Version 4.1 sucht die App selbst nach neuen Versionen, zeigt ein Banner und installiert das Update auf
Knopfdruck (Einstellungen → Updates). Papierkonto und Einstellungen bleiben dabei erhalten.

**So entstehen neue Versionen:** Die Weiterentwicklung folgt der [Roadmap](ROADMAP.md) in gebündelten Paketen. Sobald
in `VERSION` eine neue Nummer steht und alle Prüfungen grün sind, veröffentlicht GitHub Actions automatisch ein Release
mit der fertigen App; die Neuerungen stehen im [CHANGELOG](CHANGELOG.md).

**Variante B – selbst bauen** (macOS 14+, Xcode oder `xcode-select --install`)

```bash
cd GoMiningBot
./build_app.sh          # erzeugt dist/GoMining Bot Pro.app und dist/GoMining-Bot.zip (Apple Silicon + Intel)
swift test              # Unit-Tests der Kernbibliothek
```

## Eigene App neben der alten „GoMining Bot“

Seit 4.1.1 heißt die App **GoMining Bot Pro** und hat eine eigene Bundle-ID (`com.sebastian.gominingbot.pro`), ein
eigenes Symbol (blau-violett mit „PRO“) und einen eigenen Datenordner. Bis 4.1 hatte sie denselben Namen und dieselbe
Bundle-ID wie die alte App 3.9 – macOS hielt beide für dieselbe App und öffnete oft die alte. Die alte App kann
jetzt gefahrlos daneben liegen oder in den Papierkorb.

## Daten aus Version 3.9 und 4.0/4.1

Datenordner: `~/Library/Application Support/GoMining Bot Pro/`. Beim ersten Start wird der bisherige Ordner
`~/Library/Application Support/GoMining Bot/` (alte App 3.9 und diese App bis 4.1) einmalig **kopiert**; der alte Ordner
bleibt unverändert, damit sich die beiden Apps nicht gegenseitig das Papierkonto überschreiben. Einstellungen wie
Mitteilungen und Preisalarme werden ebenfalls übernommen. Liegt dort noch eine `simulation.json` im Format von 3.9,
wird sie automatisch ins neue Format überführt; **vorher** wird eine Kopie der alten Datei in `backups/` abgelegt. Der gespeicherte BingX-Schlüssel (Schlüsselbund-Dienst `com.sebastian.gominingbot.bingx.readonly`)
wird weiterverwendet; macOS fragt beim ersten Zugriff einmal nach der Erlaubnis („Immer erlauben“).

Einmalige Anpassung: Der alte Standard für gleichzeitige Positionen (4 bzw. 8) wird auf **10** angehoben; bewusst
andere Werte bleiben unverändert.

## Neu in 4.3

- **Diagramm zum Zoomen und Verschieben** (Trackpad oder Lupe, „Live“, „Alles“), Tooltips mit den Trades jeder Kerze.
- **Profile & Vorlagen:** Einstellungen speichern, laden, als Datei teilen und importieren; Vorlagen „Vorsichtig“,
  „Ausgewogen“, „Aktiv“; ein Profil per Klick als Schattenkonto testen.
- **Berichte:** heute, gestern, letzte 7 Tage auf der Statistik-Seite, als HTML-Bericht speicherbar; Tageszusammenfassung
  als Mitteilung.
- **Vergleichsdiagramm** aller Schattenkonten seit ihrem Start.

## Neu in 4.2

- **Mindest-Kaufabstand 80 bp:** Der Bot kauft nicht mehr nach jedem kleinen Rücksetzer. Auf 7 Tagen echter Kerzen mit
  echtem Spread: +0,35 USDT statt −18 USDT (Halten −6,5 %), bei deutlich weniger Trades.
- **Backtest mit echtem Live-Spread** statt fester 20 bp – die Ergebnisse passen damit besser zum Livebetrieb.
- **Vergleich mit Schattenkonten:** bis zu fünf weitere Einstellungen (Vorlagen „Vorsichtig“, „Aktiv“, „mit
  Limit-Kauf“ …) handeln parallel auf denselben Live-Daten; die neue Seite *Vergleich* zeigt, welche besser läuft, und
  übernimmt die Einstellungen auf Wunsch ins Hauptkonto.
- **Replay aus dem Marktprotokoll:** Backtest über die echten Orderbücher und Käuferanteile, die die App selbst
  aufgezeichnet hat – statt angenommenem Spread. Typischen Spread und typische Tiefe kann man auch für den
  Kerzen-Backtest messen lassen.
- **Robustere Optimierung:** Ergebnis je Zeitabschnitt („3/4 im Plus“), Walk-forward-Prüfung (wie hätte der Optimierer in
  Echtzeit abgeschnitten?) und „Übernehmen“ nur noch, wenn der Testabschnitt im Plus liegt.
- **Limit-Kauf am Bid (Maker) als Option:** virtuelle Kauforder am Bid, ausgeführt erst, wenn echte Verkäufe die
  Warteschlange davor abgearbeitet haben; mit Zeitlimit und Abbruch, wenn der Kurs davonläuft.

Details: [CHANGELOG](CHANGELOG.md).

## Neu in 4.0 und 4.1

Neuerungen ab 4.1 (Updates aus der App, Trendfilter, „Was ist neu“) stehen im [CHANGELOG](CHANGELOG.md).

**Schneller und robuster**

- Livestream (Trades + Orderbuch) ist die Hauptquelle; REST nur für Kerzen und als Fallback, wenn der Stream hakt.
- Automatische Wiederverbindung (1 → 30 s), Wächter bei Stille, neue Verbindung nach dem Aufwachen aus dem Ruhezustand.
- Engine rechnet mit vorberechneten Kennzahlen ohne Speicherzuweisungen im Takt; Oberfläche wird höchstens ~4× pro
  Sekunde aktualisiert. Der Bot läuft auch weiter, wenn das Fenster verdeckt ist (kein App Nap).
- Minuten ohne Trade werden korrekt als „flach“ behandelt – vorher blockierte das bei dünnem Handel mit
  „Kurskerzen veraltet“.
- Speichern atomar im Hintergrund, Sicherungen alle 30 Minuten (12 behalten), Wiederherstellung bei beschädigter Datei,
  Sicherung vor jedem Zurücksetzen.

**Neue Funktionen**

- **Kerzendiagramm** mit echtem Open/High/Low/Close (grün/rot), Volumen, Fadenkreuz, Einstiegslinien, ▲/▼-Marken für
  Käufe und Verkäufe, Linien „Kauf ab“/„Verkauf ab“ und Zeitraum 1 Min / 5 Min / 15 Min / 1 Std / 4 Std.
- **Anstiegs- und Fall-Erkennung** über 6, 8, 20 und 60 Minuten: Nach einem Anstieg (mit roter Gegenkerze) wird nicht
  mehr in den Pump gekauft und früher verkauft; nach einem Fall (mit grüner Kerze) wird nachgekauft. BingX Spot kann
  nicht leerverkaufen – es wird nur Bestand auf- und abgebaut.
- **Backtest** über bis zu 7 Tage 1-Minuten-Kerzen direkt von BingX (weiter zurück gibt die Schnittstelle nichts her;
  längeren Verlauf sammelt die App lokal, solange sie läuft, bis 45 Tage) und **Optimierer** (Rastersuche mit
  Trainings-/Testaufteilung gegen Überanpassung; Ergebnis mit einem Klick übernehmen). 12 Kombinationen auf 7 Tagen
  dauern weniger als eine Sekunde.
- **Statistik:** Gewinnquote, Profit-Faktor, Erwartung je Trade, Ø Gewinn/Verlust, Haltedauer, Drawdown,
  Vermögensverlauf gegen „Halten“, Ergebnis je Tag.
- **Neue Schutzfunktionen** (alle einstellbar): Trailing-Stop, Zeit-Ausstieg, Abkühlphase nach Stop-Loss,
  Drawdown-Grenze, Mindestabstand zwischen Käufen, automatisches Zusammenfassen von Kleinstresten.
- **Menüleiste** mit Kurs, Ergebnis und Start/Pause; **Benachrichtigungen** (Trades, Stop-Loss, Schutzgrenzen) und
  **Preisalarme**.
- **Export:** Trades als CSV (Excel/Numbers, deutsches Format), Sicherung als JSON, „Diagnose kopieren“ für Fehlersuche.
- Verkäufe großer Bestände (z. B. der Startkauf) erfolgen in Tranchen von „Einsatz je Position“.

## So entscheidet der Bot

Pro Marktdurchlauf (Livestream-Ereignis, höchstens ~4× pro Sekunde):

1. **Marktprüfung:** gültiges, frisches Orderbuch; für Käufe zusätzlich frische Kerzen, Spread unter dem Limit und
   etwas Handelsaktivität.
2. **Verkäufe zuerst**, je Los: *Stop-Loss* (Standard 3 %) → *Trailing-Stop* (optional) → *Nettoziel*
   (mindestens „Mindest-Nettoziel“, adaptiv höher bei großem Spread/hoher Volatilität; nach einem Anstieg mit
   Gegenkerze genügt das Minimum). Verkauft wird gegen die echte Orderbuchtiefe, mit Teilverkauf, wenn die Tiefe nicht
   reicht (höchstens 30 % der sichtbaren Tiefe).
3. **Käufe**, wenn alle Grenzen passen (Tagesverlust, Drawdown, Abkühlphase, Abstand zwischen Trades, freie
   Positionen, Bestandsanteil, Guthaben) und einer dieser Auslöser vorliegt:
   *Adaptiver Rückgang* (Kurs fällt um die Kaufschwelle unter das Hoch der letzten Kerzen, Käuferanteil nicht
   schwach), *Schneller Rückgang mit frischem Kaufdruck*, *bestätigter Fall* (6/8/20/60 min) oder
   *Aufwärtstrend mit Kaufdruck*. Im Miner-Wars-Fenster (Dienstag 00:00–18:00 UTC) gelten strengere Schwellen.
4. Kaufschwelle = max(5 bp, 1,5 × Spread + 2 × (Gebühr + Slippage), 2 × Volatilität), begrenzt durch den
   „Maximalen Kaufabstand“; Verkaufsziel = max(Mindest-Nettoziel, 0,5 × Spread, 1,5 × Volatilität).

Alle Kosten (Gebühr je Seite, Slippage, Spread, Orderbuchtiefe, Mindestmenge/-betrag der Börse) fließen in jeden
simulierten Trade ein.

## Grenzen – bitte lesen

- **Keine echten Orders.** Die Echtgeld-Anbindung gibt es bewusst nicht; Papierergebnisse sind kein Beleg dafür, dass
  eine Strategie mit echtem Geld funktioniert (Ausführung, Wartezeiten, Teilausführung, Gebührenstufen).
- **Kein Gewinnversprechen.** Mit den Standardwerten von 4.2 lag der Bot auf 7 Tagen echter Kerzen (Stand 12.10.2026)
  bei +0,02 bis +0,04 % (reines Halten: −6,5 %) – vor allem, weil er in einer fallenden Woche wenig gekauft hat. Mit den
  Werten von 4.1 und echtem Spread waren es −1,8 %. Die Walk-forward-Prüfung des Optimierers findet bisher keine
  Einstellung, die verlässlich im Plus bleibt – Gebühren, Spread und Stop-Loss fressen die kleinen Ziele. Die App ist
  ein Werkzeug zum Ausprobieren und Lernen.
- **Backtest ≠ Zukunft.** Im Backtest gibt es keine historischen Orderbücher; Spread und Tiefe sind Annahmen, und es
  fehlen die Einzeltrades (Käuferanteil). Der Optimierer findet auch im Zufall „gute“ Werte – der Testabschnitt zeigt,
  ob sie halten.
- Die BingX-Parser sind gegen Beispielantworten getestet und werden bei jedem Build zusätzlich in einem Rauchtest gegen
  die Live-Schnittstelle geprüft. Falls die App trotzdem „Marktdaten eingeschränkt“ meldet: *Einstellungen → Diagnose
  kopieren* und mitschicken.
- Keine Anlageberatung.

## Entwicklung

```
GoMiningBot/
  Package.swift
  Sources/GoMiningCore/   Modelle, Engine, Orderbuch, Erkennung, Backtest, Statistik, Persistenz, BingX-Parser
  Sources/GoMiningBot/    SwiftUI-App: Controller, Dienste (REST, WebSocket, Schlüsselbund), Oberfläche
  Tests/                  Unit-Tests (XCTest) – laufen in GitHub Actions auf macOS
  Resources/              App-Symbol und Info.plist-Vorlage
  build_app.sh            baut und signiert (ad hoc) die .app
```

Der Workflow `.github/workflows/gomining-bot.yml` führt bei jedem Push `swift test` aus, baut die universelle App und
legt sie als Artefakt ab.
