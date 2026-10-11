# Einbau in deinen eigenen GoMining-Bot

Diese Anleitung zeigt, was du in **deinen selbst programmierten GoMining-Bot** uebernimmst.
Jeder Schritt ist unabhaengig - du kannst sie einzeln einbauen und testen.

| Datei hier | Was sie macht | Fuer welchen Bot |
|---|---|---|
| `gecko_mining/static/candle-chart.js` | Kerzen-Chart gruen/rot, alles im Bild | jeder Bot mit Web-Oberflaeche |
| `gecko_mining/js/movement.js` | Kerzen bauen, Anstieg/Fall 6/8/20/60 min, Short-Signal, 10 Positionen | Bot in JavaScript/Node |
| `gecko_mining/strategy.py`, `positions.py`, `data.py` | dasselbe in Python | Bot in Python |
| `tests/movement.test.js`, `tests/test_gecko_mining.py` | Tests dazu | |

---

## Schritt 1 - 10 statt 4 Positionen

Such in deinem Bot die Stelle, an der auf 4 begrenzt wird. Typische Muster:

```text
MAX_POSITIONS = 4          maxPositions: 4          if len(positions) >= 4
if (openTrades.length >= 4)          max_open_trades = 4
```

Aendere die `4` auf `10`. **Pruefe danach das Kapital:** Wenn eine Position z.B. 100 $
bindet, brauchst du mindestens 10 x 100 $ plus Puffer fuer Verluste. Sonst blockiert
"nicht genug Kapital" schon vor der 10. Position. (Hier: 2000 $ Startkapital bei 100 $
pro Position.) Zusaetzlich sinnvoll: hoechstens 2 Positionen pro Coin, keine Long- und
Short-Position gleichzeitig auf demselben Coin.

---

## Schritt 2 - Kerzen-Chart (gruen/rot)

1. `candle-chart.js` in deinen Web-Ordner kopieren.
2. Im HTML:

```html
<div style="position:relative; height:460px">
  <canvas id="chart" style="position:absolute; inset:0; width:100%; height:100%"></canvas>
  <div id="tip" style="position:absolute; display:none; pointer-events:none"></div>
</div>
<script src="candle-chart.js"></script>
```

3. Zeichnen, wann immer neue Kurse da sind:

```js
let hoverX = null;
function zeichne() {
  CandleChart.draw(document.getElementById("chart"), {
    candles,            // [{t: unixSekunden, o, h, l, c}, ...]  aelteste zuerst
    positions,          // optional: offene Positionen -> Einstieg/SL/TP-Linien
    moves,              // optional: Ergebnis von analyze() -> 6/8/20/60-min-Schattierung
    candleMinutes: 1,
    hoverX,
    tooltip: document.getElementById("tip"),
  });
}
const cv = document.getElementById("chart");
cv.addEventListener("mousemove", (e) => { hoverX = e.offsetX; zeichne(); });
cv.addEventListener("mouseleave", () => { hoverX = null; zeichne(); });
new ResizeObserver(zeichne).observe(cv.parentElement);
```

**Warum der Kursverlauf vorher nicht ganz im Bild war:** Meist wird die Y-Achse nur aus den
Schlusskursen berechnet, die Dochte (Hoch/Tief) ragen dann oben und unten raus. Oder das
Canvas hat eine feste Pixelgroesse. `candle-chart.js` nimmt Hoch/Tief **aller** Kerzen plus
SL/TP-Linien, gibt 8 % Rand dazu, passt sich der Containergroesse und dem
`devicePixelRatio` an und macht den rechten Rand so breit wie das laengste Preislabel.

Hast du nur einzelne Preise und keine Kerzen? Dann baust du sie mit `buildCandles` (Schritt 3).

Farben stellst du ueber CSS-Variablen ein: `--up` (gruen), `--down` (rot), `--grid`, `--muted`, `--accent`.

---

## Schritt 3 - Anstiege/Faelle erkennen und shorten

### JavaScript-Bot

`movement.js` kopieren, dann in deiner Bot-Schleife (jeder Durchlauf / jeder Poll):

