#!/usr/bin/env python3
"""Krypto-Zeitmaschine: spielt einen Plan 10.000-mal durch, bevor Geld fließt.

Baut die nächsten Stunden aus den eigenen Kerzen des Coins nach (gleiche
Tageszeit, plus/minus ein paar Kerzen), prüft Kerze für Kerze erst den Stop,
dann das Ziel, und rechnet jedes Ergebnis nach Gebühren und Schlupf in R.
Dazu kommt die echte Historie derselben Regel. Eine Simulation, keine Prognose.

Braucht crypto-scanner im Nachbarordner (Datenzugriff, Regeln, Gebühren).

  timemachine.py run                         # Plan Nr. 1 aus crypto/watchlist.json
  timemachine.py run --pick SOL              # Plan für SOLUSDT aus der Watchlist
  timemachine.py run --symbol BTC --stop-pct 3 --target-r 2 --hours 24
"""
import argparse
import importlib.util
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Eine Kopie im eigenen Ordner (Zip für die Claude-App) oder der Scanner im Nachbarordner.
# (im New Token Bot heißt die Kopie crypto_scan.py).
SCANNERS = (os.path.join(HERE, "scan.py"), os.path.join(HERE, "crypto_scan.py"),
            os.path.join(HERE, "..", "crypto-scanner", "scan.py"))


