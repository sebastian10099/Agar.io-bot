---
name: crypto-timemachine
description: >-
  Krypto-Zeitmaschine. Spielt einen Krypto-Plan (Einstieg, Stop, Ziel) 10.000-mal
  durch, bevor Geld fließt: baut die nächsten Stunden aus den eigenen Kerzen des
  Coins zur selben Tageszeit nach (5-Minuten-Kerzen der letzten 30 Tage, bei
  längeren Haltedauern Stundenkerzen der letzten 120 Tage), neutralisiert den
  Trend der letzten Wochen, rechnet jedes Ergebnis nach Gebühren und Schlupf in R
  und vergleicht mit der echten Historie derselben Regel. Gibt Ziel zuerst, Stop
  zuerst, weder noch, im Plus, Kursspanne, Ø R und ein ehrliches Urteil aus.
  Verwenden, wenn der Nutzer sagt "Zeitmaschine", "spiel den Trade durch", "wie
  stehen die Chancen", "Krypto-Prognose", "lohnt sich der Trade", "Monte Carlo",
  "run the time machine", "what are the odds", "simulate this crypto trade",
  oder nach /crypto-scanner.
argument-hint: "[--pick SYMBOL|N] oder [--symbol BTC --stop-pct 3 --target-r 2]"
---

# crypto-timemachine

Die Zeitmaschine steht zwischen dem Plan und dem Geld. Der Scanner hat einen
Plan geschrieben (Einstieg, Stop, Ziel). Sie fragt: Wenn die nächsten Stunden
so verlaufen wie die letzten Wochen dieses Coins, wie oft trifft der Plan
zuerst das Ziel, zuerst den Stop, oder keins von beiden, und was bleibt nach
Gebühren übrig? Sie ist eine Simulation aus den eigenen Kerzen des Coins,
keine Vorhersage.

`${CLAUDE_SKILL_DIR}` ist der Ordner dieses Skills. Er braucht
`crypto-scanner` im Nachbarordner (beide zusammen installieren).

```bash
python3 "${CLAUDE_SKILL_DIR}/timemachine.py" run                 # Plan 1 aus crypto/watchlist.json
python3 "${CLAUDE_SKILL_DIR}/timemachine.py" run --pick SOL      # Plan für SOLUSDT
python3 "${CLAUDE_SKILL_DIR}/timemachine.py" run --pick 3 --write
python3 "${CLAUDE_SKILL_DIR}/timemachine.py" run --symbol BTC --stop-pct 2 --target-r 2 --hours 24
python3 "${CLAUDE_SKILL_DIR}/timemachine.py" run --symbol ETH --entry 3000 --stop 2900 --target 3200
```

Weitere Schalter: `--hours N` (ORB 24, Tages-Setups ihre Haltedauer),
`--interval auto|5m|1h`, `--days N`, `--window N`, `--replays 10000`,
`--seed 19`, `--fee 0.10`, `--slip 0.05`, `--keep-drift` (Trend nicht
neutralisieren), `--now "2026-10-21 19:30"` (UTC), `--offline ORDNER`,
`--json`, `--write` (-> crypto/timemachine.json).

## So rechnet sie

1. **Der Pool.** Bis 24 h: die 5-Minuten-Kerzen der letzten 30 Tage; darüber:
   Stundenkerzen der letzten 120 Tage. Jede Kerze wird zu vier Verhältnissen
   zum vorigen Schluss (Eröffnung, Hoch, Tief, Schluss), sortiert nach
   Tageszeit (UTC). Kerzen nach einer Datenlücke und alles ab jetzt bleiben
   draußen.
2. **Trend neutral.** Der mittlere Anstieg pro Kerze der letzten Wochen wird
   herausgerechnet (die Ausgabe nennt ihn). Sonst würde ein Coin, der zuletzt
   stark stieg, in der Simulation einfach weitersteigen. Mit `--keep-drift`
   bleibt er drin; sag dann dazu, dass Trends selten so weiterlaufen.
3. **Eine Wiederholung.** Start beim Einstieg. Für jede kommende Kerze zieht
   sie zufällig eine Kerze derselben Tageszeit (±2 Fünf-Minuten- oder ±1
   Stundenkerze). Erst Stop, dann Ziel; eine Kerze, die beides berührt, zählt
   als Stop. Eine Eröffnung unter dem Stop füllt zur Eröffnung (schlechter).
4. **R nach Gebühren.** Kauf zu Einstieg × (1 + Schlupf) × (1 + Gebühr),
   Verkauf zu Preis × (1 − Schlupf) × (1 − Gebühr). Der Stop ist genau −1 R,
   ein 2-R-Ziel bringt nach Gebühren weniger (die Ausgabe nennt den Wert).
5. **Die Historie.** ORB-Plan: dieselbe Spannen-Regel an jedem der letzten 30
   Tage. Tages-Setup: dasselbe Setup auf bis zu 1000 echten Tageskerzen des
   Coins, dazu der Vergleich "jeder Tag mit derselben Stop/Ziel-Regel". Eigener
   Plan: jeden Tag zur selben Uhrzeit mit denselben Abständen.
6. **Das Urteil** steht zuerst auf dem Erwartungswert nach Gebühren:
   - "Kein Vorsprung", wenn die Simulation im Mittel −0,05 R oder schlechter
     ist und die Historie keinen Vorteil zeigt.
   - "Schwacher Hinweis, keine Gewissheit", wenn die Historie mindestens 30
     Fälle hat, im Mittel ≥ +0,05 R bringt und den Vergleich um ≥ 0,05 R
     schlägt, während die Simulation nicht negativ ist.
   - Sonst "Kein klarer Vorsprung".
   Darunter: wie viele der entschiedenen Wiederholungen zuerst das Ziel trafen
   und wo die Gewinnschwelle läge, und ein Hinweis, wenn über 40 % weder Stop
   noch Ziel trafen.

**Der Seed.** `random.Random(19)`: gleicher Plan, gleiche Daten, gleicher
Seed, gleiche Zahlen. Den Seed immer mit nennen.

## Schritte

1. Prüfen, dass `crypto/watchlist.json` von heute ist, sonst erst
   `/crypto-scanner`.
2. `timemachine.py run --pick …` (oder ein eigener Plan mit `--symbol`).
3. Dem Nutzer in dieser Reihenfolge sagen: Plan und Ziel-R nach Gebühren, die
   vier Anteile, die Kursspanne, Ø R, die Historie, dann die Urteilszeilen
   genau wie gedruckt. Seed nennen.
4. Wenn das Urteil "Kein Vorsprung" oder "Kein klarer Vorsprung" lautet, das
   klar sagen. Nicht schönreden. Wenn Historie und Simulation sich
   widersprechen, auch das sagen.
5. Einmal sagen: Das ist aus den letzten Wochen gebaut und keine Vorhersage.
   Nachrichten, Listings, Hacks und Liquidationswellen können Dinge tun, die
   diese Wochen nie taten.

## Regeln

- Jede Zahl kommt aus dem Lauf. Nie einen Münzwurf zu einem Vorsprung
  aufrunden.
- Die Urteilszeilen druckt das Werkzeug. Wiederholen, nicht umschreiben.
- Simulierte Chancen sind keine Zusagen.
- Ein Plan je Lauf. Neuer Einstieg, Stop oder Ziel heißt neuer Lauf.

## Was sie nie tut

Sie platziert keine Order, bemisst keine Positionsgröße, ändert keinen Plan,
nennt nichts sicher und nennt keinen Gewinn in Euro oder Dollar.
