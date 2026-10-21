#!/usr/bin/env python3
"""Krypto-Scanner: findet Setups auf den liquidesten Binance-USDT-Paaren.

Nur Standardbibliothek, kein API-Schlüssel. Daten: Binance Public Market Data
(https://data-api.binance.vision, Ersatz: https://api.binance.com).

  scan.py universe              -> crypto/universe.txt  (Top-Paare nach 24h-Umsatz)
  scan.py daily                 -> crypto/watchlist.json (Setups auf der letzten fertigen Tageskerze)
  scan.py orb                   -> crypto/watchlist.json (Ausbruch aus der Eröffnungsspanne des UTC-Tages)
  scan.py backtest              -> wie oft hat jedes Setup früher nach Gebühren verdient?

Eine Trefferliste ist keine Kaufliste und keine Prognose. Alle R-Werte sind
nach Gebühren und Schlupf gerechnet: der Stop ist genau -1 R.
"""
import argparse
import concurrent.futures
import datetime
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOSTS = ("https://data-api.binance.vision", "https://api.binance.com")
UA = "crypto-skills/1.0 (+https://github.com/sebastian10099/Agar.io-bot)"
PAUSE = 0.12          # Sekunden zwischen Anfragen
WORKERS = 4           # gleichzeitige Anfragen
QUOTE = "USDT"
DAY = 86400
OUT_DIR = "crypto"
FEE_PCT = 0.10        # Binance Spot, Taker, ohne BNB-Rabatt
SLIP_PCT = 0.05
STOP_ATR = 1.5
TARGET_R = 2.0
HOLD_DAYS = 10
MIN_CASES = 30

# Stablecoins, Fiat, Gold und eingewickelte Doppelgänger: kein Krypto-Risiko, das man handeln will.
NOT_CRYPTO = {
    "USDC", "USD1", "RLUSD", "FDUSD", "TUSD", "DAI", "USDP", "PYUSD", "USDE", "USDS", "BUSD",
    "BFUSD", "XUSD", "RWUSD", "USDF", "USDQ", "U", "EUR", "EURI", "AEUR", "GBP", "TRY", "BRL",
    "ARS", "MXN", "JPY", "PLN", "RON", "ZAR", "UAH", "COP", "CZK", "PAXG", "XAUT",
    "WBTC", "WBETH", "BETH", "STETH", "WSTETH", "BNSOL",
}
# Echte Coins, deren Kürzel auf B endet und die mehr als 1 $ kosten.
CRYPTO_B = {"BNB", "TRB"}
# Binance führt Aktien-Token (NVDAB, TSLAB ...) in dieser Handelsgruppe.
STOCK_GROUP = "TRD_GRP_261"
LEVERAGED = ("UP", "DOWN", "BULL", "BEAR")


# --------------------------------------------------------------------------- Daten

class Feed:
    """Binance-Endpunkte; mit offline=DIR liest es gespeicherte Dateien."""

    def __init__(self, offline=None, pause=PAUSE):
        self.offline = offline
        self.pause = pause
        self.requests = 0

    def _get(self, path, params):
        query = urllib.parse.urlencode(params)
        last = None
        for host in HOSTS:
            url = f"{host}{path}?{query}" if query else f"{host}{path}"
            for attempt in range(3):
                try:
                    req = urllib.request.Request(url, headers={"User-Agent": UA})
                    with urllib.request.urlopen(req, timeout=25) as r:
                        self.requests += 1
                        if self.pause:
                            time.sleep(self.pause)
                        return json.loads(r.read().decode("utf-8"))
                except urllib.error.HTTPError as e:
                    last = e
                    if e.code in (418, 429):
                        time.sleep(5 * (attempt + 1))
                        continue
                    break
                except (urllib.error.URLError, TimeoutError, OSError) as e:
                    last = e
                    time.sleep(1 + attempt)
        raise RuntimeError(f"Binance nicht erreichbar ({path}): {last}")

    def _file(self, name):
        path = os.path.join(self.offline, name)
        if not os.path.exists(path):
            raise RuntimeError(f"offline: {path} fehlt")
        with open(path, encoding="utf-8") as f:
            return json.load(f)

    def tickers(self):
        return self._file("ticker24hr.json") if self.offline else self._get("/api/v3/ticker/24hr", {})

    def exchange_info(self):
        if self.offline:
            path = os.path.join(self.offline, "exchangeInfo.json")
            return self._file("exchangeInfo.json") if os.path.exists(path) else None
        try:
            return self._get("/api/v3/exchangeInfo", {"permissions": "SPOT"})
        except RuntimeError:
            return None

    def klines(self, symbol, interval, start_ms=None, end_ms=None, limit=1000):
        """Kerzen [openTime, o, h, l, c, v, closeTime, quoteVolume, ...], seitenweise."""
        if self.offline:
            rows = self._file(f"{symbol}_{interval}.json")
            return [k for k in rows if (start_ms is None or k[0] >= start_ms) and (end_ms is None or k[0] <= end_ms)]
        out = []
        params = {"symbol": symbol, "interval": interval, "limit": limit}
        if start_ms is None:
            if end_ms is not None:
                params["endTime"] = int(end_ms)
            return self._get("/api/v3/klines", params)
        cursor = int(start_ms)
        while True:
            params["startTime"] = cursor
            if end_ms is not None:
                params["endTime"] = int(end_ms)
            page = self._get("/api/v3/klines", params)
            out.extend(page)
            if len(page) < limit:
                return out
            cursor = page[-1][0] + 1


