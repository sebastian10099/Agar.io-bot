---
name: crypto-scanner
description: >-
  Krypto-Scanner. Durchsucht die liquidesten Krypto-Paare auf Binance (USDT,
  nur Spot, nur Long) nach Setups: 20-Tage-Ausbruch, Bullenflagge, zurück über
  den 20-Tage-Schnitt, überverkauft, Abprall aus überverkauft, und den
  Ausbruch aus der Eröffnungsspanne des UTC-Tages auf 5-Minuten-Kerzen.
  Filtert Stablecoins, Fiat, Gold, Wrapper, Hebel-Token und Binances
  Aktien-Token heraus. Schreibt crypto/watchlist.json mit einem Plan (Einstieg,
  Stop, Ziel) je Treffer für /crypto-timemachine. Mit "backtest" prüft er, ob
  jedes Setup früher nach Gebühren Geld gebracht hätte. Kostenlose Binance-
  Daten, kein Schlüssel. Verwenden, wenn der Nutzer sagt "scanne Krypto",
  "welche Coins brechen aus", "Krypto-Setups", "was soll ich mir heute
  ansehen", "überverkaufte Coins", "Krypto-Watchlist", "lohnt sich das Setup",
  "scan crypto", "find crypto setups", "crypto breakouts", oder am Anfang
  eines Krypto-Tages vor /crypto-timemachine.
argument-hint: "[universe | daily | orb | backtest] [--top N]"
---

# crypto-scanner

Der erste Schritt eines Krypto-Trades. Er liest kostenlose Binance-Kerzen und
listet die Paare, auf die eine Regel passt. Mehr tut er nicht. Ein Treffer ist
keine Kaufempfehlung und keine Prognose. Die meisten Leute, die kurzfristig
traden, verlieren Geld; der Scanner ändert daran nichts. Er erspart nur das
Durchblättern von hundert Charts.

`${CLAUDE_SKILL_DIR}` ist der Ordner dieses Skills (hier liegt diese SKILL.md).

```bash
python3 "${CLAUDE_SKILL_DIR}/scan.py" universe                 # -> crypto/universe.txt (Top 60 nach 24h-Umsatz)
python3 "${CLAUDE_SKILL_DIR}/scan.py" daily                    # -> crypto/watchlist.json (letzte fertige Tageskerze)
python3 "${CLAUDE_SKILL_DIR}/scan.py" daily --symbols BTC,ETH,SOL
python3 "${CLAUDE_SKILL_DIR}/scan.py" orb                      # Ausbruch aus der ersten Stunde ab 00:00 UTC
python3 "${CLAUDE_SKILL_DIR}/scan.py" orb --open 13:30 --or-minutes 30   # ab US-Börsenöffnung
python3 "${CLAUDE_SKILL_DIR}/scan.py" backtest                 # -> crypto/backtest.json, Setups nach Gebühren
```

Weitere Schalter: `--top 60`, `--min-volume 5000000`, `--exclude PEPE,TRUMP`,
`--keep KÜRZEL` (gegen einen falschen Filter), `--fresh` (Universum neu laden),
`--stop-atr 1.5`, `--target-r 2`, `--hold 10` (Tage), `--stop-rule mid|low`
(orb), `--fee 0.10` und `--slip 0.05` (Prozent je Seite), `--now "2026-10-21 19:30"`
(UTC), `--offline ORDNER`, `--json`, `--no-write`, `--show N`. Exit-Code 0, wenn
etwas gefunden wurde, sonst 1 (der Grund steht in einer Zeile).

## Was er liest und schreibt

| Datei | Inhalt |
| --- | --- |
| Binance `/api/v3/ticker/24hr`, `/exchangeInfo`, `/klines` | über `data-api.binance.vision`, Ersatz `api.binance.com` |
| `crypto/universe.txt` | `SYMBOL\|24h-Umsatz` je Zeile; `daily`, `orb` und `backtest` lesen sie |
| `crypto/watchlist.json` | `mode`, `as_of`, `scanned`, `failed`, `hits[]` mit `plan` je Treffer |
| `crypto/backtest.json` | die Tabelle aus `backtest` |

## Das Universum

Alle USDT-Paare mit Status TRADING und mindestens 5 Mio $ Umsatz in 24 h,
sortiert nach Umsatz, die ersten 60. Raus fliegen:

1. Stablecoins, Fiat, Gold und eingewickelte Doppelgänger (USDC, FDUSD, EUR,
   PAXG, XAUT, WBTC …) und jedes Paar, das 24 h lang zwischen 0,985 und
   1,015 $ blieb.
