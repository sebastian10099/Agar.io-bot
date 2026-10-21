"""Krypto-Desk: ein Spielgeld-Konto gegen echte Binance-Kurse.

Nimmt jeden Tag nach dem Tagesschluss (00:00 UTC) die Setups des
crypto-scanner (bot/crypto_scan.py, dieselbe Datei wie im Plugin), lässt jeden
Plan durch die crypto-timemachine laufen (bot/crypto_tm.py) und handelt ihn mit
Spielgeld: Kauf zum echten Kurs plus Schlupf und Gebühr, Stop und Ziel liegen
wie Orders an der Börse. Sie greifen auch, während der Bot aus ist: verpasste
Minutenkerzen werden beim nächsten Start nachgeholt. Spätestens nach der
Haltedauer wird verkauft. Echtes Geld bewegt hier nichts.

Zum Vergleich läuft "BTC halten" mit demselben Startbetrag mit.
"""
from __future__ import annotations

import copy
import threading
import time
from typing import Any, Callable, Optional

from . import crypto_tm as tm

scan = tm.scan

KEY = "crypto_desk"
DAY = 86400
STEP_S = 60                  # Stops und Ziele jede Minute prüfen
EQUITY_EVERY_S = 600         # ein Punkt der Kontokurve alle 10 Minuten
EQUITY_KEEP = 4000
CLOSED_KEEP = 500
SCAN_AFTER_S = 120           # zwei Minuten nach Mitternacht ist die Tageskerze sicher fertig
BACKTEST_EVERY_S = 7 * DAY
MIN_ORDER_USD = 10.0

DEFAULTS: dict[str, Any] = {
    "enabled": True,
    "start_usd": 1000.0,
    "risk_pct": 1.0,             # so viel vom Konto geht am Stop verloren (nach Gebühren)
    "max_open": 8,
    "max_position_pct": 20.0,
    "entry_window_h": 6,         # nur in den ersten Stunden nach dem Tagesschluss einsteigen, wie im Rückblick
    "top": 60,
    "min_volume": 5e6,
    "setups": list(scan.SETUPS),
    "fee_pct": scan.FEE_PCT,
    "slip_pct": scan.SLIP_PCT,
    "stop_atr": scan.STOP_ATR,
    "target_r": scan.TARGET_R,
    "hold_days": scan.HOLD_DAYS,
    "timemachine": True,
    "require_hint": False,       # nur kaufen, wenn die Zeitmaschine "Schwacher Hinweis" sagt
    "backtest": True,
    "benchmark": "BTCUSDT",
}

VERDICTS = (("Urteil: Kein Vorsprung", "kein Vorsprung"), ("Urteil: Kein klarer Vorsprung", "kein klarer Vorsprung"),
            ("Urteil: Schwacher Hinweis", "schwacher Hinweis"), ("Urteil: Simulation im Plus", "Simulation im Plus"))


def verdict_key(line: str) -> str:
    for prefix, key in VERDICTS:
        if line.startswith(prefix):
            return key
    return "ohne Zeitmaschine"


def utc_day(ts: float) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ts))


def new_book(start_usd: float, now: float) -> dict[str, Any]:
    return {"v": 1, "start_usd": float(start_usd), "cash": float(start_usd), "started_at": now, "next_id": 1,
            "positions": [], "closed": [], "equity": [], "bench_start": None, "scan_day": None,
            "last_scan": None, "backtest": None, "agg": {"setup": {}, "verdict": {}}, "last_equity_at": 0}


