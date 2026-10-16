# New-Token Bot

Ein Trading-Bot für frisch gelistete Tokens — **Paper-first**: echte Kurse,
simulierte Ausführung, und ein eingebauter Beweis, ob die Strategie überhaupt
eine Kante hat. Läuft als lokale Mac-App, ohne Abhängigkeiten außer Python 3.9+.

> Ehrlich vorweg: Es gibt keinen Bot, der bei neuen Tokens garantiert Gewinn
> macht. Der Großteil neuer Listings sind Rug-Pulls oder Honeypots. Dieses
> Projekt ist dafür gebaut, das **messbar** zu machen, bevor echtes Geld im
> Spiel ist. Echtgeld-Ausführung ist absichtlich nicht enthalten.

## Starten

| Was | Wie |
| --- | --- |
| Live-Markt, Spielgeld | Doppelklick auf **Start Trading Bot.command** (oder `TradingBot.app`) |
| Offline-Demo, Zeitraffer | Doppelklick auf **Start Demo.command** |
| Terminal | `python3 -m bot.main` bzw. `python3 -m bot.main --demo` |

Das Dashboard öffnet sich unter http://127.0.0.1:8765 — nur lokal erreichbar.
Daten liegen in `~/Library/Application Support/NewTokenBot/`.

Beim ersten Start entsteht dort eine `config.json`; alles, was du dort
einträgst, überschreibt die Standardwerte aus `bot/config.json`.

Falls der Starter „Kein Python gefunden, das HTTPS-Verbindungen aufbauen kann"
meldet: Der python.org-Build bringt keine Zertifikate mit. Einmalig
`/Applications/Python 3.x/Install Certificates.command` doppelklicken.

## Die Steuerseite

Das Dashboard ist zugleich die Steuerung. Vier Reiter:

- **Übersicht** – offene Positionen mit Live-Gain, Hoch, Rest-Anteil, den
  **Zielkursen** (Stop, nächste Leiterstufe, Trailing sobald scharf, Restzeit bis
  zum Zeit-Stop) und einem Knopf zum manuellen Schließen; die **Kapitalkurve**
  (realisierter Stand nach jedem Exit, mit Fadenkreuz und Tastaturablesung);
  Edge-Report mit Balken; geschlossene Positionen. Jede Position hat einen
  **Details**-Dialog mit dem **Kursverlauf seit Einstieg** (Einstieg, Stop und
  Leiterstufen als Linien, Hoch markiert) und ihren einzelnen Fills.
- **Steuerung** – jeder Parameter der Strategie als Formular, gruppiert nach
  Allgemein / Risiko / Filter / Strategie / Exits. Geänderte Felder werden
  markiert, Fehler stehen direkt am Feld, „Speichern“ gilt **sofort** für den
  laufenden Bot und landet in `~/Library/Application Support/NewTokenBot/config.json`.
  Dazu: **Profile** (Parametersätze unter Namen speichern, laden, löschen – zum
  Vergleichen von Strategien), Standardwerte laden, Paper-Konto zurücksetzen
  (nur Positionen, oder alles inklusive Edge-Daten), wahlweise mit neuem
  Startkapital, und CSV-Export von Positionen, Fills und Kandidaten.
  Die Karte **Quellen** zeigt für jede Discovery-Quelle, ob sie liefert, wie
  viele Tokens sie im letzten Poll gemeldet hat und wie viele davon nur sie
  gesehen hat – so siehst du, welche Quelle wirklich etwas bringt.
- **Kandidaten** – alle bewerteten Tokens mit Score, Kennzahlen und den
  Gründen für die Entscheidung; filterbar nach buy/watch/skip und Suchtext,
  sortierbar per Klick auf die Spaltenköpfe. **Kaufen** eröffnet einen Token
  als Paper-Position unabhängig vom Bot-Urteil – der Tracker behält die
  ursprüngliche Entscheidung, so lässt sich das eigene Urteil gegen die Regeln
  messen.
- **Analyse** – zuerst **Exits nach Grund**: wie oft jede Ausstiegsregel
  gegriffen hat, mit Trefferquote, Ø und Σ P&L und Ø Haltedauer – so siehst
  du, ob der Zeit-Stop Geld kostet oder die Leiter zu früh verkauft. Darunter
  der Rückblick: Jeder Filterwert wird einzeln über ein Raster
  bewegt (alle anderen bleiben wie eingestellt), und für jeden Wert steht da,
  wie viele der bisherigen Kandidaten damit `buy` gewesen wären und welche
  Rendite sie danach tatsächlich hatten. Zeilen mit weniger als fünf Treffern
  sind ausgegraut – Rauschen, kein Ergebnis. Umschaltbar nach Horizont
  (5 / 15 / 60 Minuten). **Übernehmen** trägt einen besseren Wert (oder alle
  auf einmal) ins Formular ein – gespeichert wird erst mit „Speichern“.
