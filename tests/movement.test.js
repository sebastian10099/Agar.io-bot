// Tests fuer gecko_mining/js/movement.js - ausfuehren: node --test tests/movement.test.js
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const M = require("../gecko_mining/js/movement.js");

const T0 = 1_700_000_000 - (1_700_000_000 % 60);

function candlesFromCloses(closes) {
  let prev = closes[0];
  return closes.map((c, i) => {
    const k = { t: T0 + 60 * i, o: prev, h: Math.max(prev, c), l: Math.min(prev, c), c };
    prev = c;
    return k;
  });
}

const flat = (n) => Array(n).fill(100);

test("buildCandles: OHLC, gruen/rot und Luecken", () => {
  const c = M.buildCandles([[T0, 10], [T0 + 20, 12], [T0 + 40, 9], [T0 + 59, 11], [T0 + 180, 8]], 60);
  assert.deepEqual(c[0], { t: T0, o: 10, h: 12, l: 9, c: 11 });
  assert.equal(c.length, 4);
  assert.deepEqual(c[1], { t: T0 + 60, o: 11, h: 11, l: 11, c: 11 });
  assert.ok(c[3].c < c[3].o); // rote Kerze
});

test("Anstieg von unten nach oben in 6 Minuten wird erkannt", () => {
  const m = M.measureWindow(candlesFromCloses([...flat(30), 100, 100.5, 101, 101.5, 102, 102.5]), 6, 6, 1.5);
  assert.equal(m.direction, "up");
  assert.ok(Math.abs(m.movePct - 2.5) < 1e-9);
  assert.equal(m.triggered, true);
});

test("alle Fenster 6/8/20/60 werden gemessen", () => {
  const closes = Array.from({ length: 90 }, (_, i) => 100 + 0.1 * i);
  assert.deepEqual(M.analyze(candlesFromCloses(closes)).map((m) => m.windowMinutes), [6, 8, 20, 60]);
});

test("Pump + rote Kerze -> SHORT", () => {
  const s = M.generateSignal("BTC", candlesFromCloses([...flat(30), 100, 101, 102, 103, 104, 103.6]));
  assert.equal(s.side, "short");
  assert.match(s.reason, /Anstieg/);
});

test("kein Short in den laufenden Pump", () => {
  assert.equal(M.generateSignal("BTC", candlesFromCloses([...flat(30), 100, 101, 102, 103, 104, 105])), null);
});

test("Dump + gruene Kerze -> LONG, momentum dreht die Richtung", () => {
  assert.equal(M.generateSignal("BTC", candlesFromCloses([...flat(30), 100, 99, 98, 97, 96, 96.4])).side, "long");
  const up = candlesFromCloses([...flat(30), 100, 101, 102, 103, 104, 105]);
  assert.equal(M.generateSignal("BTC", up, { mode: "momentum" }).side, "long");
});

test("ruhiger Markt -> kein Signal", () => {
  assert.equal(M.generateSignal("BTC", candlesFromCloses(flat(90))), null);
});

const sig = (coin, side = "short", price = 100) => ({ coin, side, price, ts: T0, reason: "test" });

test("standardmaessig 10 offene Positionen erlaubt, die 11. wird abgelehnt", () => {
  assert.equal(M.DEFAULTS.maxOpenPositions, 10);
  const pm = new M.PositionManager();
  for (let i = 0; i < 10; i++) pm.open(sig("c" + i));
  assert.equal(pm.openPositions().length, 10);
  assert.match(pm.canOpen(sig("c10")), /Maximum von 10/);
  assert.throws(() => pm.open(sig("c10")));
});

test("Short: Take-Profit bei fallendem Kurs, SL hat Vorrang", () => {
  const pm = new M.PositionManager({ feePct: 0, stopLossPct: 2, takeProfitPct: 4 });
  const pos = pm.open(sig("BTC", "short", 100));
  assert.ok(Math.abs(pos.stop_loss - 102) < 1e-9 && Math.abs(pos.take_profit - 96) < 1e-9);
  assert.equal(pm.checkExits("BTC", 100, 95.5, 96, T0 + 60)[0].exit_reason, "Take-Profit");
  assert.ok(Math.abs(pm.realizedPnl - 4) < 1e-9);

  const pm2 = new M.PositionManager({ feePct: 0, stopLossPct: 2, takeProfitPct: 4 });
  pm2.open(sig("BTC", "long", 100));
  assert.equal(pm2.checkExits("BTC", 105, 97, 100, T0 + 60)[0].exit_reason, "Stop-Loss");
});

test("keine Gegenposition und max. 2 pro Coin", () => {
  const pm = new M.PositionManager();
  pm.open(sig("BTC"));
  assert.match(pm.canOpen(sig("BTC", "long")), /Gegenposition/);
  pm.open(sig("BTC"));
  assert.match(pm.canOpen(sig("BTC")), /fuer BTC/);
});

test("JS- und Python-Version liefern dasselbe Signal", () => {
  // gleiche Kursreihe wie SignalTest.test_reversal_shorts_pump_after_red_candle in Python
  const s = M.generateSignal("kaspa", candlesFromCloses([...flat(30), 100, 101, 102, 103, 104, 103.6]));
  assert.equal(s.move.windowMinutes, 6);
  assert.ok(Math.abs(s.move.movePct - 4) < 1e-9);
});
