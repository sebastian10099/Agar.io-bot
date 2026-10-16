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

## Wie der Bot entscheidet

```
DexScreener (neue Tokens)  ->  Harte Filter  ->  Score 0-100  ->  buy / watch / skip
                                   |                                   |
                               RugCheck                          Tracker: was wurde
                                                                 5/15/60 min später daraus?
```

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
- **Echtzeit-Discovery** über einen Solana-RPC/Websocket (pump.fun, Raydium) statt der DexScreener-Profile — schneller, aber braucht einen RPC-Anbieter.
- **Parameter-Sweep** auf den gesammelten Daten: welche Filterwerte hätten im Rückblick die beste `buy`-Rendite gebracht?
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
  store.py       SQLite
  server.py      Lokales Dashboard (nur 127.0.0.1)
  demo.py        Offline-Markt für Demo und Tests
  live.py        Schnittstelle für Echtgeld — bewusst nicht implementiert
  sources/       DexScreener, RugCheck
tests/           python3 -m unittest tests.test_bot
```

## Tests

```bash
python3 -m unittest -v tests.test_bot
```

Strategie-Entscheidungen, alle Exit-Regeln, der Tracker, ein kompletter
Zyklus gegen den Demo-Markt und das Dashboard sind abgedeckt.