def _load_scanner():
    path = next((p for p in SCANNERS if os.path.exists(p)), None)
    if not path:
        sys.exit("crypto-scanner fehlt neben crypto-timemachine (beide Ordner zusammen installieren).")
    spec = importlib.util.spec_from_file_location("crypto_scan", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


scan = _load_scanner()

DAY = 86400
STEP = {"5m": 300, "1h": 3600}
POOL_DAYS = {"5m": 30, "1h": 120}
WINDOW = {"5m": 2, "1h": 1}
MIN_DAYS = 14
REPLAYS = 10000
SEED = 19
EDGE = 0.05          # ab so viel R im Mittel zählt es als Plus oder Minus
MIN_HISTORY = 30     # so viele echte Fälle braucht die Historie
MIN_T = 2.0          # und so deutlich muss ihr Mittel über Null liegen (Mittel / Standardfehler)
MANY_NEITHER = 0.40


# --------------------------------------------------------------------------- Pool

def build_pool(B, step, before_ts):
    """Je Tageszeit-Slot die Kerzen als Verhältnisse zum vorigen Schluss."""
    slots = DAY // step
    pool = [[] for _ in range(slots)]
    logs = []
    t, o, h, l, c = B["t"], B["o"], B["h"], B["l"], B["c"]
    for k in range(1, len(t)):
        if t[k] >= before_ts or t[k] - t[k - 1] != step or c[k - 1] <= 0:
            continue
        pc = c[k - 1]
        pool[(t[k] % DAY) // step].append((o[k] / pc, h[k] / pc, l[k] / pc, c[k] / pc))
        logs.append(c[k] / pc)
    mean = sum(logs) / len(logs) if logs else 1.0
    return pool, math.log(mean), len(logs)


def buckets(pool, window, neutral=True):
    """Je Slot die Kerzen der Nachbar-Slots. Neutral: in jedem Topf bleibt der Kurs im Mittel, wo er ist
    (fairer Markt). Sonst würde der Zufall einzelner Tageszeiten über viele Tage zu einem Trend."""
    n = len(pool)
    out = []
    for s in range(n):
        b = sum((pool[(s + d) % n] for d in range(-window, window + 1)), [])
        if neutral and b:
            f = len(b) / sum(x[3] for x in b)
            b = [(a * f, h * f, l * f, c * f) for a, h, l, c in b]
        out.append(b)
    return out


def simulate(bk, start_slot, bars_ahead, entry, stop, target, fee, slip, replays=REPLAYS, seed=SEED):
    rng = random.Random(seed)
    rand = rng.random
    n = len(bk)
    tf = sf = nn = green = 0
    rs, ends = [], []
    for _ in range(replays):
        p = entry
        out = None
        exit_px = None
        for i in range(bars_ahead):
            b = bk[(start_slot + i) % n]
            ro, rh, rl, rc = b[int(rand() * len(b))]
            if out is None:
                o, hi, lo = p * ro, p * rh, p * rl
                if o <= stop:
                    out, exit_px = "stop", o
                elif lo <= stop:
                    out, exit_px = "stop", stop
                elif hi >= target:
                    out, exit_px = "target", target
            p *= rc
        if out is None:
            out, exit_px = "neither", p
        r = scan.r_net(entry, stop, exit_px, fee, slip)
        if out == "target":
            tf += 1
        elif out == "stop":
            sf += 1
        else:
            nn += 1
        if r > 0:
            green += 1
        rs.append(r)
        ends.append(p)
    ends.sort()
    q = lambda f: ends[min(len(ends) - 1, int(f * len(ends)))]
    return {
        "replays": replays, "seed": seed, "bars": bars_ahead,
        "target_first": tf / replays, "stop_first": sf / replays, "neither": nn / replays,
        "green": green / replays, "avg_r": sum(rs) / replays,
        "end_p5": q(0.05), "end_p50": q(0.5), "end_p95": q(0.95),
    }


# --------------------------------------------------------------------------- Historie

def tally(results):
    n = len(results)
    if not n:
        return {"n": 0}
    rs = [r for _, r in results]
    avg = sum(rs) / n
    sd = math.sqrt(sum((r - avg) ** 2 for r in rs) / (n - 1)) if n > 1 else 0.0
    return {"n": n,
            "target": sum(o == "target" for o, _ in results),
            "stop": sum(o == "stop" for o, _ in results),
            "neither": sum(o == "neither" for o, _ in results),
            "avg_r": avg, "t": avg / (sd / math.sqrt(n)) if sd > 0 else 0.0}


def history_orb(B5, plan, before_ts, bars_ahead, fee, slip):
    open_min, orm = int(plan.get("open_min", 0)), int(plan.get("or_minutes", 60))
    first = B5["t"][0] - B5["t"][0] % DAY + open_min * 60
    out = []
    d = first
    while d + DAY <= before_ts:
        res = scan.orb_day(B5, d, orm)
        if res and res["trigger"] is not None:
            i = res["trigger"]
            entry = B5["c"][i]
            stop = (res["high"] + res["low"]) / 2 if plan.get("stop_rule", "mid") == "mid" else res["low"]
            if stop < entry and i + 1 < len(B5["c"]):
                target = entry + float(plan.get("target_r", 2)) * (entry - stop)
                o, px, _ = scan.walk(B5, i + 1, entry, stop, target, bars_ahead)
                out.append((o, scan.r_net(entry, stop, px, fee, slip)))
        d += DAY
    return tally(out)


def history_daily(D, plan, fee, slip):
    setup = plan["rule"].split(":", 1)[1]
    rsi, ma20, atr = scan.indicators(D)
    hold = int(plan.get("hold_days", scan.HOLD_DAYS))
    stop_atr, target_r = float(plan.get("stop_atr", scan.STOP_ATR)), float(plan.get("target_r", 2))
    same, every = [], []
    for i in range(30, len(D["c"]) - hold):
        if not atr[i]:
            continue
        entry = D["o"][i + 1]
        stop, target = scan.plan_levels(entry, atr[i], stop_atr, target_r)
        if stop <= 0:
            continue
        o, px, _ = scan.walk(D, i + 1, entry, stop, target, hold)
        rec = (o, scan.r_net(entry, stop, px, fee, slip))
        every.append(rec)
        if setup in scan.setups_at(D, i, rsi, ma20):
            same.append(rec)
    return tally(same), tally(every), len(D["c"])


def history_same_time(B, step, plan, before_ts, bars_ahead, fee, slip):
    """Vergleich: jeden Tag zur selben Uhrzeit mit denselben Abständen einsteigen."""
    entry0 = plan["entry"]
    sd, td = plan["stop"] / entry0, plan["target"] / entry0
    slot = (before_ts % DAY) // step
    out = []
    for k, t in enumerate(B["t"]):
        if t + bars_ahead * step > before_ts:
            break
        if (t % DAY) // step != slot:
            continue
        e = B["o"][k]
        o, px, _ = scan.walk(B, k, e, e * sd, e * td, bars_ahead)
        out.append((o, scan.r_net(e, e * sd, px, fee, slip)))
    return tally(out)


# --------------------------------------------------------------------------- Urteil

def verdict(mc, target_r_net, history=None):
    """Urteil in wenigen Zeilen: zuerst der Erwartungswert nach Gebühren, dann die Historie."""
    history = history or {}
    same, every = history.get("same") or {"n": 0}, history.get("every") or {}
    sim = mc["avg_r"]
    hist_ok = (same["n"] >= MIN_HISTORY and same["avg_r"] >= EDGE and same.get("t", 0) >= MIN_T
               and (not every.get("n") or same["avg_r"] - every["avg_r"] >= EDGE))
    if hist_ok and sim > -EDGE:
        head = (f"Schwacher Hinweis, keine Gewissheit: die Historie lag im Plus (Ø R {same['avg_r']:+.3f} "
                f"bei {same['n']} Fällen, t {same['t']:.1f}), die Simulation ist neutral (Ø R {sim:+.3f}).")
    elif sim <= -EDGE and not hist_ok:
        head = f"Kein Vorsprung: im Mittel {sim:+.3f} R nach Gebühren, und die Historie zeigt keinen Vorteil."
    elif sim >= EDGE:
        head = (f"Simulation im Plus (Ø R {sim:+.3f}), " +
                ("aber nur mit dem Trend der letzten Tage – der hält selten." if history.get("kept_drift")
                 else "die Historie bestätigt das " + ("auch." if hist_ok else "nicht.")))
    else:
        head = f"Kein klarer Vorsprung: etwa Null nach Gebühren (Ø R {sim:+.3f})."
    lines = [f"Urteil: {head}"]
    tf, sf = mc["target_first"], mc["stop_first"]
    if tf + sf > 0:
        share = tf / (tf + sf)
        need = 1 / (1 + target_r_net) if target_r_net > 0 else 1.0
        lines.append(f"Von den Wiederholungen, die Stop oder Ziel trafen, traf {share * 100:.1f} % zuerst das Ziel; "
                     f"die Gewinnschwelle läge bei {need * 100:.1f} %.")
    if mc["neither"] > MANY_NEITHER:
        lines.append(f"{mc['neither'] * 100:.1f} % der Wiederholungen trafen weder Stop noch Ziel; "
                     f"da entscheidet der Kurs am Ende.")
    return lines


# --------------------------------------------------------------------------- Plan

def norm_symbol(s):
    s = s.strip().upper()
    return s if s.endswith(scan.QUOTE) else s + scan.QUOTE


def load_plan(a, feed, now_ts):
    if a.symbol:
        sym = norm_symbol(a.symbol)
        entry = a.entry
        if entry is None:
            rows = scan.closed(feed.klines(sym, "1m", limit=5), now_ts * 1000) or feed.klines(sym, "5m", limit=2)
            entry = float(rows[-1][4])
        if a.stop is not None:
            stop = a.stop
        elif a.stop_pct is not None:
            stop = entry * (1 - a.stop_pct / 100)
        else:
            sys.exit("Stop fehlt: --stop PREIS oder --stop-pct PROZENT.")
        target = a.target if a.target is not None else entry + (a.target_r or 2) * (entry - stop)
        return {"symbol": sym, "rule": "manual", "entry": entry, "stop": stop, "target": target,
                "target_r": round((target - entry) / (entry - stop), 3) if entry > stop else None}
    path = a.plan or os.path.join(a.out, "watchlist.json")
    if not os.path.exists(path):
        sys.exit(f"{path} fehlt: erst crypto-scanner laufen lassen oder --symbol angeben.")
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    hits = [h for h in doc.get("hits", []) if h.get("plan")]
    if "plan" in doc and not hits:
        return doc["plan"]
    if not hits:
        sys.exit(f"{path} enthält keinen Plan.")
    if a.pick is None:
        return hits[0]["plan"]
    if a.pick.isdigit():
        k = int(a.pick)
        if not 1 <= k <= len(hits):
            sys.exit(f"--pick {k}: die Watchlist hat {len(hits)} Pläne.")
        return hits[k - 1]["plan"]
    want = norm_symbol(a.pick)
    for h in hits:
        if h["symbol"] == want:
            return h["plan"]
    sys.exit(f"{want} steht nicht in {path}.")


def check_plan(plan):
    e, s, t = float(plan["entry"]), float(plan["stop"]), float(plan["target"])
    if not (s < e < t):
        sys.exit(f"Plan ergibt keinen Sinn: Stop {s} < Einstieg {e} < Ziel {t} muss gelten (nur Long).")
    return e, s, t


# --------------------------------------------------------------------------- Lauf

def run(a, feed, now_ts, plan=None):
    plan = plan or load_plan(a, feed, now_ts)
    entry, stop, target = check_plan(plan)
    rule = plan.get("rule", "manual")
    hours = a.hours or (int(plan.get("hold_days", 3)) * 24 if rule.startswith("daily:") else 24)
    hours = max(1, min(hours, 24 * 30))
    interval = a.interval if a.interval != "auto" else ("5m" if hours <= 24 else "1h")
    step = STEP[interval]
    days = a.days or POOL_DAYS[interval]
    window = WINDOW[interval] if a.window is None else a.window
    bars_ahead = max(1, hours * 3600 // step)
    sym = plan["symbol"]
    now_ms = now_ts * 1000

    rows = scan.closed(feed.klines(sym, interval, start_ms=(now_ts - days * DAY) * 1000, end_ms=now_ms), now_ms)
    B = scan.bars(rows)
    span_days = (B["t"][-1] - B["t"][0]) / DAY if len(B["t"]) > 1 else 0
    if span_days < MIN_DAYS:
        sys.exit(f"Zu wenig Daten für {sym}: {span_days:.1f} Tage {interval}-Kerzen, mindestens {MIN_DAYS} nötig.")
    pool, drift, n_pool = build_pool(B, step, now_ts)
    bk = buckets(pool, window, neutral=not a.keep_drift)
    if min(len(b) for b in bk) == 0:
        sys.exit(f"Lücken in den Daten von {sym}: nicht jede Tageszeit hat Kerzen.")
    start_slot = (now_ts % DAY) // step
    fee, slip = a.fee, a.slip
    mc = simulate(bk, start_slot, bars_ahead, entry, stop, target, fee, slip, a.replays, a.seed)
    target_r_net = scan.r_net(entry, stop, target, fee, slip)

    history = {}
    if rule == "orb":
        B5 = B if interval == "5m" else scan.bars(scan.closed(
            feed.klines(sym, "5m", start_ms=(now_ts - 30 * DAY) * 1000, end_ms=now_ms), now_ms))
        day_now = now_ts - (now_ts - int(plan.get("open_min", 0)) * 60) % DAY
        history = {"kind": "orb", "same": history_orb(B5, plan, day_now, hours * 12, fee, slip)}
    elif rule.startswith("daily:"):
        D = scan.bars(scan.closed(feed.klines(sym, "1d", limit=1000), now_ms))
        same, every, n_days = history_daily(D, plan, fee, slip)
        history = {"kind": "daily", "same": same, "every": every, "days": n_days}
    else:
        history = {"kind": "same_time", "same": history_same_time(B, step, plan, now_ts, bars_ahead, fee, slip)}

    last = B["c"][-1]
    return {
        "plan": plan, "as_of": scan.utc_text(now_ts), "interval": interval, "pool_days": round(span_days, 1),
        "window": window, "hours": hours, "fee_pct": fee, "slip_pct": slip, "neutral": not a.keep_drift,
        "drift_per_day_pct": round((math.exp(drift * DAY / step) - 1) * 100, 2), "pool_bars": n_pool,
        "last": last, "target_r_net": target_r_net, "mc": mc, "history": history,
        "verdict": verdict(mc, target_r_net, dict(history, kept_drift=a.keep_drift)),
    }


def pc(x):
    return f"{x * 100:5.1f} %"


def report(doc):
    pl, mc, h = doc["plan"], doc["mc"], doc["history"]
    px = scan.px
    rule = pl.get("rule", "manual")
    rule_text = {"orb": f"Ausbruch aus der {pl.get('or_minutes', 60)}-min-Eröffnungsspanne", "manual": "eigener Plan"}.get(
        rule, scan.SETUP_NAMES.get(rule.split(":", 1)[-1], rule))
    gross_r = (pl["target"] - pl["entry"]) / (pl["entry"] - pl["stop"])
    unit = "Fünf-Minuten-Kerzen" if doc["interval"] == "5m" else "Stundenkerzen"
    lines = [
        f"{pl['symbol']} · {rule_text} · Einstieg {px(pl['entry'])}, Stop {px(pl['stop'])}, Ziel {px(pl['target'])} "
        f"({gross_r:.2f} R brutto, {doc['target_r_net']:+.2f} R nach Gebühren; Stop = -1 R).",
        f"Kurs jetzt {px(doc['last'])} ({(doc['last'] / pl['entry'] - 1) * 100:+.2f} % zum Einstieg), Stand {doc['as_of']}.",
        f"{mc['replays']:,}".replace(",", ".") + f" Wiederholungen der nächsten {doc['hours']} h ({mc['bars']} {unit} "
        f"aus den letzten {doc['pool_days']:g} Tagen, gleiche Tageszeit ±{doc['window']} Kerzen), Seed {mc['seed']}.",
        ("Trend neutralisiert" if doc["neutral"] else "Trend behalten") +
        f" (der Coin lief zuletzt {doc['drift_per_day_pct']:+.2f} % pro Tag). "
        f"Gebühr {doc['fee_pct']:g} % + Schlupf {doc['slip_pct']:g} % je Seite.",
        f"  Ziel zuerst   {pc(mc['target_first'])}",
        f"  Stop zuerst   {pc(mc['stop_first'])}",
        f"  weder noch    {pc(mc['neither'])}   nach {doc['hours']} h noch offen",
        f"  im Plus       {pc(mc['green'])}   nach Gebühren",
        f"  Kurs nach {doc['hours']} h: Median {px(mc['end_p50'])}, 90 % zwischen {px(mc['end_p5'])} und {px(mc['end_p95'])}.",
        f"  Ø R nach Gebühren: {mc['avg_r']:+.3f}",
    ]
    s = h.get("same", {"n": 0})
    if h["kind"] == "orb":
        what = "Historie: dieselbe Regel an den letzten Tagen"
    elif h["kind"] == "daily":
        what = f"Historie: dasselbe Setup auf {h['days']} echten Tageskerzen"
    else:
        what = "Vergleich: jeden Tag zur selben Uhrzeit mit denselben Abständen eingestiegen"
    if s["n"]:
        lines.append(f"{what}: {s['n']} Fälle, {s['target']} Ziel, {s['stop']} Stop, {s['neither']} weder; "
                     f"Ø R {s['avg_r']:+.3f} (t {s['t']:.1f}; erst ab 2 mehr als Zufall).")
    else:
        lines.append(f"{what}: kein einziger Fall.")
    e = h.get("every")
    if e and e["n"]:
        lines.append(f"  Zum Vergleich jeder Tag mit derselben Stop/Ziel-Regel: {e['n']} Fälle, Ø R {e['avg_r']:+.3f}.")
    lines.extend(doc["verdict"])
    return "\n".join(lines)


def parser():
    p = argparse.ArgumentParser(description="Krypto-Zeitmaschine (Monte Carlo + Historie, nach Gebühren)")
    p.add_argument("cmd", choices=("run",))
    p.add_argument("--plan", help="Watchlist- oder Plan-Datei (Standard crypto/watchlist.json)")
    p.add_argument("--pick", help="welcher Plan: Nummer (1 = erster) oder Kürzel")
    p.add_argument("--symbol", help="eigener Plan: Coin, z. B. BTC")
    p.add_argument("--entry", type=float, help="Einstieg (Standard: letzter Kurs)")
    p.add_argument("--stop", type=float)
    p.add_argument("--stop-pct", type=float, help="Stop so viel Prozent unter dem Einstieg")
    p.add_argument("--target", type=float)
    p.add_argument("--target-r", type=float, help="Ziel als Vielfaches des Risikos (Standard 2)")
    p.add_argument("--hours", type=int, help="so viele Stunden nachspielen (ORB 24, Tages-Setups Haltedauer)")
    p.add_argument("--interval", choices=("auto", "5m", "1h"), default="auto")
    p.add_argument("--days", type=int, help="Pool: so viele Tage zurück (5m: 30, 1h: 120)")
    p.add_argument("--window", type=int, help="Tageszeit ± so viele Kerzen (5m: 2, 1h: 1)")
    p.add_argument("--replays", type=int, default=REPLAYS)
    p.add_argument("--seed", type=int, default=SEED)
    p.add_argument("--fee", type=float, default=scan.FEE_PCT)
    p.add_argument("--slip", type=float, default=scan.SLIP_PCT)
    p.add_argument("--keep-drift", action="store_true", help="den Trend der letzten Tage nicht neutralisieren")
    p.add_argument("--now", help="Uhr festlegen, UTC: '2026-10-21 19:30'")
    p.add_argument("--out", default=scan.OUT_DIR)
    p.add_argument("--offline", help="Ordner mit gespeicherten Binance-Antworten")
    p.add_argument("--json", action="store_true")
    p.add_argument("--write", action="store_true", help="auch crypto/timemachine.json schreiben")
    return p


def main(argv=None):
    a = parser().parse_args(argv)
    if a.replays < 100:
        sys.exit("--replays: mindestens 100.")
    feed = scan.Feed(a.offline, pause=0 if a.offline else scan.PAUSE)
    now_ts = scan.parse_now(a.now)
    try:
        doc = run(a, feed, now_ts)
    except RuntimeError as e:
        print(str(e))
        return 1
    if a.write:
        scan.write_json(os.path.join(a.out, "timemachine.json"), doc)
    print(json.dumps(doc, ensure_ascii=False) if a.json else report(doc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