def fetch_all(feed, symbols, load, workers=WORKERS):
    """load(sym) für alle Paare, mit wenigen Threads; liefert [(sym, rows | None, Fehler | None)] in Reihenfolge."""
    def one(sym):
        try:
            return sym, load(sym), None
        except RuntimeError as e:
            return sym, None, str(e)
    if feed.offline or workers <= 1:
        return [one(s) for s in symbols]
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        return list(ex.map(one, symbols))


def closed(rows, now_ms):
    """Nur fertige Kerzen: closeTime liegt vor jetzt."""
    return [k for k in rows if k[6] < now_ms]


def bars(rows):
    """Kerzen als Spalten."""
    return {
        "t": [int(k[0]) // 1000 for k in rows],
        "o": [float(k[1]) for k in rows],
        "h": [float(k[2]) for k in rows],
        "l": [float(k[3]) for k in rows],
        "c": [float(k[4]) for k in rows],
        "qv": [float(k[7]) for k in rows],
    }


# --------------------------------------------------------------------------- Universum

def is_stablelike(t):
    try:
        hi, lo = float(t["highPrice"]), float(t["lowPrice"])
    except (KeyError, TypeError, ValueError):
        return False
    return 0.985 <= lo and hi <= 1.015


def stock_bases(info):
    if not info:
        return set()
    out = set()
    for s in info.get("symbols", []):
        groups = set(sum(s.get("permissionSets") or [], [])) | set(s.get("permissions") or [])
        if STOCK_GROUP in groups:
            out.add(s.get("baseAsset"))
    return out


def trading_symbols(info):
    if not info:
        return None
    return {s["symbol"] for s in info.get("symbols", []) if s.get("status") == "TRADING"}


def why_out(base, t, stocks, extra_excl=()):
    """Grund, warum ein Paar kein Krypto ist, sonst None."""
    if base in extra_excl:
        return "ausgeschlossen"
    if base in NOT_CRYPTO or is_stablelike(t):
        return "Stablecoin/Fiat/Gold/Wrapper"
    if base.endswith(LEVERAGED) and len(base) > 4:
        return "Hebel-Token"
    if base in stocks:
        return "Aktien-Token"
    try:
        price = float(t["lastPrice"])
    except (KeyError, TypeError, ValueError):
        price = 0.0
    if base.endswith("B") and len(base) >= 3 and price >= 1 and base not in CRYPTO_B:
        return "Aktien-Token (vermutlich)"
    return None


def universe(feed, top=60, min_volume=5e6, exclude=(), keep=()):
    tickers = feed.tickers()
    info = feed.exchange_info()
    stocks = stock_bases(info) - set(keep)
    live = trading_symbols(info)
    rows, skipped = [], {}
    for t in tickers:
        sym = t.get("symbol", "")
        if not sym.endswith(QUOTE) or (live is not None and sym not in live):
            continue
        base = sym[: -len(QUOTE)]
        qv = float(t.get("quoteVolume") or 0)
        if qv < min_volume:
            continue
        reason = None if base in keep else why_out(base, t, stocks, set(exclude))
        if reason:
            skipped[reason] = skipped.get(reason, 0) + 1
            continue
        rows.append({"symbol": sym, "base": base, "volume": qv,
                     "price": float(t.get("lastPrice") or 0),
                     "change_pct": float(t.get("priceChangePercent") or 0)})
    rows.sort(key=lambda r: -r["volume"])
    return rows[:top], skipped


def read_universe(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line.split("|")[0])
    return out


# --------------------------------------------------------------------------- Indikatoren

def sma(xs, n, i):
    if i + 1 < n:
        return None
    return sum(xs[i - n + 1:i + 1]) / n


def rsi_series(c, n=14):
    out = [None] * len(c)
    if len(c) <= n:
        return out
    gains = losses = 0.0
    for i in range(1, n + 1):
        d = c[i] - c[i - 1]
        gains += max(d, 0)
        losses += max(-d, 0)
    ag, al = gains / n, losses / n
    out[n] = 100.0 if al == 0 else 100 - 100 / (1 + ag / al)
    for i in range(n + 1, len(c)):
        d = c[i] - c[i - 1]
        ag = (ag * (n - 1) + max(d, 0)) / n
        al = (al * (n - 1) + max(-d, 0)) / n
        out[i] = 100.0 if al == 0 else 100 - 100 / (1 + ag / al)
    return out


def atr_series(h, l, c, n=14):
    out = [None] * len(c)
    if len(c) <= n:
        return out
    tr = [h[0] - l[0]] + [max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1])) for i in range(1, len(c))]
    a = sum(tr[1:n + 1]) / n
    out[n] = a
    for i in range(n + 1, len(c)):
        a = (a * (n - 1) + tr[i]) / n
        out[i] = a
    return out