2. Hebel-Token (…UP, …DOWN, …BULL, …BEAR).
3. Aktien-Token: Binance führt NVDAB, TSLAB, SPCXB und rund 100 weitere in der
   Handelsgruppe `TRD_GRP_261`. Dazu, falls die Gruppe fehlt: Kürzel auf B,
   Kurs ab 1 $, nicht BNB oder TRB. `--keep` hebt das für ein Kürzel auf.

## Die Setups (auf der letzten fertigen Tageskerze, UTC)

| Setup | Regel |
| --- | --- |
| 20-Tage-Ausbruch | Schluss über allen Schlüssen der 20 Tage davor |
| Bullenflagge | +20 % in den 10 Tagen vor der Flagge, dann 5 Tage enge Spanne (höchstens halb so groß wie der Anstieg), Schluss 90–102 % vom Flaggenbeginn |
| zurück über den 20-Tage-Schnitt | gestern darunter, heute darüber |
| überverkauft | RSI(14) ≤ 30 |
| Abprall aus überverkauft | gestern RSI ≤ 30, heute steigender RSI und grüne Kerze |

Plan je Treffer: Einstieg = Schluss, Stop = Einstieg − 1,5 × ATR(14), Ziel =
2 R, höchstens 10 Tage halten.

`orb`: Die Eröffnungsspanne ist die erste Stunde ab 00:00 UTC (`--open`,
`--or-minutes`). Ausgelöst ist der erste fertige 5-Minuten-Schluss über dem
Spannenhoch. Stop = Spannenmitte (oder Spannentief), Ziel = 2 R. Er sagt auch,
ob seit dem Auslösen schon Stop oder Ziel getroffen wurde, und welche Paare
noch knapp darunter warten.

## Der Rückblick (`backtest`)

Jedes Setup auf jeder Tageskerze der letzten bis zu 1000 Tage und jedem Coin
im Universum: Einstieg zur nächsten Tageseröffnung, Stop und Ziel wie oben,
sonst raus nach 10 Tagen. Ein Tag, der Stop und Ziel berührt, zählt als Stop;
ein Sprung unter den Stop füllt zur Eröffnung, das Ziel füllt nie besser als
zum Zielpreis. Alles in R nach Gebühr und Schlupf (0,10 % + 0,05 % je Seite):
der Stop ist genau −1 R, ein 2-R-Ziel bringt etwas weniger als 2.

Die Tabelle zeigt je Setup: Fälle, verschiedene Tage, Ziel %, Stop %, Ø R,
einen t-Wert über die Tagesmittel (Fälle am selben Tag hängen zusammen, weil
der ganze Markt gemeinsam fällt) und Ø R in der ersten und zweiten Hälfte der
Zeit. Die letzte Zeile ist der Vergleich "jeder Tag": dieselbe Stop/Ziel-Regel
ohne Setup. Ein Setup gilt nur dann als "positiv in beiden Hälften", wenn es
mindestens 30 Fälle hat, in beiden Hälften über Null liegt, den Vergleich
schlägt und t ≥ 2 erreicht.

Wichtig: Das Universum sind die Coins, die heute noch handeln. Abgestürzte
und delistete Coins fehlen. Das schönt besonders "kaufen nach Kursrutsch"
(überverkauft, Abprall). Sag das dem Nutzer, wenn ein solches Setup gut
aussieht.

## Schritte

1. `universe`, dann `daily` (oder `orb` im Tagesverlauf).
2. Dem Nutzer die Treffer nennen: Paar, Setup, Schluss, RSI, ATR, Plan.
3. Vor jeder Entscheidung `backtest` zeigen, wenn er heute noch nicht lief:
   die Zeile des Setups und die Vergleichszeile. Verliert das Setup nach
   Gebühren, sag es klar.
4. Für einen Treffer, den der Nutzer ernst nimmt: `/crypto-timemachine`.

## Regeln

- Jede Zahl kommt aus dem Lauf. Nie ein knappes Ergebnis zu einem Vorsprung
  aufrunden.
- Eine Trefferliste ist keine Kaufliste. Sag einmal klar, dass es keine
  Prognose ist.
- Nur Spot, nur Long. Kein Hebel, keine Futures, kein Leerverkauf.
- Kostenlose Daten können haken. Kerzen, nicht jeder Tick.

## Was er nie tut

Er platziert keine Order, kennt keinen API-Schlüssel, bewegt kein Geld und
nennt keinen Treffer sicher.