- **Protokoll** – was der Bot getan hat, inklusive jeder Änderung über die Seite,
  filterbar nach Trades / Polls / Info / Fehler.

Oben rechts: **🔔** (Browser-Benachrichtigung bei jedem Einstieg und Exit,
fragt einmal um Erlaubnis), **Jetzt pollen** (sofort neue Tokens holen) und
**Pause**. Pause stoppt nur neue Einstiege – Exits offener Positionen laufen
weiter. Tasten: `1`–`5` Reiter, `p` Pause, `r` Pollen, `/` Suche.

Die Seite ist vollständig per Tastatur bedienbar, jedes Bedienelement hat einen
Namen für Screenreader, Rückmeldungen werden vorgelesen, und alle Farbpaare
erfüllen WCAG AA in beiden Themes – nachgemessen, nicht geschätzt
(`tests/ui/verify.js` prüft Tastaturbedienung und Beschriftungen mit).
Der Punkt links im Titel zeigt, ob der Bot lebt (grün), noch nie gepollt hat
(gelb) oder länger als drei Intervalle nichts gemeldet hat (rot).

Die Seite redet über eine kleine JSON-API mit dem Bot, die du auch direkt
nutzen kannst (nur von `127.0.0.1` erreichbar):

| Methode | Pfad | Zweck |
| --- | --- | --- |
| GET | `/api/state` | Alles, was die Seite anzeigt |
| GET | `/api/schema` | Parameter-Schema (Typ, Grenzen, Beschriftung) |
| GET | `/api/config` · `/api/defaults` | Aktuelle bzw. Standard-Parameter |
| POST | `/api/config` `{"patch": {"exits.stop_loss_pct": -25}}` | Parameter ändern, validiert, 422 bei Fehlern |
| POST | `/api/control` `{"action": "pause"\|"resume"\|"poll"}` | Steuern |
| POST | `/api/positions/close` `{"id": 3}` | Position zum letzten Kurs schließen |
| POST | `/api/positions/open` `{"candidate_id": 12}` | Kandidaten manuell als Paper-Position kaufen |
| GET | `/api/positions/3` | Position mit allen Fills, Kursverlauf (`ticks`) und den Exit-Parametern |
| GET | `/api/sweep?horizon=15` | Rückblick-Analyse der Filterwerte |
| POST | `/api/reset` `{"what": "positions"\|"all", "bankroll": 500}` | Paper-Konto zurücksetzen, optional mit neuem Startkapital |
| GET/POST | `/api/profiles` · `/api/profiles/apply` · `/api/profiles/delete` | Parameter-Profile verwalten |
| GET | `/api/export/positions.csv` · `trades.csv` · `candidates.csv` | Export (Semikolon-CSV, UTF-8 mit BOM) |
| POST | `/api/ai/key` `{"key": "sk-ant-…"}` | Anthropic-Schlüssel im macOS-Schlüsselbund ablegen |

Ein neuer Parameter ist ein Eintrag in `bot/settings.py` – Validierung und
Formular entstehen daraus automatisch.

## Wie der Bot entscheidet

```
DexScreener-Profile + GeckoTerminal-Pools  ->  Harte Filter  ->  Score 0-100  ->  buy / watch / skip
          (Discovery-Quellen)                      |                                   |
                                               RugCheck                          Tracker: was wurde
                                                                                 5/15/60 min später daraus?
```

**Discovery** – woher neue Tokens kommen – ist steckbar (`discovery.sources`,
auch über die Steuerseite). Eingebaut sind zwei kostenlose Feeds ohne Schlüssel:

- **DexScreener** – „neueste Profile“ und „neueste Boosts“: Tokens, die gerade
  beworben werden. Zuverlässig, aber erst, wenn jemand dafür bezahlt hat.
- **GeckoTerminal** – „neue Pools“ pro Chain in Entstehungsreihenfolge. Sieht
  einen Launch meist einige Minuten früher. Begrenzt auf eine Abfrage je Chain
  alle 15 Sekunden (die Freigrenze sind 30 pro Minute), dazwischen wird die
  letzte Antwort wiederverwendet.

Die erste Quelle in der Reihenfolge, die einen Token nennt, gilt als seine
Quelle (steht am Kandidaten). Die Kennzahlen holt immer DexScreener; ist ein
Token dort noch nicht gelistet, wird er mit den Zahlen des Feeds bewertet und
der Kandidat trägt „via Feed“. Fällt eine Quelle aus, steht das einmal im
Protokoll und in der Quellen-Karte – die anderen laufen weiter.