SETUPS = ("breakout20", "bull_flag", "reclaim_ma20", "oversold", "oversold_bounce")
SETUP_NAMES = {
    "breakout20": "20-Tage-Ausbruch",
    "bull_flag": "Bullenflagge",
    "reclaim_ma20": "über den 20-Tage-Schnitt zurück",
    "oversold": "überverkauft (RSI ≤ 30)",
    "oversold_bounce": "Abprall aus überverkauft",
}


def setups_at(B, i, rsi, ma20):
    """Welche Setups feuern auf der fertigen Tageskerze i."""
    c, h, l, o = B["c"], B["h"], B["l"], B["o"]
    if i < 30:
        return []
    hits = []
    if c[i] > max(c[i - 20:i]):
        hits.append("breakout20")
    base = min(c[i - 15:i - 5])
    pole = c[i - 5] / base - 1 if base > 0 else 0
    if pole >= 0.20 and c[i - 5] > 0:
        flag = (max(h[i - 4:i + 1]) - min(l[i - 4:i + 1])) / c[i - 5]
        if flag <= pole / 2 and 0.90 <= c[i] / c[i - 5] <= 1.02:
            hits.append("bull_flag")
    if ma20[i - 1] is not None and ma20[i] is not None and c[i - 1] < ma20[i - 1] and c[i] > ma20[i]:
        hits.append("reclaim_ma20")
    if rsi[i] is not None and rsi[i] <= 30:
        hits.append("oversold")
    if rsi[i - 1] is not None and rsi[i] is not None and rsi[i - 1] <= 30 and rsi[i] > rsi[i - 1] and c[i] > o[i]:
        hits.append("oversold_bounce")
    return hits


def indicators(B):
    return rsi_series(B["c"]), [sma(B["c"], 20, i) for i in range(len(B["c"]))], atr_series(B["h"], B["l"], B["c"])


# --------------------------------------------------------------------------- Kosten und R

def r_net(entry, stop, exit_price, fee_pct=FEE_PCT, slip_pct=SLIP_PCT):
    """R nach Gebühren und Schlupf; der Stop ist genau -1 R."""
    fee, slip = fee_pct / 100, slip_pct / 100
    basis = entry * (1 + slip) * (1 + fee)
    risk = basis - stop * (1 - slip) * (1 - fee)
    if risk <= 0:
        raise ValueError("Stop muss unter dem Einstieg liegen")
    return (exit_price * (1 - slip) * (1 - fee) - basis) / risk


