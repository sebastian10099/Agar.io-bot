/*
 * JavaScript-Version der Bot-Logik aus strategy.py / positions.py / data.py,
 * zum Einbauen in einen bestehenden JS/Node-Bot.  Keine Abhaengigkeiten.
 *
 *   const M = require("./movement.js");
 *   const candles = M.buildCandles(ticks, 60);            // ticks: [[unixSek, preis], ...]
 *   const signal  = M.generateSignal("BTC", candles);      // null oder {side: "short"|"long", ...}
 *   const pm = new M.PositionManager();                    // max. 10 offene Positionen
 *   if (signal && !pm.canOpen(signal)) pm.open(signal);
 *   pm.checkExits("BTC", last.h, last.l, last.c, nowSek);  // bei jeder neuen Kerze
 */
"use strict";

const DEFAULTS = Object.freeze({
  candleMinutes: 1,
  windowsMinutes: [6, 8, 20, 60],
  moveThresholdPct: [1.5, 2.0, 3.0, 5.0],
  mode: "reversal", // "reversal": Pump -> short, Dump -> long | "momentum": mit der Bewegung
  allowLong: true,
  allowShort: true,
  requireConfirmation: true,
  maxOpenPositions: 10,
  maxPositionsPerCoin: 2,
  positionSizeUsd: 100,
  startingCapitalUsd: 2000,
  takeProfitPct: 3.0,
  stopLossPct: 1.5,
  maxHoldMinutes: 120,
  feePct: 0.1,
});

const withDefaults = (cfg) => Object.assign({}, DEFAULTS, cfg || {});

/* --- Kerzen ------------------------------------------------------------ */

// Fasst [ts, preis]-Ticks zu {t,o,h,l,c}-Kerzen zusammen. Luecken werden mit
// flachen Kerzen gefuellt, damit "letzte 6 Minuten" wirklich 6 Kerzen sind.
function buildCandles(ticks, candleSeconds) {
  if (!(candleSeconds > 0)) throw new Error("candleSeconds muss > 0 sein");
  const ordered = ticks.filter(([, p]) => Number.isFinite(p) && p > 0).sort((a, b) => a[0] - b[0]);
  const out = [];
  let cur = null;
  for (const [ts, price] of ordered) {
    const start = Math.floor(ts / candleSeconds) * candleSeconds;
    if (!cur) { cur = { t: start, o: price, h: price, l: price, c: price }; continue; }
    if (start === cur.t) {
      cur.h = Math.max(cur.h, price); cur.l = Math.min(cur.l, price); cur.c = price;
      continue;
    }
    out.push(cur);
    for (let gap = cur.t + candleSeconds; gap < start; gap += candleSeconds) {
      out.push({ t: gap, o: cur.c, h: cur.c, l: cur.c, c: cur.c });
    }
    // Neue Kerze eroeffnet am vorherigen Schluss -> durchgehender Verlauf.
    cur = { t: start, o: cur.c, h: Math.max(cur.c, price), l: Math.min(cur.c, price), c: price };
  }
  if (cur) out.push(cur);
  return out;
}

/* --- Bewegungserkennung ------------------------------------------------ */

// Misst in den letzten windowCandles Kerzen, ob der Kurs vom Tief zum Hoch
// (Anstieg) oder vom Hoch zum Tief (Fall) gelaufen ist.
function measureWindow(candles, windowCandles, windowMinutes, thresholdPct) {
  if (windowCandles < 2 || candles.length < 2) return null;
  const recent = candles.slice(-windowCandles);
  let lowI = 0, highI = 0;
  recent.forEach((c, i) => {
    if (c.l < recent[lowI].l) lowI = i;
    if (c.h > recent[highI].h) highI = i;
  });
  const low = recent[lowI].l, high = recent[highI].h, close = recent[recent.length - 1].c;
  if (low <= 0 || high <= low) return null;
  let up;
  if (lowI !== highI) up = lowI < highI;
  else up = recent[highI].c >= recent[highI].o; // Hoch und Tief in derselben Kerze
  const move = up
    ? { direction: "up", movePct: (high - low) / low * 100, retracePct: (high - close) / (high - low) * 100, startPrice: low, extremePrice: high }
    : { direction: "down", movePct: (high - low) / high * 100, retracePct: (close - low) / (high - low) * 100, startPrice: high, extremePrice: low };
  move.windowMinutes = windowMinutes;
  move.thresholdPct = thresholdPct;
  move.strength = move.movePct / thresholdPct;
  move.triggered = move.movePct >= thresholdPct;
  return move;
}

function analyze(candles, cfg) {
  const c = withDefaults(cfg);
  const moves = [];
  c.windowsMinutes.forEach((minutes, k) => {
    const n = Math.max(2, Math.ceil(minutes / c.candleMinutes));
    const m = measureWindow(candles, n, minutes, c.moveThresholdPct[k]);
    if (m) moves.push(m);
  });
  return moves;
}

function sideFor(move, c) {
  if (c.mode === "reversal") return move.direction === "up" ? "short" : "long";
  return move.direction === "up" ? "long" : "short";
}