**Harte Filter** (ein Verstoß = `skip`, Grund wird gespeichert):

- Alter 2–120 Minuten — nicht in der ersten Minute kaufen, nicht alten Tokens hinterherlaufen
- Liquidität 15 k–2 M $, 5-Minuten-Volumen ≥ 3 k $, ≥ 15 Käufe in 5 Minuten
- Käufe/Verkäufe ≥ 1.2 — es muss mehr rein- als rausgehen
- 5-Minuten-Kursänderung zwischen 0 % und +150 % — nichts Fallendes, nichts Parabolisches
- FDV ≤ 20 M $
- RugCheck: keine `danger`-Einstufung (Freeze-Authority, Holder-Konzentration, …), Score ≤ 2000. Ist RugCheck nicht erreichbar, wird **nicht** gekauft.

**Score** aus Liquidität, Aktivität (Volumen/Liquidität), Kaufdruck, Momentum,
Alter (5–30 min ideal), Socials und RugCheck. Ab 60 Punkten `buy`, darunter `watch`.

## Wie gehandelt wird (Paper)

- Positionsgröße aus Risiko: 1 % der Bankroll pro Trade, geteilt durch den Stop-Abstand → ~3,3 % pro Position
- Stop-Loss −30 %, Gewinnleiter: 50 % der Position bei +50 %, 25 % bei +100 %
- Trailing-Stop 25 % vom Hoch, der erst ab +25 % scharf wird
- Zeit-Stop nach 45 Minuten — neue Tokens verfallen schnell, Halten ist kein Plan
- Maximal 5 offene Positionen, Tages-Verlustlimit 5 % → danach keine neuen Einstiege
- **Jeder Fill zahlt 1 % Gebühr und 2 % Slippage.** Das ist bewusst pessimistisch. Ein Bot, der nur mit null Kosten profitabel ist, ist nicht profitabel.

## KI-Modus: Claude als zweiter Blick – oder als Entscheider

Im Reiter *Steuerung* unter **KI** lässt sich Claude zuschalten. Die harten
Sicherheitsfilter (RugCheck-Gefahrenflags, Liquidität, Altersfenster) bleiben
immer davor: Das Modell sieht nur Kandidaten, die sie bestanden haben, und
bekommt deren Kennzahlen, die RugCheck-Zusammenfassung und das Urteil der
Regeln. Es antwortet strukturiert mit `buy` / `watch` / `skip`, einer
Vertrauenszahl, bis zu drei Gründen und Warnzeichen.

| Modus | Was passiert |
| --- | --- |
| **Aus** | Nur die Regeln entscheiden. |
| **Beraten** | Die Regeln entscheiden, das KI-Urteil wird bei jedem Kandidaten mitprotokolliert. |
| **Entscheiden** | Das KI-Urteil ersetzt die Regel-Entscheidung; gekauft wird nur ab der eingestellten Mindest-Vertrauenszahl. |

Der Punkt ist die Messung: Der Edge-Report in der Übersicht lässt sich auf
**Bot / Regeln / KI** umschalten und zeigt die Vorwärtsrendite derselben
Kandidaten nach dem jeweiligen Urteil. Fang mit *Beraten* an. Erst wenn die
KI-Spalte über Wochen klar vor den Regeln liegt, ist *Entscheiden* mehr als
ein Gefühl. Ein Sprachmodell kann Kurse nicht vorhersagen; es kann Warnzeichen
lesen, die starre Regeln übersehen – ob das Geld wert ist, sagt nur der Report.

Einrichtung:

```bash
pip install anthropic            # offizielles SDK, einzige Zusatzabhängigkeit
```

Schlüssel: `ANTHROPIC_API_KEY` in der Umgebung, ein `ant auth login`-Profil,
oder auf dem Mac über die Steuerseite in den Schlüsselbund speichern. Dann
einmal prüfen, ob die Verbindung steht – ein echter Aufruf mit einem
Beispiel-Token, Urteil und Kosten werden ausgegeben:

```bash
python3 -m bot.ai
```

Technik: Modell `claude-opus-5-5` (einstellbar), adaptives Denken mit
einstellbarer Tiefe (`effort`), strukturierte JSON-Ausgabe per Schema,
serverseitige Fallbacks bei Sicherheitsablehnungen, Prompt-Caching für den
festen Systemteil. Kostenbremse über *Max. Anfragen pro Stunde*; der laufende
Verbrauch steht auf der Steuerseite. Jeder Fehler (ungültiger Schlüssel,
Rate-Limit, Modell nicht gefunden) landet im Protokoll, und die Regeln
entscheiden dann allein weiter.