def plan_levels(entry, atr, stop_atr=STOP_ATR, target_r=TARGET_R):
    stop = entry - stop_atr * atr
    return stop, entry + target_r * (entry - stop)


def walk(B, start, entry, stop, target, bars_max):
    """Ab Kerze start bis zu bars_max Kerzen. Stop zuerst; ein Sprung unter den Stop füllt zur
    Eröffnung (schlechter), das Ziel füllt höchstens zum Zielpreis."""
    end = min(len(B["c"]), start + bars_max)
    for j in range(start, end):
        o, h, l = B["o"][j], B["h"][j], B["l"][j]
        if j > start and o <= stop:
            return "stop", o, j
        if l <= stop:
            return "stop", stop, j
        if h >= target:
            return "target", target, j
    return "neither", B["c"][end - 1], end - 1


# --------------------------------------------------------------------------- Modi

def daily_scan(feed, symbols, now_ms, stop_atr=STOP_ATR, target_r=TARGET_R, hold=HOLD_DAYS):
    hits, failed = [], []
    for sym, rows, err in fetch_all(feed, symbols, lambda s: feed.klines(s, "1d", limit=120)):
        if err:
            failed.append({"symbol": sym, "error": err})
            continue
        rows = closed(rows, now_ms)
        if len(rows) < 40:
            continue
        B = bars(rows)
        rsi, ma20, atr = indicators(B)
        i = len(B["c"]) - 1
        found = setups_at(B, i, rsi, ma20)
        if not found or not atr[i]:
            continue
        entry = B["c"][i]
        stop, target = plan_levels(entry, atr[i], stop_atr, target_r)
        hits.append({
            "symbol": sym, "setups": found, "close": entry,
            "change_pct": round((B["c"][i] / B["c"][i - 1] - 1) * 100, 2),
            "rsi": round(rsi[i], 1) if rsi[i] is not None else None,
            "atr_pct": round(atr[i] / entry * 100, 2),
            "volume": round(B["qv"][i]),
            "plan": {"symbol": sym, "rule": "daily:" + found[0], "entry": entry, "stop": round_price(stop, entry),
                     "target": round_price(target, entry), "target_r": target_r, "stop_atr": stop_atr,
                     "hold_days": hold, "candle": utc_text(B["t"][i]) + " (Tageskerze)",
                     "entry_time": B["t"][i] + DAY},
        })
    hits.sort(key=lambda x: (-len(x["setups"]), -x["volume"]))
    return hits, failed


def price_digits(ref):
    return 2 if ref >= 100 else 4 if ref >= 1 else 6 if ref >= 0.01 else 10


def round_price(x, ref):
    return round(x, price_digits(ref))


def px(x):
    """Preis ohne wissenschaftliche Schreibweise."""
    return f"{x:.{price_digits(abs(x))}f}".rstrip("0").rstrip(".") if x else "0"


def orb_day(B, day_start, or_minutes, cut_ts=None):
    """Eröffnungsspanne ab day_start; erster Schluss darüber. Zeiten in Sekunden."""
    end_or = day_start + or_minutes * 60
    idx = [i for i, t in enumerate(B["t"]) if day_start <= t < day_start + DAY and (cut_ts is None or t + 300 <= cut_ts)]
    rng = [i for i in idx if B["t"][i] < end_or]
    if len(rng) < or_minutes // 5:
        return None
    hi = max(B["h"][i] for i in rng)
    lo = min(B["l"][i] for i in rng)
    after = [i for i in idx if B["t"][i] >= end_or]
    for i in after:
        if B["c"][i] > hi:
            return {"high": hi, "low": lo, "trigger": i, "after": after}
    return {"high": hi, "low": lo, "trigger": None, "after": after}