class CryptoDesk:
    def __init__(self, store: Any, cfg: dict[str, Any], feed: Any = None, clock: Callable[[], float] = time.time,
                 tm_run: Optional[Callable[..., dict]] = None) -> None:
        self.store = store
        self.cfg = cfg                       # the bot's whole config; the "crypto" section is read live
        self.feed = feed or scan.Feed()
        self.clock = clock
        self.tm_run = tm_run or tm.run
        self._lock = threading.RLock()
        self._force_scan = False
        self._scan_retry_at = 0.0
        self._errors: dict[str, str] = {}
        self.status = "startet"
        self.last_step = None
        book = store.get(KEY)
        self.book = book if isinstance(book, dict) and book.get("v") == 1 else new_book(self.conf()["start_usd"], clock())
        self._view: dict[str, Any] = {}
        self._refresh_view()

    # --- settings ---------------------------------------------------------
    def conf(self) -> dict[str, Any]:
        c = dict(DEFAULTS)
        c.update(self.cfg.get("crypto") or {})
        return c

    # --- money --------------------------------------------------------------
    def _value(self, pos: dict[str, Any], price: Optional[float] = None) -> float:
        """What the position would bring if sold now, after slippage and fee."""
        c = self.conf()
        p = pos["last"] if price is None else price
        return pos["qty"] * p * (1 - c["slip_pct"] / 100) * (1 - c["fee_pct"] / 100)

    def equity(self) -> float:
        return self.book["cash"] + sum(self._value(p) for p in self.book["positions"])

    def _open(self, sym: str, setup: str, price: float, stop: float, target: float, now: float,
              tmres: Optional[dict[str, Any]], late: bool) -> Optional[str]:
        """Opens a paper position; returns the reason when it does not."""
        c = self.conf()
        fee, slip = c["fee_pct"] / 100, c["slip_pct"] / 100
        if not (0 < stop < price < target):
            return "Stop/Ziel passen nicht zum Kurs"
        eq = self.equity()
        fill = price * (1 + slip)
        per_unit = fill * (1 + fee) - stop * (1 - slip) * (1 - fee)
        qty = eq * c["risk_pct"] / 100 / per_unit
        cap = min(eq * c["max_position_pct"] / 100, self.book["cash"] / (1 + fee))
        if qty * fill > cap:
            qty = cap / fill
        size = qty * fill
        if size < MIN_ORDER_USD:
            return "zu wenig freies Spielgeld"
        cost = size * (1 + fee)
        self.book["cash"] -= cost
        pid = self.book["next_id"]
        self.book["next_id"] += 1
        self.book["positions"].append({
            "id": pid, "symbol": sym, "setup": setup, "opened_at": now, "price": price, "fill": fill, "qty": qty,
            "size": size, "cost": cost, "stop": stop, "target": target, "risk_usd": qty * per_unit,
            "hold_until": now + c["hold_days"] * DAY, "checked_ms": int(now // 60 + 1) * 60_000, "last": price,
            "tm": tmres, "late": late,
        })
        self._log("trade", f"Krypto: Kauf {sym} ({scan.SETUP_NAMES.get(setup, setup)}) {size:.2f} $ zu {scan.px(price)}, "
                           f"Stop {scan.px(stop)}, Ziel {scan.px(target)}"
                           + (f" · Zeitmaschine: {tmres['verdict']}" if tmres and tmres.get("verdict") else ""))
        return None

    def _close(self, pos: dict[str, Any], price: float, reason: str, at: float) -> None:
        c = self.conf()
        proceeds = pos["qty"] * price * (1 - c["slip_pct"] / 100)
        net = proceeds * (1 - c["fee_pct"] / 100)
        pnl = net - pos["cost"]
        r = pnl / pos["risk_usd"] if pos["risk_usd"] > 0 else 0.0
        self.book["cash"] += net
        self.book["positions"] = [p for p in self.book["positions"] if p["id"] != pos["id"]]
        verdict = (pos.get("tm") or {}).get("key") or "ohne Zeitmaschine"
        done = {"id": pos["id"], "symbol": pos["symbol"], "setup": pos["setup"], "opened_at": pos["opened_at"],
                "closed_at": at, "entry": pos["price"], "exit": price, "size": pos["size"], "pnl": pnl, "r": r,
                "reason": reason, "verdict": verdict, "late": pos.get("late", False)}
        self.book["closed"].append(done)
        del self.book["closed"][:-CLOSED_KEEP]
        for group, key in (("setup", pos["setup"]), ("verdict", verdict)):
            a = self.book["agg"][group].setdefault(key, {"n": 0, "wins": 0, "pnl": 0.0, "r": 0.0})
            a["n"] += 1
            a["wins"] += pnl > 0
            a["pnl"] += pnl
            a["r"] += r
        self._log("trade", f"Krypto: Verkauf {pos['symbol']} ({reason}) {pnl:+.2f} $ = {r:+.2f} R")

    # --- one minute ---------------------------------------------------------
    def step(self, now: Optional[float] = None) -> None:
        now = self.clock() if now is None else now
        c = self.conf()
        with self._lock:
            if not c["enabled"]:
                self.status = "aus (in den Einstellungen einschalten)"
            else:
                self._check_positions(now)
                if self._scan_due(now):
                    self._daily(now)
                if now - self.book["last_equity_at"] >= EQUITY_EVERY_S:
                    self._equity_point(now)
                if c["backtest"] and self._backtest_due(now):
                    self._backtest(now)
                self._errors.pop("step", None)
                self.status = next(iter(self._errors.values()), None) or self._steady(now)
            self.last_step = now
            self.store.set(KEY, self.book)
            self._refresh_view()

    def _check_positions(self, now: float) -> None:
        now_ms = int(now * 1000)
        for pos in list(self.book["positions"]):
            try:
                rows = self.feed.klines(pos["symbol"], "1m", start_ms=pos["checked_ms"], end_ms=now_ms)
            except RuntimeError as error:
                self._error(f"kurs:{pos['symbol']}", f"Krypto: kein Kurs für {pos['symbol']} ({error})")
                continue
            self._errors.pop(f"kurs:{pos['symbol']}", None)
            rows = [k for k in scan.closed(rows, now_ms) if k[0] >= pos["checked_ms"]]
            closed = False
            for k in rows:
                t, o, h, lo, cl = k[0] / 1000, float(k[1]), float(k[2]), float(k[3]), float(k[4])
                if t >= pos["hold_until"]:
                    self._close(pos, o, "Haltedauer um", t)
                elif o <= pos["stop"]:
                    self._close(pos, o, "Stop (Kurslücke)", t)
                elif lo <= pos["stop"]:
                    self._close(pos, pos["stop"], "Stop", t)
                elif h >= pos["target"]:
                    self._close(pos, pos["target"], "Ziel", t)
                else:
                    pos["last"] = cl
                    pos["checked_ms"] = k[0] + 60_000
                    continue
                closed = True
                break
            if not closed and now >= pos["hold_until"] + 300 and not rows:
                self._close(pos, pos["last"], "Haltedauer um", now)

    def _scan_due(self, now: float) -> bool:
        if self._force_scan:
            return True
        if now < self._scan_retry_at:
            return False
        day_start = now - now % DAY
        if self.book["scan_day"] == utc_day(now) or now - day_start < SCAN_AFTER_S:
            return False
        return now - day_start <= self.conf()["entry_window_h"] * 3600

    def _daily(self, now: float) -> None:
        c = self.conf()
        late = now - (now - now % DAY) > c["entry_window_h"] * 3600
        self._force_scan = False
        self._busy(f"scannt die Top {c['top']} Coins …")
        try:
            rows, skipped = scan.universe(self.feed, int(c["top"]), float(c["min_volume"]))
            symbols = [r["symbol"] for r in rows]
            hits, failed = scan.daily_scan(self.feed, symbols, int(now * 1000), c["stop_atr"], c["target_r"],
                                           int(c["hold_days"]))
        except RuntimeError as error:
            self._error("scan", f"Krypto-Scan fehlgeschlagen, neuer Versuch in 10 Minuten: {error}")
            self._scan_retry_at = now + 600
            return
        self._errors.pop("scan", None)
        self.book["scan_day"] = utc_day(now)
        taken, passed = [], []
        held = {p["symbol"] for p in self.book["positions"]}
        for h in hits:
            setup = next((s for s in h["setups"] if s in c["setups"]), None)
            why = None
            if setup is None:
                why = "Setup abgeschaltet"
            elif h["symbol"] in held:
                why = "schon im Depot"
            elif len(self.book["positions"]) >= int(c["max_open"]):
                why = f"schon {c['max_open']} offen"
            tmres = None
            if why is None:
                at = self.clock()                    # the scan and the time machine take minutes: price it now
                price = self._price(h["symbol"], at)
                if price is None:
                    why = "kein aktueller Kurs"
            if why is None:
                pl = h["plan"]
                atr = (pl["entry"] - pl["stop"]) / pl["stop_atr"]
                stop = price - c["stop_atr"] * atr
                target = price + c["target_r"] * (price - stop)
                plan = {"symbol": h["symbol"], "rule": "daily:" + setup, "entry": price, "stop": stop, "target": target,
                        "target_r": c["target_r"], "stop_atr": c["stop_atr"], "hold_days": c["hold_days"]}
                tmres = self._timemachine(plan, now) if c["timemachine"] else None
                if c["require_hint"] and (tmres or {}).get("key") != "schwacher Hinweis":
                    why = "Zeitmaschine sieht keinen Vorsprung"
                else:
                    why = self._open(h["symbol"], setup, price, stop, target, at, tmres, late)
            row = {"symbol": h["symbol"], "setups": h["setups"], "close": h["close"], "rsi": h.get("rsi"),
                   "verdict": (tmres or {}).get("verdict")}
            if why:
                passed.append({**row, "why": why})
            else:
                taken.append(row)
                held.add(h["symbol"])
        self.book["last_scan"] = {"at": now, "day": utc_day(now), "scanned": len(symbols), "hits": len(hits),
                                  "taken": taken, "passed": passed, "failed": len(failed), "skipped": skipped}
        self._log("info", f"Krypto-Scan: {len(hits)} von {len(symbols)} Coins mit Setup, {len(taken)} gekauft"
                          + (" (außerhalb des Einstiegsfensters, von Hand ausgelöst)" if late else ""))

    def _price(self, sym: str, now: float) -> Optional[float]:
        """The close of the last finished minute before now."""
        try:
            rows = scan.closed(self.feed.klines(sym, "1m", end_ms=int(now * 1000), limit=3), int(now * 1000))
        except RuntimeError:
            return None
        return float(rows[-1][4]) if rows else None

    def _timemachine(self, plan: dict[str, Any], now: float) -> dict[str, Any]:
        c = self.conf()
        args = tm.parser().parse_args(["run", "--fee", str(c["fee_pct"]), "--slip", str(c["slip_pct"])])
        try:
            doc = self.tm_run(args, self.feed, int(now), plan=plan)
        except SystemExit as error:            # the tool refuses in one line (too little data, a gap)
            return {"key": "ohne Zeitmaschine", "verdict": f"nicht gelaufen: {error}"}
        except RuntimeError as error:
            return {"key": "ohne Zeitmaschine", "verdict": f"nicht gelaufen: {error}"}
        mc, same = doc["mc"], (doc.get("history") or {}).get("same") or {}
        line = (doc.get("verdict") or [""])[0]
        return {"key": verdict_key(line), "verdict": line.replace("Urteil: ", ""), "avg_r": round(mc["avg_r"], 3),
                "target_first": round(mc["target_first"], 3), "stop_first": round(mc["stop_first"], 3),
                "hist_n": same.get("n", 0), "hist_r": round(same.get("avg_r", 0.0), 3), "hist_t": round(same.get("t", 0.0), 2)}

    def _equity_point(self, now: float) -> None:
        c = self.conf()
        bench = self._price(c["benchmark"], now)
        if bench and not self.book["bench_start"]:
            self.book["bench_start"] = bench
        bvalue = self.book["start_usd"] * bench / self.book["bench_start"] if bench and self.book["bench_start"] else None
        pts = self.book["equity"]
        pts.append([round(now), round(self.equity(), 2), round(bvalue, 2) if bvalue else None])
        if len(pts) > EQUITY_KEEP:               # thin out the older half, keep the recent detail
            half = len(pts) // 2
            pts[:half] = pts[:half:2]
        self.book["last_equity_at"] = now

    def _backtest_due(self, now: float) -> bool:
        bt = self.book.get("backtest")
        return not bt or now - bt.get("at", 0) >= BACKTEST_EVERY_S

    def _backtest(self, now: float) -> None:
        c = self.conf()
        self._busy("Rückblick über bis zu 1000 Tage läuft (etwa eine Minute) …")
        try:
            rows, _ = scan.universe(self.feed, int(c["top"]), float(c["min_volume"]))
            trades, _ = scan.backtest(self.feed, [r["symbol"] for r in rows], int(now * 1000), 1000, int(c["hold_days"]),
                                      c["stop_atr"], c["target_r"], c["fee_pct"], c["slip_pct"])
        except RuntimeError as error:
            self._error("backtest", f"Krypto-Rückblick fehlgeschlagen: {error}")
            self.book["backtest"] = {"at": now - BACKTEST_EVERY_S + 6 * 3600, "table": [], "error": str(error)}
            return
        stamps = sorted(r[0] for r in trades["alle_tage"])
        split = stamps[len(stamps) // 2] if stamps else None
        base = scan.summarize(trades["alle_tage"], split)
        table = []
        for s in scan.SETUPS + ("alle_tage",):
            row = scan.summarize(trades[s], split)
            row["setup"] = s
            row["name"] = scan.SETUP_NAMES.get(s, "jeder Tag (Vergleich)")
            if s != "alle_tage" and row["n"]:
                row["urteil"] = scan.judge(row, base)
            table.append(row)
        self.book["backtest"] = {"at": now, "coins": len(rows), "table": table}
        self._log("info", "Krypto-Rückblick (1000 Tage) aktualisiert")

    def _steady(self, now: float) -> str:
        c, ls = self.conf(), self.book["last_scan"]
        done = self.book["scan_day"] == utc_day(now) or now - (now - now % DAY) > c["entry_window_h"] * 3600
        first = (f"letzter Scan {ls['day']}: {ls['hits']} Setups, {len(ls['taken'])} gekauft" if ls else "noch kein Scan")
        return f"läuft · {first} · nächster Scan {'morgen' if done else 'heute'} 00:02 UTC"

    def _busy(self, what: str) -> None:
        """Shows a long step on the page while it runs."""
        self.status = what
        self._refresh_view()

    # --- logging ------------------------------------------------------------
    def _log(self, level: str, message: str) -> None:
        try:
            self.store.log(level, message)
        except Exception:  # noqa: BLE001 - the log must never stop the desk
            pass

    def _error(self, key: str, message: str) -> None:
        if self._errors.get(key) != message:      # once per distinct problem, not every minute
            self._log("error", message)
        self._errors[key] = message
        self.status = message

    # --- controls -------------------------------------------------------------
    def scan_now(self) -> dict[str, Any]:
        self._force_scan = True
        return {"ok": True}

    def reset(self, start_usd: Optional[float] = None) -> dict[str, Any]:
        start = float(start_usd or self.conf()["start_usd"])
        if not 10 <= start <= 1e9:
            return {"ok": False, "error": "Startbetrag zwischen 10 und 1.000.000.000 $"}
        if not self._lock.acquire(timeout=3):          # a scan is running: do not hold the page for minutes
            return {"ok": False, "error": "Der Krypto-Desk scannt gerade – in einer Minute noch einmal"}
        try:
            keep = self.book.get("backtest")
            self.book = new_book(start, self.clock())
            self.book["backtest"] = keep
            self.store.set(KEY, self.book)
            self._log("info", f"Krypto-Konto neu begonnen mit {start:.2f} $ Spielgeld")
            self._refresh_view()
        finally:
            self._lock.release()
        return {"ok": True}

    # --- loop -------------------------------------------------------------------
    def run(self, wait: Callable[[float], bool]) -> None:
        """wait(seconds) returns True when the bot stops."""
        while True:
            try:
                self.step()
            except Exception as error:  # noqa: BLE001 - keep the desk alive
                self._error("step", f"Krypto-Desk: {type(error).__name__}: {error}")
            if wait(STEP_S):
                return

    # --- what the dashboard shows ----------------------------------------------
    def view(self) -> dict[str, Any]:
        return self._view

    def _refresh_view(self) -> None:
        b, c = self.book, self.conf()
        eq = self.equity()
        positions = []
        for p in b["positions"]:
            value = self._value(p)
            positions.append({**{k: p[k] for k in ("id", "symbol", "setup", "opened_at", "price", "size", "stop", "target",
                                                    "hold_until", "last", "risk_usd")},
                              "setup_name": scan.SETUP_NAMES.get(p["setup"], p["setup"]),
                              "gain_pct": (p["last"] / p["price"] - 1) * 100, "unrealized": value - p["cost"],
                              "tm": p.get("tm"), "late": p.get("late", False)})
        closed = b["closed"]
        wins = sum(1 for t in closed if t["pnl"] > 0)
        bench_last = next((pt[2] for pt in reversed(b["equity"]) if pt[2]), None)
        pts = b["equity"]
        if len(pts) > 400:
            stride = len(pts) / 400
            pts = [pts[int(i * stride)] for i in range(400)] + [pts[-1]]
        peak, dd = 0.0, 0.0
        for _, v, _b in b["equity"]:
            peak = max(peak, v)
            dd = max(dd, (peak - v) / peak if peak else 0.0)
        agg = {g: [{"key": k, "name": scan.SETUP_NAMES.get(k, k), "n": a["n"], "win_rate": a["wins"] / a["n"],
                    "pnl": a["pnl"], "avg_r": a["r"] / a["n"]} for k, a in sorted(b["agg"][g].items())]
               for g in ("setup", "verdict")}
        self._view = copy.deepcopy({
            "enabled": c["enabled"], "status": self.status, "last_step": self.last_step,
            "start_usd": b["start_usd"], "started_at": b["started_at"], "cash": b["cash"], "equity": eq,
            "pnl": eq - b["start_usd"], "pnl_pct": (eq / b["start_usd"] - 1) * 100,
            "bench": c["benchmark"], "bench_value": bench_last,
            "bench_pct": (bench_last / b["start_usd"] - 1) * 100 if bench_last else None,
            "max_drawdown_pct": dd * 100, "positions": positions, "max_open": c["max_open"],
            "closed": list(reversed(closed[-40:])), "closed_n": len(closed),
            "win_rate": wins / len(closed) if closed else None,
            "avg_r": sum(t["r"] for t in closed) / len(closed) if closed else None,
            "curve": pts, "by_setup": agg["setup"], "by_verdict": agg["verdict"],
            "last_scan": b["last_scan"], "backtest": b.get("backtest"),
            "config": {k: c[k] for k in ("risk_pct", "max_open", "entry_window_h", "fee_pct", "slip_pct", "stop_atr",
                                          "target_r", "hold_days", "timemachine", "require_hint")},
        })