## Der Edge-Report — der wichtigste Teil

Der Tracker merkt sich **jeden** bewerteten Token, auch die abgelehnten, und
holt nach 5, 15 und 60 Minuten den Kurs. Das Dashboard zeigt dann pro
Entscheidung die durchschnittliche Vorwärtsrendite:

| decision | 15 min | n | Ø Rendite | Treffer |
| --- | --- | --- | --- | --- |
| buy | 15 | 42 | +11 % | 57 % |
| watch | 15 | 130 | −4 % | 41 % |
| skip | 15 | 610 | −23 % | 22 % |

So sollte es aussehen, wenn die Filter etwas taugen. Wenn `buy` nicht klar
besser abschneidet als `watch` und `skip`, hat die Strategie keine Kante —
dann helfen auch keine schöneren Trades. Lass den Bot **mindestens zwei
Wochen** laufen, bevor du dem Report traust; vorher ist n zu klein.

## Ideen, die drinstecken — und die nächsten

Eingebaut:
1. Rug-Filter vor allem anderen. Das allein sortiert den Großteil der Verlierer aus.
2. „Zu früh" und „zu spät" sind beides Fehler — das Alters- und Momentum-Fenster ist eng.
3. Kaufdruck statt Kursanstieg als Signal: Käufe/Verkäufe sagt mehr als die Prozentzahl.
4. Kosten pessimistisch simulieren, damit die Zahlen auf Echtgeld übertragbar sind.
5. Kontrollgruppe mitlaufen lassen (watch/skip), sonst ist jede Gewinnkurve Zufall.

Als Nächstes sinnvoll, in dieser Reihenfolge:
- **Echtzeit-Discovery** über einen Solana-RPC/Websocket (pump.fun, Raydium) – noch schneller als GeckoTerminal, aber braucht einen RPC-Anbieter mit Websocket und ist ohne den nicht testbar. Die Feed-Schnittstelle in `bot/discovery.py` ist dafür gedacht: `discover(chains)` liefern, fertig.
- **Holder-Analyse**: Top-10-Anteil und Dev-Wallet-Verhalten direkt aus der Chain.
- **Live-Adapter** (`bot/live.py`): Jupiter-Quote + Swap, lokal signiert — erst, wenn der Edge-Report über Wochen positiv ist, und nur mit Geld, das weg sein darf.

## Projektstruktur

```
bot/
  main.py        Einstieg, Konfiguration, Dashboard-Server starten
  engine.py      Poll-Schleife: entdecken -> bewerten -> handeln -> Exits
  strategy.py    Filter und Score
  paper.py       Paper-Engine mit Gebühren, Slippage und allen Exit-Regeln
  tracker.py     Vorwärtsrenditen für den Edge-Report
  sweep.py       Rückblick: Filterwerte gegen die eigene Historie
  store.py       SQLite
  server.py      Lokales Dashboard und Steuer-API (nur 127.0.0.1)
  settings.py    Parameter-Schema: Validierung + Formular aus einer Quelle
  demo.py        Offline-Markt für Demo und Tests
  ai.py          Claude-Anbindung: zweiter Blick auf gefilterte Kandidaten
  live.py        Schnittstelle für Echtgeld — bewusst nicht implementiert
  discovery.py   Discovery-Quellen zusammenführen, Status je Quelle
  sources/       DexScreener, GeckoTerminal, RugCheck
tests/           python3 -m unittest tests.test_bot tests.test_control tests.test_ai tests.test_sources
```

## Tests

```bash
python3 -m unittest -v tests.test_bot tests.test_control tests.test_ai tests.test_sources
```

Strategie-Entscheidungen, alle Exit-Regeln, der Tracker, ein kompletter
Zyklus gegen den Demo-Markt, die Parameter-Validierung, Live-Änderungen,
manuelles Schließen, Resets und jede API-Route sind abgedeckt.

**Browser-Prüfung der Steuerseite** – klickt gegen einen laufenden Demo-Server
jede Funktion durch (Formular, Validierung, Persistenz, Schließen, Pause,
Filter, Reset), prüft auf Konsolenfehler und auf Überhang am Telefon, und legt
Screenshots in `tests/ui/shots/` ab:

```bash
python3 -m bot.main --demo --no-open --port 8797 &
npm install playwright          # einmalig, lädt Chromium
node tests/ui/verify.js
```

Der Demo-Markt listet seine Tokens jede simulierte Stunde neu (eine reale
Minute im 60×-Zeitraffer), damit dauerhaft frische Kandidaten kommen.