def orb_scan(feed, symbols, now_ts, open_min=0, or_minutes=60, stop_rule="mid", target_r=TARGET_R):
    day0 = now_ts - now_ts % DAY + open_min * 60
    if day0 > now_ts:
        day0 -= DAY
    hits, failed, waiting = [], [], []
    if now_ts < day0 + or_minutes * 60 + 300:
        return hits, failed, waiting, day0
    load = lambda s: feed.klines(s, "5m", start_ms=day0 * 1000, end_ms=now_ts * 1000)
    for sym, rows, err in fetch_all(feed, symbols, load):
        if err:
            failed.append({"symbol": sym, "error": err})
            continue
        rows = closed(rows, now_ts * 1000)
        if not rows:
            continue
        B = bars(rows)
        res = orb_day(B, day0, or_minutes, now_ts)
        if not res:
            continue
        hi, lo = res["high"], res["low"]
        last = B["c"][-1]
        if res["trigger"] is None:
            waiting.append({"symbol": sym, "high": hi, "last": last, "away_pct": round((hi / last - 1) * 100, 2)})
            continue
        i = res["trigger"]
        entry = B["c"][i]
        stop = (hi + lo) / 2 if stop_rule == "mid" else lo
        if stop >= entry:
            continue
        target = entry + target_r * (entry - stop)
        status, px, j = walk(B, i + 1, entry, stop, target, len(B["c"])) if i + 1 < len(B["c"]) else ("offen", last, i)
        hits.append({
            "symbol": sym, "setups": ["orb"], "close": entry, "range_high": hi, "range_low": lo,
            "trigger_time": utc_text(B["t"][i] + 300), "last": last,
            "since_trigger": {"stop": "Stop getroffen", "target": "Ziel getroffen"}.get(status, "offen"),
            "volume": round(sum(B["qv"])),
            "plan": {"symbol": sym, "rule": "orb", "entry": entry, "stop": round_price(stop, entry),
                     "target": round_price(target, entry), "target_r": target_r, "stop_rule": stop_rule,
                     "or_minutes": or_minutes, "open_min": open_min, "entry_time": B["t"][i] + 300},
        })
    hits.sort(key=lambda x: -x["volume"])
    waiting.sort(key=lambda x: x["away_pct"])
    return hits, failed, waiting, day0


def backtest(feed, symbols, now_ms, days=1000, hold=HOLD_DAYS, stop_atr=STOP_ATR, target_r=TARGET_R,
             fee_pct=FEE_PCT, slip_pct=SLIP_PCT):
    """Jedes Setup auf jeder Tageskerze: Einstieg zur nächsten Eröffnung, Stop/Ziel, sonst raus nach hold Tagen."""
    trades = {s: [] for s in SETUPS}
    trades["alle_tage"] = []
    failed = []
    for sym, rows, err in fetch_all(feed, symbols, lambda s: feed.klines(s, "1d", limit=min(days, 1000))):
        if err:
            failed.append({"symbol": sym, "error": err})
            continue
        rows = closed(rows, now_ms)
        if len(rows) < 60:
            continue
        B = bars(rows)
        rsi, ma20, atr = indicators(B)
        for i in range(30, len(B["c"]) - hold):
            if not atr[i]:
                continue
            entry = B["o"][i + 1]
            stop, target = plan_levels(entry, atr[i], stop_atr, target_r)
            if stop <= 0:
                continue
            outcome, px, _ = walk(B, i + 1, entry, stop, target, hold)
            rec = (B["t"][i], outcome, r_net(entry, stop, px, fee_pct, slip_pct), sym)
            trades["alle_tage"].append(rec)
            for s in setups_at(B, i, rsi, ma20):
                trades[s].append(rec)
    return trades, failed


def summarize(recs, split_ts=None):
    n = len(recs)
    if not n:
        return {"n": 0}
    rs = [r[2] for r in recs]
    out = {
        "n": n,
        "target_pct": round(100 * sum(r[1] == "target" for r in recs) / n, 1),
        "stop_pct": round(100 * sum(r[1] == "stop" for r in recs) / n, 1),
        "avg_r": round(sum(rs) / n, 3),
        "sum_r": round(sum(rs), 1),
        "coins": len({r[3] for r in recs}),
    }
    # Fälle am selben Tag hängen zusammen (der ganze Markt fällt gemeinsam): t-Wert über Tagesmittel.
    per_day = {}
    for r in recs:
        per_day.setdefault(r[0], []).append(r[2])
    means = [sum(v) / len(v) for v in per_day.values()]
    out["days"] = len(means)
    if len(means) > 2:
        m = sum(means) / len(means)
        sd = math.sqrt(sum((x - m) ** 2 for x in means) / (len(means) - 1))
        out["t_days"] = round(m / (sd / math.sqrt(len(means))), 2) if sd > 0 else None
    if split_ts is not None:
        a = [r[2] for r in recs if r[0] < split_ts]
        b = [r[2] for r in recs if r[0] >= split_ts]
        out["first_half_r"] = round(sum(a) / len(a), 3) if a else None
        out["second_half_r"] = round(sum(b) / len(b), 3) if b else None
    return out


