/*
 * CandleChart - Kerzen-Chart (gruen/rot) auf einem <canvas>, ohne Abhaengigkeiten.
 *
 * Einbinden:   <script src="candle-chart.js"></script>   (oder require/import in Node-Bundlern)
 * Aufrufen:    CandleChart.draw(canvas, {
 *                candles,        // [{t: unix-Sekunden, o, h, l, c}, ...]  aelteste zuerst
 *                positions,      // optional: [{id, side: "long"|"short", entry_price, stop_loss, take_profit, opened_ts}]
 *                moves,          // optional: [{window_minutes, direction: "up"|"down", triggered}]
 *                candleMinutes,  // optional, Standard 1
 *                hoverX,         // optional: Mausposition (offsetX) fuer Fadenkreuz
 *                tooltip,        // optional: HTMLElement fuer OHLC-Tooltip (position:absolute im selben Container)
 *              });
 *
 * Das Canvas muss per CSS eine Groesse haben (z.B. width:100%; height:460px);
 * der Chart passt sich daran und an devicePixelRatio an. Farben kommen aus den
 * CSS-Variablen --up, --down, --grid, --muted, --accent (mit Fallbacks) oder
 * aus options.colors.
 */
(function (root) {
  "use strict";

  const FALLBACK = { up: "#16a34a", down: "#dc2626", grid: "#e5e7eb", muted: "#6b7280", accent: "#2563eb", label: "#ffffff" };

  function cssColors(el) {
    const style = getComputedStyle(el);
    const out = {};
    for (const key of Object.keys(FALLBACK)) {
      out[key] = style.getPropertyValue("--" + key).trim() || FALLBACK[key];
    }
    return out;
  }

  function fmtPrice(p) {
    if (p == null || !isFinite(p)) return "–";
    const digits = p >= 1000 ? 2 : p >= 1 ? 4 : p >= 0.01 ? 6 : 8;
    return p.toLocaleString("de-DE", { minimumFractionDigits: Math.min(digits, 2), maximumFractionDigits: digits });
  }

  const fmtTime = (t) => new Date(t * 1000).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" });

  // "Schoene" Achsenschritte (1, 2, 2.5, 5 x 10^n), damit Preislabels lesbar bleiben.
  function niceStep(range, ticks) {
    const raw = range / Math.max(1, ticks);
    const mag = Math.pow(10, Math.floor(Math.log10(raw)));
    const norm = raw / mag;
    const nice = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10;
    return nice * mag;
  }

  // Y-Bereich aus ALLEN Dochten + Positionslinien -> der ganze Kursverlauf bleibt im Bild.
  function priceRange(candles, positions) {
    let lo = Infinity, hi = -Infinity;
    for (const c of candles) { lo = Math.min(lo, c.l); hi = Math.max(hi, c.h); }
    for (const p of positions) {
      lo = Math.min(lo, p.stop_loss, p.take_profit, p.entry_price);
      hi = Math.max(hi, p.stop_loss, p.take_profit, p.entry_price);
    }
    if (hi === lo) { hi *= 1.001; lo *= 0.999; }
    const pad = (hi - lo) * 0.08;
    return [lo - pad, hi + pad];
  }

  function draw(canvas, options) {
    const opts = options || {};
    const candles = opts.candles || [];
    const positions = opts.positions || [];
    const span = opts.candleMinutes || 1;
    const col = Object.assign(cssColors(canvas), opts.colors || {});
    const tip = opts.tooltip || null;

    const dpr = root.devicePixelRatio || 1;
    const W = canvas.clientWidth, H = canvas.clientHeight;
    if (canvas.width !== Math.round(W * dpr) || canvas.height !== Math.round(H * dpr)) {
      canvas.width = Math.round(W * dpr);
      canvas.height = Math.round(H * dpr);
    }
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    ctx.font = "11px system-ui, sans-serif";
    ctx.lineWidth = 1;
    if (!candles.length) {
      ctx.fillStyle = col.muted;
      ctx.fillText("Noch keine Kursdaten …", 12, 20);
      if (tip) tip.style.display = "none";
      return;
    }

    const [lo, hi] = priceRange(candles, positions);
    const step = niceStep(hi - lo, Math.max(3, Math.floor(H / 60)));
    const labels = [];
    for (let v = Math.ceil(lo / step) * step; v <= hi; v += step) labels.push(v);
    const last = candles[candles.length - 1];
    // Rechter Rand breit genug fuer das laengste Preislabel.
    const axisW = Math.ceil(Math.max(...labels.map((v) => ctx.measureText(fmtPrice(v)).width),
      ctx.measureText(fmtPrice(last.c)).width)) + 16;
    const left = 4, top = 8, bottom = 22;
    const plotW = W - left - axisW, plotH = H - top - bottom;
    const y = (v) => top + (hi - v) / (hi - lo) * plotH;
    const slot = plotW / candles.length;
    const x = (i) => left + slot * (i + 0.5);
    const body = Math.max(1, Math.min(14, slot * 0.7));

    // Raster + Preisachse
    ctx.strokeStyle = col.grid; ctx.fillStyle = col.muted;
    ctx.textBaseline = "middle"; ctx.textAlign = "left";
    for (const v of labels) {
      const yy = Math.round(y(v)) + 0.5;
      ctx.beginPath(); ctx.moveTo(left, yy); ctx.lineTo(left + plotW, yy); ctx.stroke();
      ctx.fillText(fmtPrice(v), left + plotW + 6, yy);
    }
    // Zeitachse (von rechts, nichts ragt links aus dem Bild)
    ctx.textAlign = "center"; ctx.textBaseline = "top";
    const every = Math.max(1, Math.ceil(70 / slot));
    for (let i = candles.length - 1; i >= 0; i -= every) {
      const label = fmtTime(candles[i].t);
      if (x(i) - ctx.measureText(label).width / 2 < left) break;
      ctx.fillText(label, x(i), H - bottom + 6);
    }

    // Analyse-Fenster (6/8/20/60 min) als Schattierung von rechts
    const windows = (opts.moves || []).slice().sort((a, b) => b.window_minutes - a.window_minutes);
    windows.forEach((m, k) => {
      const n = Math.min(candles.length, Math.ceil(m.window_minutes / span));
      const x0 = left + slot * (candles.length - n);
      ctx.fillStyle = m.triggered ? (m.direction === "up" ? col.up : col.down) : col.muted;
      ctx.globalAlpha = m.triggered ? 0.08 : 0.035;
      ctx.fillRect(x0, top, left + plotW - x0, plotH);
      ctx.globalAlpha = 0.7;
      ctx.textAlign = "left"; ctx.textBaseline = "top";
      ctx.fillText(m.window_minutes + "m", x0 + 3, top + 2 + 13 * k); // gestaffelt, damit 6m/8m lesbar bleiben
    });
    ctx.globalAlpha = 1;

    // Kerzen: gruen = Schluss >= Eroeffnung, rot = Schluss < Eroeffnung
    candles.forEach((c, i) => {
      const color = c.c >= c.o ? col.up : col.down;
      const cx = Math.round(x(i)) + 0.5;
      ctx.strokeStyle = color; ctx.fillStyle = color;
      ctx.beginPath(); ctx.moveTo(cx, y(c.h)); ctx.lineTo(cx, y(c.l)); ctx.stroke();
      const yo = y(c.o), yc = y(c.c);
      ctx.fillRect(cx - body / 2, Math.min(yo, yc), body, Math.max(1, Math.abs(yc - yo)));
    });

    // Offene Positionen: Einstieg, Stop-Loss, Take-Profit
    const hline = (v, color, label, dash) => {
      const yy = Math.round(y(v)) + 0.5;
      ctx.setLineDash(dash); ctx.strokeStyle = color;
      ctx.beginPath(); ctx.moveTo(left, yy); ctx.lineTo(left + plotW, yy); ctx.stroke();
      ctx.setLineDash([]); ctx.fillStyle = color; ctx.textAlign = "left"; ctx.textBaseline = "bottom";
      ctx.fillText(label, left + 4, yy - 2);
    };
    for (const p of positions) {
      hline(p.entry_price, col.accent, "#" + p.id + " " + String(p.side).toUpperCase(), [4, 3]);
      if (p.stop_loss != null) hline(p.stop_loss, col.down, "SL #" + p.id, [2, 3]);
      if (p.take_profit != null) hline(p.take_profit, col.up, "TP #" + p.id, [2, 3]);
      const i = candles.findIndex((c) => c.t + span * 60 > p.opened_ts);
      if (i >= 0) {
        ctx.fillStyle = col.accent;
        const yy = y(p.entry_price), dir = p.side === "long" ? 1 : -1;
        ctx.beginPath(); ctx.moveTo(x(i), yy); ctx.lineTo(x(i) - 5, yy + 9 * dir); ctx.lineTo(x(i) + 5, yy + 9 * dir); ctx.fill();
      }
    }

    // Aktueller Kurs als Label an der Achse
    const yl = Math.round(y(last.c)) + 0.5;
    ctx.fillStyle = last.c >= last.o ? col.up : col.down;
    ctx.fillRect(left + plotW + 1, yl - 8, axisW - 2, 16);
    ctx.fillStyle = col.label; ctx.textAlign = "left"; ctx.textBaseline = "middle";
    ctx.fillText(fmtPrice(last.c), left + plotW + 6, yl);

    // Fadenkreuz + Tooltip
    const hoverX = opts.hoverX;
    if (hoverX != null && hoverX >= left && hoverX <= left + plotW) {
      const i = Math.min(candles.length - 1, Math.max(0, Math.floor((hoverX - left) / slot)));
      const c = candles[i];
      ctx.strokeStyle = col.muted; ctx.setLineDash([3, 3]);
      ctx.beginPath(); ctx.moveTo(Math.round(x(i)) + 0.5, top); ctx.lineTo(Math.round(x(i)) + 0.5, top + plotH); ctx.stroke();
      ctx.setLineDash([]);
      if (tip) {
        const chg = (c.c - c.o) / c.o * 100;
        tip.innerHTML = fmtTime(c.t) + "<br>O " + fmtPrice(c.o) + " H " + fmtPrice(c.h) +
          "<br>L " + fmtPrice(c.l) + " C " + fmtPrice(c.c) +
          '<br><span style="color:' + (chg >= 0 ? col.up : col.down) + '">' + (chg >= 0 ? "+" : "") + chg.toFixed(2) + "%</span>";
        tip.style.display = "block";
        const tx = x(i) + 12, tw = tip.offsetWidth;
        tip.style.left = (tx + tw > W ? x(i) - tw - 12 : tx) + "px";
        tip.style.top = top + 4 + "px";
      }
    } else if (tip) {
      tip.style.display = "none";
    }
  }

  const api = { draw, fmtPrice, niceStep, priceRange };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  root.CandleChart = api;
})(typeof window !== "undefined" ? window : globalThis);