function confirmed(move, last, side, c) {
  if (c.mode === "reversal") {
    if (!c.requireConfirmation) return true;
    const green = last.c >= last.o;
    if (side === "short" && green) return false; // nicht in den laufenden Pump shorten
    if (side === "long" && !green) return false;
    return move.retracePct <= 60; // Gegenbewegung schon groesstenteils gelaufen -> zu spaet
  }
  return move.retracePct <= 33;
}

// Staerkstes ausgeloestes Fenster -> ein Signal, sonst null.
function generateSignal(coin, candles, cfg) {
  const c = withDefaults(cfg);
  if (candles.length < 2) return null;
  const last = candles[candles.length - 1];
  let best = null;
  for (const move of analyze(candles, c)) {
    if (!move.triggered) continue;
    const side = sideFor(move, c);
    if ((side === "long" && !c.allowLong) || (side === "short" && !c.allowShort)) continue;
    if (!confirmed(move, last, side, c)) continue;
    if (!best || move.strength > best.move.strength) {
      const label = move.direction === "up" ? "Anstieg +" : "Fall -";
      best = { coin, side, price: last.c, ts: last.t, move,
               reason: `${label}${move.movePct.toFixed(2)}% in ${move.windowMinutes} min` };
    }
  }
  return best;
}

/* --- Positionen -------------------------------------------------------- */

function pnl(pos, price, feePct) {
  const dir = pos.side === "long" ? 1 : -1;
  const gross = (price - pos.entry_price) * pos.quantity * dir;
  return gross - (pos.entry_price + price) * pos.quantity * (feePct || 0) / 100;
}

class PositionManager {
  constructor(cfg) {
    this.cfg = withDefaults(cfg);
    this.positions = [];
    this.realizedPnl = 0;
    this._nextId = 1;
  }

  openPositions(coin) {
    return this.positions.filter((p) => p.exit_price == null && (coin == null || p.coin === coin));
  }

  freeSlots() { return Math.max(0, this.cfg.maxOpenPositions - this.openPositions().length); }

  // null wenn eroeffnet werden darf, sonst der Grund dagegen.
  canOpen(signal) {
    const c = this.cfg;
    if (this.freeSlots() <= 0) return `Maximum von ${c.maxOpenPositions} offenen Positionen erreicht`;
    const same = this.openPositions(signal.coin);
    if (same.length >= c.maxPositionsPerCoin) return `Maximum von ${c.maxPositionsPerCoin} Positionen fuer ${signal.coin} erreicht`;
    if (same.some((p) => p.side !== signal.side)) return `Gegenposition auf ${signal.coin} offen`;
    const margin = this.openPositions().reduce((s, p) => s + p.entry_price * p.quantity, 0);
    if (c.startingCapitalUsd + this.realizedPnl - margin < c.positionSizeUsd) return "Nicht genug freies Kapital";
    if (!(signal.price > 0)) return "Ungueltiger Preis";
    return null;
  }

  open(signal) {
    const why = this.canOpen(signal);
    if (why) throw new Error(why);
    const c = this.cfg, price = signal.price;
    const sl = c.stopLossPct / 100, tp = c.takeProfitPct / 100;
    const long = signal.side === "long";
    const pos = {
      id: this._nextId++, coin: signal.coin, side: signal.side, entry_price: price,
      quantity: c.positionSizeUsd / price, opened_ts: signal.ts,
      stop_loss: long ? price * (1 - sl) : price * (1 + sl),
      take_profit: long ? price * (1 + tp) : price * (1 - tp),
      reason: signal.reason, exit_price: null, closed_ts: null, exit_reason: "",
    };
    this.positions.push(pos);
    return pos;
  }

  close(pos, price, ts, reason) {
    if (pos.exit_price != null) throw new Error(`Position ${pos.id} ist bereits geschlossen`);
    pos.exit_price = price; pos.closed_ts = ts; pos.exit_reason = reason;
    const result = pnl(pos, price, this.cfg.feePct);
    this.realizedPnl += result;
    return result;
  }

  // SL/TP/Haltedauer gegen die letzte Kerze; liegen SL und TP beide drin, gilt der SL.
  checkExits(coin, high, low, close, ts) {
    const closed = [];
    for (const pos of this.openPositions(coin)) {
      const long = pos.side === "long";
      const hitSl = long ? low <= pos.stop_loss : high >= pos.stop_loss;
      const hitTp = long ? high >= pos.take_profit : low <= pos.take_profit;
      if (hitSl) this.close(pos, pos.stop_loss, ts, "Stop-Loss");
      else if (hitTp) this.close(pos, pos.take_profit, ts, "Take-Profit");
      else if (ts - pos.opened_ts >= this.cfg.maxHoldMinutes * 60) this.close(pos, close, ts, "Max. Haltedauer");
      else continue;
      closed.push(pos);
    }
    return closed;
  }
}

module.exports = { DEFAULTS, buildCandles, measureWindow, analyze, generateSignal, PositionManager, pnl };