def judge(row, base):
    if row["n"] < MIN_CASES:
        return "zu wenige Fälle"
    halves = (row.get("first_half_r"), row.get("second_half_r"))
    both = all(h is not None and h > 0 for h in halves)
    better = row["avg_r"] > base.get("avg_r", 0)
    t = row.get("t_days")
    if row["avg_r"] > 0 and both and better and t is not None and t >= 2:
        return "positiv in beiden Hälften"
    if row["avg_r"] > 0:
        return "positiv, aber nicht stabil"
    return "verliert nach Gebühren"


# --------------------------------------------------------------------------- Ausgabe

def utc_text(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def parse_now(text):
    if not text:
        return int(time.time())
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            d = datetime.datetime.strptime(text, fmt).replace(tzinfo=datetime.timezone.utc)
            return int(d.timestamp())
        except ValueError:
            pass
    raise SystemExit(f"--now verstehe ich nicht: {text!r} (Format 2026-10-21 19:30, UTC)")


def parse_clock(text):
    hh, _, mm = text.partition(":")
    try:
        m = int(hh) * 60 + int(mm or 0)
    except ValueError:
        raise SystemExit(f"Uhrzeit verstehe ich nicht: {text!r} (Format HH:MM, UTC)")
    if not 0 <= m < 24 * 60:
        raise SystemExit(f"Uhrzeit außerhalb des Tages: {text!r}")
    return m


def fmt_vol(v):
    return f"{v / 1e9:.2f} Mrd $" if v >= 1e9 else f"{v / 1e6:.1f} Mio $"


def write_json(path, doc):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def pick_symbols(a, feed):
    if a.symbols:
        out = []
        for s in a.symbols.split(","):
            s = s.strip().upper()
            if s:
                out.append(s if s.endswith(QUOTE) else s + QUOTE)
        return out
    path = os.path.join(a.out, "universe.txt")
    if os.path.exists(path) and not a.fresh:
        return read_universe(path)[: a.top]
    rows, _ = universe(feed, a.top, a.min_volume)
    return [r["symbol"] for r in rows]


def main(argv=None):
    p = argparse.ArgumentParser(description="Krypto-Scanner (Binance, nur Spot, nur Long)")
    p.add_argument("mode", choices=("universe", "daily", "orb", "backtest"))
    p.add_argument("--top", type=int, default=60, help="so viele Paare nach 24h-Umsatz (Standard 60)")
    p.add_argument("--min-volume", type=float, default=5e6, help="Mindest-24h-Umsatz in USDT (Standard 5 Mio)")
    p.add_argument("--symbols", help="eigene Liste, z. B. BTC,ETH,SOL")
    p.add_argument("--exclude", default="", help="Kürzel ausschließen, z. B. PEPE,TRUMP")
    p.add_argument("--keep", default="", help="Kürzel behalten, obwohl der Filter sie ausschließt")
    p.add_argument("--fresh", action="store_true", help="Universum neu laden statt crypto/universe.txt")
    p.add_argument("--open", default="00:00", help="orb: Tagesbeginn in UTC (Standard 00:00)")
    p.add_argument("--or-minutes", type=int, default=60, help="orb: Länge der Eröffnungsspanne (Standard 60)")
    p.add_argument("--stop-rule", choices=("mid", "low"), default="mid")
    p.add_argument("--target-r", type=float, default=TARGET_R)
    p.add_argument("--stop-atr", type=float, default=STOP_ATR)
    p.add_argument("--hold", type=int, default=HOLD_DAYS, help="daily/backtest: höchstens so viele Tage halten")
    p.add_argument("--days", type=int, default=1000, help="backtest: so viele Tageskerzen (max. 1000)")
    p.add_argument("--fee", type=float, default=FEE_PCT, help="Gebühr je Seite in %% (Standard 0.10)")
    p.add_argument("--slip", type=float, default=SLIP_PCT, help="Schlupf je Seite in %% (Standard 0.05)")
    p.add_argument("--now", help="Uhr festlegen, UTC: '2026-10-21 19:30'")
    p.add_argument("--out", default=OUT_DIR)
    p.add_argument("--offline", help="Ordner mit gespeicherten Binance-Antworten")
    p.add_argument("--show", type=int, default=15)
    p.add_argument("--json", action="store_true")
    p.add_argument("--no-write", action="store_true")
    a = p.parse_args(argv)

    feed = Feed(a.offline, pause=0 if a.offline else PAUSE)
    now_ts = parse_now(a.now)
    now_ms = now_ts * 1000
    excl = {x.strip().upper() for x in a.exclude.split(",") if x.strip()}
    keep = {x.strip().upper() for x in a.keep.split(",") if x.strip()}

    try:
        if a.mode == "universe":
            rows, skipped = universe(feed, a.top, a.min_volume, excl, keep)
            if not a.no_write:
                os.makedirs(a.out, exist_ok=True)
                with open(os.path.join(a.out, "universe.txt"), "w", encoding="utf-8") as f:
                    f.write(f"# {utc_text(now_ts)} · Top {len(rows)} USDT-Paare nach 24h-Umsatz, nur Krypto\n")
                    for r in rows:
                        f.write(f"{r['symbol']}|{round(r['volume'])}\n")
            if a.json:
                print(json.dumps({"universe": rows, "skipped": skipped}, ensure_ascii=False))
            else:
                print(f"{len(rows)} Krypto-Paare (mind. {fmt_vol(a.min_volume)} Umsatz in 24 h). "
                      f"Ausgefiltert: " + (", ".join(f"{v} {k}" for k, v in sorted(skipped.items())) or "nichts"))
                for r in rows[: a.show]:
                    print(f"  {r['symbol']:<14} {fmt_vol(r['volume']):>12}  {r['change_pct']:+6.2f} %")
            return 0 if rows else 1

        symbols = [s for s in pick_symbols(a, feed) if s[: -len(QUOTE)] not in excl]
        if not symbols:
            print("Keine Paare zum Scannen.")
            return 1

        if a.mode == "daily":
            hits, failed = daily_scan(feed, symbols, now_ms, a.stop_atr, a.target_r, a.hold)
            doc = {"mode": "daily", "as_of": utc_text(now_ts), "scanned": len(symbols), "failed": failed, "hits": hits}
            if not a.no_write:
                write_json(os.path.join(a.out, "watchlist.json"), doc)
            if a.json:
                print(json.dumps(doc, ensure_ascii=False))
                return 0 if hits else 1
            print(f"Tages-Scan {utc_text(now_ts)}: {len(hits)} von {len(symbols)} Paaren mit Setup "
                  f"(letzte fertige Tageskerze).")
            for h in hits[: a.show]:
                pl = h["plan"]
                names = ", ".join(SETUP_NAMES[s] for s in h["setups"])
                print(f"  {h['symbol']:<12} {names}")
                print(f"      Schluss {px(h['close'])} ({h['change_pct']:+.2f} %), RSI {h['rsi']}, ATR {h['atr_pct']} %"
                      f" · Plan: Stop {px(pl['stop'])}, Ziel {px(pl['target'])} ({pl['target_r']:g}R), max {pl['hold_days']} Tage")
            if failed:
                print(f"  {len(failed)} Paare nicht geladen.")
            return 0 if hits else 1

        if a.mode == "orb":
            hits, failed, waiting, day0 = orb_scan(feed, symbols, now_ts, parse_clock(a.open), a.or_minutes,
                                                   a.stop_rule, a.target_r)
            doc = {"mode": "orb", "as_of": utc_text(now_ts), "day_start": utc_text(day0), "or_minutes": a.or_minutes,
                   "scanned": len(symbols), "failed": failed, "hits": hits, "waiting": waiting[:20]}
            if now_ts < day0 + a.or_minutes * 60 + 300:
                print(f"Die Eröffnungsspanne ab {utc_text(day0)} läuft noch ({a.or_minutes} min).")
                return 1
            if not a.no_write:
                write_json(os.path.join(a.out, "watchlist.json"), doc)
            if a.json:
                print(json.dumps(doc, ensure_ascii=False))
                return 0 if hits else 1
            print(f"Eröffnungsspannen-Ausbruch seit {utc_text(day0)} ({a.or_minutes} min), Stand {utc_text(now_ts)}: "
                  f"{len(hits)} von {len(symbols)} ausgebrochen.")
            for h in hits[: a.show]:
                pl = h["plan"]
                print(f"  {h['symbol']:<12} Spanne {px(h['range_low'])}–{px(h['range_high'])}, Schluss darüber "
                      f"{px(h['close'])} um {h['trigger_time']}; jetzt {px(h['last'])} · {h['since_trigger']}"
                      f" · Plan: Stop {px(pl['stop'])}, Ziel {px(pl['target'])}")
            for w in waiting[:5]:
                print(f"  wartet: {w['symbol']:<12} {w['away_pct']:+.2f} % bis zum Spannenhoch {px(w['high'])}")
            return 0 if hits else 1

        trades, failed = backtest(feed, symbols, now_ms, a.days, a.hold, a.stop_atr, a.target_r, a.fee, a.slip)
        all_ts = sorted(r[0] for r in trades["alle_tage"])
        split = all_ts[len(all_ts) // 2] if all_ts else None
        base = summarize(trades["alle_tage"], split)
        table = []
        for s in SETUPS + ("alle_tage",):
            row = summarize(trades[s], split)
            row["setup"] = s
            if s != "alle_tage" and row["n"]:
                row["urteil"] = judge(row, base)
            table.append(row)
        doc = {"mode": "backtest", "as_of": utc_text(now_ts), "coins": len(symbols), "hold_days": a.hold,
               "stop_atr": a.stop_atr, "target_r": a.target_r, "fee_pct": a.fee, "slip_pct": a.slip,
               "split": utc_text(split) if split else None, "table": table, "failed": failed}
        if not a.no_write:
            write_json(os.path.join(a.out, "backtest.json"), doc)
        if a.json:
            print(json.dumps(doc, ensure_ascii=False))
            return 0
        print(f"Rückblick über {len(symbols)} Coins, bis {min(a.days, 1000)} Tage: Einstieg zur nächsten Tageseröffnung, "
              f"Stop {a.stop_atr:g}×ATR, Ziel {a.target_r:g}R, sonst raus nach {a.hold} Tagen; "
              f"Gebühr {a.fee:g} % + Schlupf {a.slip:g} % je Seite.")
        print(f"  {'Setup':<34}{'Fälle':>7}{'Tage':>6}{'Ziel':>8}{'Stop':>8}{'Ø R':>8}{'t':>6}{'1. Hälfte':>11}{'2. Hälfte':>11}")
        for row in table:
            if not row["n"]:
                print(f"  {SETUP_NAMES.get(row['setup'], 'jeder Tag (Vergleich)'):<34}{0:>7}")
                continue
            name = SETUP_NAMES.get(row["setup"], "jeder Tag (Vergleich)")
            fh = "–" if row.get("first_half_r") is None else f"{row['first_half_r']:+.3f}"
            sh = "–" if row.get("second_half_r") is None else f"{row['second_half_r']:+.3f}"
            tv = "–" if row.get("t_days") is None else f"{row['t_days']:.1f}"
            print(f"  {name:<34}{row['n']:>7}{row['days']:>6}{row['target_pct']:>7.1f}%{row['stop_pct']:>7.1f}%"
                  f"{row['avg_r']:>+8.3f}{tv:>6}{fh:>11}{sh:>11}  {row.get('urteil', '')}")
        print("  t: Mittel je Tag geteilt durch seinen Standardfehler (ab 2 kaum noch Zufall). Nur Coins, die heute\n"
              "  noch gehandelt werden: abgestürzte und delistete fehlen, das schönt jeden Kauf nach Kursrutschen.\n"
              "  Vergangenheit ist keine Zusage für morgen.")
        return 0
    except RuntimeError as e:
        print(str(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
