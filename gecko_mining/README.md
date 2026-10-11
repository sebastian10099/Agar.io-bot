# Gecko Mining Board

Paper-Trading-Bot fuer Mining-Coins auf Basis der CoinGecko-API, mit Web-Dashboard
(Kerzen-Chart gruen/rot) und Erkennung von Anstiegen/Faellen in den letzten
**6, 8, 20 und 60 Minuten**. Nur Python-Standardbibliothek, keine Installation noetig.

## Starten

```bash
# Demo mit simulierten Kursen (Zeitraffer, ohne API)
python -m gecko_mining dashboard --demo
# -> http://127.0.0.1:8050

# Echte Kurse von CoinGecko
export GECKO_API_KEY="dein-key"      # Demo-Key: GECKO_API_PLAN=demo (Standard)
export GECKO_API_PLAN=demo           # oder "pro" fuer einen bezahlten Key
python -m gecko_mining dashboard

# Nur der Bot ohne Webseite (schreibt gecko_state.json)
python -m gecko_mining run
```

Optionen: `--max-positions 10`, `--mode reversal|momentum`, `--poll 20`,
`GECKO_COINS="bitcoin,kaspa,monero"`.

## Wie der Bot handelt

1. Jeder Durchlauf holt per `/simple/price` alle Kurse (1 Request) und baut daraus
   1-Minuten-Kerzen. Beim Start wird `/market_chart?days=1` als Verlauf geladen.
2. Pro Fenster (6/8/20/60 min) wird gemessen, ob der Kurs vom Tief bis zum Hoch
   gelaufen ist (**Anstieg**) oder vom Hoch zum Tief (**Fall**).
   Schwellen: 1,5 % / 2 % / 3 % / 5 % (`move_threshold_pct` in `config.py`).
3. `mode="reversal"` (Standard): nach einem Anstieg wird **geshortet**, sobald die
   erste rote Kerze kommt; nach einem Fall wird long gegangen, sobald eine gruene
   Kerze kommt. Ist die Gegenbewegung schon zu >60 % gelaufen, wird nicht mehr eingestiegen.
   `mode="momentum"`: mit der Bewegung handeln (Anstieg long, Fall short).
4. Jede Position hat Stop-Loss (1,5 %), Take-Profit (3 %) und eine max. Haltedauer (120 min).
5. Bis zu **10 Positionen** gleichzeitig (`max_open_positions`), max. 2 pro Coin, keine
   Gegenposition auf demselben Coin.

## Tests

```bash
python -m unittest discover -s tests -t .
```