```js
const M = require("./movement.js");
const pm = new M.PositionManager({ maxOpenPositions: 10 });   // ersetzt dein bisheriges Limit
const ticks = {};               // coin -> [[unixSek, preis], ...]
const letzteSignalKerze = {};   // coin -> Kerzenzeit (nur 1 Signal pro Kerze)

function durchlauf(preise /* {BTC: 64000, ...} */) {
  const jetzt = Date.now() / 1000;
  for (const [coin, preis] of Object.entries(preise)) {
    (ticks[coin] ||= []).push([jetzt, preis]);
    ticks[coin] = ticks[coin].filter(([t]) => t > jetzt - 120 * 60);   // 2 h behalten

    const candles = M.buildCandles(ticks[coin], 60);
    const last = candles.at(-1);
    pm.checkExits(coin, last.h, last.l, last.c, jetzt);               // SL / TP / Haltedauer

    const signal = M.generateSignal(coin, candles);                   // null | {side, reason, ...}
    if (!signal || letzteSignalKerze[coin] === last.t) continue;
    letzteSignalKerze[coin] = last.t;
    const grund = pm.canOpen(signal);
    if (grund) { console.log("uebersprungen:", coin, grund); continue; }
    pm.open(signal);
    // >>> hier deine echte Order-Funktion aufrufen, z.B. placeOrder(coin, signal.side, ...)
  }
}
```

### Python-Bot

`strategy.py`, `positions.py`, `data.py` und `config.py` in deinen Bot kopieren, dann:

```python
from config import BotConfig
from data import build_candles
from strategy import generate_signal
from positions import PositionManager

cfg = BotConfig(max_open_positions=10)
pm = PositionManager(cfg)

candles = build_candles(ticks_fuer_coin, 60)
last = candles[-1]
pm.check_exits(coin, last.high, last.low, last.close, jetzt)
signal = generate_signal(coin, candles, cfg)
if signal and pm.can_open(signal) is None:
    pm.open(signal)
    # >>> hier deine echte Order-Funktion
```

Wenn deine Dateien schon `config.py` o.ae. heissen, die Module umbenennen und die
Imports anpassen. Die relativen Imports (`from .config import ...`) dann auf normale
Imports umstellen.

### Was die Logik macht

- Pro Fenster (6, 8, 20, 60 min) wird geprueft: Lag das **Tief vor dem Hoch** (Anstieg) oder
  das **Hoch vor dem Tief** (Fall), und wie gross war die Bewegung?
- Schwellen: 1,5 % / 2 % / 3 % / 5 %. Laengere Fenster brauchen groessere Bewegungen.
- `mode: "reversal"` (Standard): Nach einem Anstieg wird **geshortet**, aber erst bei der
  ersten **roten Kerze**, also nicht in den laufenden Anstieg hinein. Nach einem Fall wird
  bei der ersten gruenen Kerze long gegangen. Ist die Gegenbewegung schon zu ueber 60 %
  gelaufen, gibt es keinen Einstieg mehr.
- `mode: "momentum"`: mit der Bewegung handeln (Anstieg -> long, Fall -> short).
- Nur Shorts: `allowLong: false` (Python: `allow_long=False`).
- Von mehreren ausgeloesten Fenstern gewinnt das staerkste (Bewegung / Schwelle).

Alle Werte stehen in `DEFAULTS` (JS) bzw. `BotConfig` (Python).

---

## Schritt 4 - API-Key

Der Key gehoert nicht in den Code, sondern in eine Umgebungsvariable:

```bash
export GECKO_API_KEY="..."     # Windows: set GECKO_API_KEY=...
```

Im Code: `os.environ["GECKO_API_KEY"]` (Python) bzw. `process.env.GECKO_API_KEY` (Node).
Holt dein Bot die Kurse woanders her (GoMining, Boerse ...), uebergibst du einfach die Preise
an `durchlauf(...)` / `build_candles(...)`. Die Logik braucht nur Zeit und Preis.

---

## Schritt 5 - Testen

```bash
node --test tests/movement.test.js          # JS-Logik
python -m unittest discover -s tests -t .   # Python-Logik
python -m gecko_mining dashboard --demo     # Chart + Bot mit simulierten Kursen ansehen
```

Die Tests pruefen unter anderem: Kerzenbau, Anstieg in 6 min erkannt, Short erst nach roter
Kerze, kein Signal im ruhigen Markt, 10 Positionen erlaubt und die 11. abgelehnt, PnL bei
Short, SL hat Vorrang vor TP. Fuer deinen Bot: Kopier die Tests mit und pass nur den
`require`/`import`-Pfad an.

**Vor echtem Geld:** erst einige Tage nur Signale loggen (ohne `placeOrder`) und mit dem
Chart vergleichen, dann mit kleiner Positionsgroesse starten.
