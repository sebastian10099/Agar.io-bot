"""Backtest on recorded price paths: what would the rules have earned?

The tracker follows every pool token it judges for an hour (the paths table:
its price every poll, reserve prices). This replays entry rules and exit
settings on those paths - hundreds of trades an hour instead of the handful
the paper account can hold - with the paper account's own costs and exit
logic (stop loss first, then the profit ladder, the trailing stop, the time
stop).

    python3 tools/backtest.py <data dir or bot.sqlite> [--since EPOCH] [--search]

Honest by construction: entries are the bot's own verdicts on the numbers it
had at that moment; an exit setting is chosen on the first half of the time
and then shown on the second half it has not seen. A path that ends (the pool
gone) is a total loss, as the tracker counts it. Past results promise
nothing about the next hour."""
from __future__ import annotations

import copy
import itertools
import json
import sqlite3
import statistics
import sys
from pathlib import Path
from typing import Any, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from bot.main import load_config  # noqa: E402
from bot.strategy import evaluate  # noqa: E402

PRESETS = Path(__file__).resolve().parent.parent / "bot" / "presets.json"
GRID = {
    "stop_loss_pct": [-15, -20, -30, -40],
    "trailing_stop_pct": [15, 25, 35],
    "time_stop_minutes": [10, 20, 30, 60],
    "take_profit_ladder": [[[50, 0.5], [100, 0.25]], [[25, 0.5], [50, 0.25]], [[100, 0.5]], []],
}
MIN_TRADES = 8          # fewer trades than this say nothing
JUMP_MAX = 10.0         # bot/engine.py PRICE_JUMP_MAX: a price this far above the last one is refused


def simulate(entry: float, opened_at: float, path: list[tuple[float, float]], ex: dict[str, Any],
             fee_pct: float, slip_pct: float) -> tuple[float, str]:
    """Return in % of the stake and the exit reason, by the rules of bot/paper.py
    (fill = price -/+ slippage, a fee on every fill, the entry fee realized at once)."""
    fee, slip = fee_pct / 100.0, slip_pct / 100.0
    fill_in = entry * (1 + slip)
    remaining, realized, peak = 1.0, -fee, fill_in
    ladder = sorted((float(t), float(f)) for t, f in ex.get("take_profit_ladder") or [])
    done: set[float] = set()
    deadline = opened_at + float(ex["time_stop_minutes"]) * 60
    last = entry                                            # the last believable price (the engine's PRICE_JUMP_MAX rule)

    def sell(frac: float, price: float) -> None:
        nonlocal remaining, realized
        frac = min(frac, remaining)
        if frac <= 0:
            return
        gross = frac * (price * (1 - slip) / fill_in)
        realized += gross * (1 - fee) - frac
        remaining = round(remaining - frac, 9)

    for at, price in path:
        if at > deadline:                                   # stored on change: at the time stop the price was the last one
            sell(remaining, last)
            return realized * 100, "time_stop"
        if price > last * JUMP_MAX:                         # a bad quote: the engine keeps the last believable price
            price = last
        last = price
        peak = max(peak, price)
        gain = (price / fill_in - 1) * 100
        if gain <= float(ex["stop_loss_pct"]):
            sell(remaining, price)
            return realized * 100, "stop_loss"
        for t, f in ladder:
            if t in done or gain < t:
                continue
            sell(f, price)
            done.add(t)
            if remaining <= 1e-9:
                return realized * 100, f"take_profit_{int(t)}"
        trail = float(ex["trailing_stop_pct"])
        if (peak / fill_in - 1) * 100 >= trail and (price / peak - 1) * 100 <= -trail:
            sell(remaining, price)
            return realized * 100, "trailing_stop"
        if at >= deadline:
            sell(remaining, price)
            return realized * 100, "time_stop"
    sell(remaining, last)                                   # the hour of path is over
    return realized * 100, "path_end"


def apply_flat(cfg: dict[str, Any], flat: dict[str, Any]) -> dict[str, Any]:
    out = copy.deepcopy(cfg)
    for path, value in flat.items():
        head, _, key = path.rpartition(".")
        node = out
        for part in head.split(".") if head else []:
            node = node.setdefault(part, {})
        node[key] = value
    return out


def load(db_path: Path, since: float) -> list[dict[str, Any]]:
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        cands = [dict(r) for r in db.execute(
            "SELECT c.id, c.seen_at, c.token, c.symbol, c.price_usd, c.decision, c.snapshot FROM candidates c "
            "WHERE c.seen_at >= ? AND EXISTS (SELECT 1 FROM paths p WHERE p.candidate_id = c.id) ORDER BY c.seen_at", (since,))]
        for c in cands:
            c["snapshot"] = json.loads(c["snapshot"] or "{}")
            c["path"] = [(r[0], r[1]) for r in db.execute(
                "SELECT at, price FROM paths WHERE candidate_id=? ORDER BY at", (c["id"],))]
        return [c for c in cands if c["price_usd"] and c["path"]]
    finally:
        db.close()


def entries(cands: list[dict[str, Any]], cfg: Optional[dict[str, Any]]) -> list[dict[str, Any]]:
    """The candidates these rules buy (all of them with cfg None), first one per token."""
    out, seen = [], set()
    for c in cands:
        if c["token"] in seen:
            continue
        if cfg is not None:
            try:
                v = evaluate(c["snapshot"], c["snapshot"].get("rug"), cfg)
            except (KeyError, TypeError, ValueError):       # a record without the numbers the rules read
                continue
            if v["decision"] != "buy" or v.get("watch_only"):
                continue
        seen.add(c["token"])
        out.append(c)
    return out


def run(trades: list[dict[str, Any]], ex: dict[str, Any], fee: float, slip: float) -> list[float]:
    return [simulate(c["price_usd"], c["seen_at"], c["path"], ex, fee, slip)[0] for c in trades]


def stats(rets: list[float]) -> str:
    if not rets:
        return "keine Trades"
    win = sum(r > 0 for r in rets) / len(rets) * 100
    return (f"{len(rets):>4} Trades · Ø {statistics.mean(rets):+6.1f} % · Median {statistics.median(rets):+6.1f} % · "
            f"im Plus {win:3.0f} % · Summe {sum(rets) / 100:+.2f} Einsätze")


def label(ex: dict[str, Any]) -> str:
    ladder = "/".join(f"+{t:g}%:{f:g}" for t, f in ex["take_profit_ladder"]) or "keine"
    return f"Stop {ex['stop_loss_pct']} % · Trailing {ex['trailing_stop_pct']} % · Zeit {ex['time_stop_minutes']} min · Stufen {ladder}"


RUG_SIGNS = [
    ("Insider-Netzwerk erkannt", lambda s, r: (r.get("insider_wallets") or 0) > 0 if r else None),
    ("10 größte Wallets ≥ 35 %", lambda s, r: r["holders"]["top10"] >= 35 if r and r.get("holders") else None),
    ("Ersteller hält > 5 %", lambda s, r: r["creator_pct"] > 5 if r and r.get("creator_pct") is not None else None),
    ("„LP Unlocked“", lambda s, r: any("LP Unlocked" in str(d) for d in r.get("danger") or []) if r else None),
    ("Eigener Pool auf PumpSwap", lambda s, r: s.get("dex") == "pumpswap" and not str(s.get("token") or "").endswith("pump")),
    ("Pool auf Meteora", lambda s, r: s.get("dex") == "meteora"),
    ("Bewertung > 3× Liquidität", lambda s, r: (s.get("fdv") or 0) > 3 * (s.get("liquidity_usd") or 1e18)),
    ("5-min-Anstieg > 150 %", lambda s, r: (s.get("change_m5") or 0) > 150),
    ("Alter < 10 min", lambda s, r: (s.get("age_min") or 0) < 10),
]


def rug_table(cands: list[dict[str, Any]]) -> list[str]:
    """How often a pool token fell 90 % within its hour, with and without each sign at the
    moment it was judged. Signs RugCheck reports only exist for tokens it was asked about."""
    pool = entries(cands, None)
    rug = {c["id"]: min(p for _, p in c["path"]) <= c["price_usd"] * 0.1 for c in pool}
    lines = [f"Rugs (−90 % binnen der Stunde): {sum(rug.values())} von {len(pool)} Pool-Tokens"]
    for name, sign in RUG_SIGNS:
        yes, no = [], []
        for c in pool:
            try:
                v = sign(c["snapshot"], c["snapshot"].get("rug"))
            except (KeyError, TypeError, ZeroDivisionError):
                v = None
            if v is not None:
                (yes if v else no).append(rug[c["id"]])
        if yes and no:
            lines.append(f"  {name:<28} mit: {sum(yes) / len(yes) * 100:3.0f} % von {len(yes):>3} · "
                         f"ohne: {sum(no) / len(no) * 100:3.0f} % von {len(no):>3}")
    return lines


# An idea found by looking at the data is only tested on data that came after it: the rule
# and its start are written down here before that data exists, and never fitted to it.
PROBES = [
    ("Frühkauf in eigenen PumpSwap-Pools (Alter < 1,5 min, Coin nicht von pump.fun)",
     1792418400.0,      # 19 Oct 2026 14:00 UTC - the idea came from the two hours before
     lambda c: c["snapshot"].get("dex") == "pumpswap" and not c["token"].endswith("pump")
     and (c["snapshot"].get("age_min") if c["snapshot"].get("age_min") is not None else 99) < 1.5),
    # the --search's best rule on 153 tokens, the only one so far that held on the unseen half
    # (+25 to +38 % on 14-16 trades); with the exit it was found with
    ("Kaufdruck ≥ 3 (Liq ≥ 15k, ≥ 8 Käufe, Alter ≤ 30 min, Bewertung/Liq ≤ 3x, ohne RugCheck-Gefahr)",
     1792420200.0,      # 19 Oct 2026 14:30 UTC
     lambda c: not (c["snapshot"].get("rug") or {}).get("danger") and _passes(c["snapshot"], {
         "min_liquidity_usd": 15000, "min_buys_m5": 8, "min_buy_sell_ratio": 3.0, "change_m5": (-100, 1e9),
         "max_age_min": 30, "max_fdv_liquidity": 3}),
     {"stop_loss_pct": -30, "trailing_stop_pct": 35, "time_stop_minutes": 60, "take_profit_ladder": [[100, 0.5]]}),
]


def probes(cands: list[dict[str, Any]], ex: dict[str, Any], fee: float, slip: float,
           table: Optional[list] = None) -> list[str]:
    pool = entries(cands, None)
    lines = []
    for name, start, rule, *own_exit in PROBES if table is None else table:
        ex_used = own_exit[0] if own_exit else ex
        hits = [c for c in pool if rule(c)]
        rugs = lambda cs: sum(min(x for _, x in c["path"]) <= c["price_usd"] * 0.1 for c in cs)
        before = [c for c in hits if c["seen_at"] < start]
        after = [c for c in hits if c["seen_at"] >= start]
        lines += [f"Probe: {name}",
                  f"  Daten, aus denen die Idee stammt: {stats(run(before, ex_used, fee, slip))} · Rugs {rugs(before)}",
                  f"  danach – die eigentliche Probe:   {stats(run(after, ex_used, fee, slip))} · Rugs {rugs(after)}"]
    return lines


def report(db_path: Path, cfg: dict[str, Any], since: float = 0.0) -> str:
    cands = load(db_path, since)
    fee, slip = float(cfg["paper"]["fee_pct"]), float(cfg["paper"]["slippage_pct"])
    lines = [f"{len(cands)} Kandidaten mit Kursverlauf · Kosten je Seite {fee:g} % Gebühr + {slip:g} % Slippage"]
    if not cands:
        return "\n".join(lines + ["noch keine Kursverläufe – der Tracker zeichnet sie ab dieser Version auf"])
    profiles = {"eingestellt": cfg}
    try:
        profiles.update({name: apply_flat(cfg, flat) for name, flat in json.loads(PRESETS.read_text()).items()})
    except (OSError, ValueError):
        pass
    combos = [dict(zip(GRID, values)) for values in itertools.product(*GRID.values())]
    pool = entries(cands, None)
    lines.append(f"Vergleich – jeder Pool-Token gekauft, Ausstiege wie eingestellt: {stats(run(pool, cfg['exits'], fee, slip))}")
    lines += [""] + rug_table(cands)
    lines += [""] + probes(cands, cfg["exits"], fee, slip)
    for name, pcfg in profiles.items():
        trades = entries(cands, pcfg)
        lines.append(f"\n{name}: {stats(run(trades, pcfg['exits'], fee, slip))}")
        if len(trades) < 2 * MIN_TRADES:
            lines.append(f"  zu wenige Käufe für einen Vergleich der Ausstiege (mindestens {2 * MIN_TRADES})")
            continue
        half = len(trades) // 2
        first, second = trades[:half], trades[half:]
        best = max(combos, key=lambda ex: statistics.mean(run(first, ex, fee, slip)))
        lines.append(f"  beste Ausstiege auf der ersten Hälfte: {label(best)}")
        lines.append(f"    erste Hälfte (gewählt):  {stats(run(first, best, fee, slip))}")
        lines.append(f"    zweite Hälfte (ungesehen): {stats(run(second, best, fee, slip))}")
        lines.append(f"    eingestellt, zweite Hälfte: {stats(run(second, pcfg['exits'], fee, slip))}")
    return "\n".join(lines)


# --search: which entry rules would have earned money? Every combination of these thresholds,
# each with a handful of exit settings, chosen on the first half and shown on the second.
ENTRY_GRID = {
    "min_liquidity_usd": [8000, 15000, 30000],
    "min_buys_m5": [8, 30, 100],
    "min_buy_sell_ratio": [1.0, 1.5, 3.0],
    "change_m5": [(0, 50), (0, 150), (-100, 1e9)],
    "max_age_min": [30, 120, 1e9],
    "max_fdv_liquidity": [1.5, 3, 1e9],
}
EXIT_SET = [
    {"stop_loss_pct": -30, "trailing_stop_pct": 25, "time_stop_minutes": 60, "take_profit_ladder": [[50, 0.5], [100, 0.25]]},
    {"stop_loss_pct": -20, "trailing_stop_pct": 15, "time_stop_minutes": 20, "take_profit_ladder": [[25, 0.5], [50, 0.25]]},
    {"stop_loss_pct": -15, "trailing_stop_pct": 15, "time_stop_minutes": 10, "take_profit_ladder": [[25, 0.5]]},
    {"stop_loss_pct": -30, "trailing_stop_pct": 35, "time_stop_minutes": 60, "take_profit_ladder": [[100, 0.5]]},
    {"stop_loss_pct": -40, "trailing_stop_pct": 25, "time_stop_minutes": 30, "take_profit_ladder": []},
    {"stop_loss_pct": -20, "trailing_stop_pct": 25, "time_stop_minutes": 30, "take_profit_ladder": [[50, 0.5], [100, 0.25]]},
]


def _passes(s: dict[str, Any], rule: dict[str, Any]) -> bool:
    try:
        liq, fdv = float(s["liquidity_usd"]), float(s.get("fdv") or 0)
        lo, hi = rule["change_m5"]
        return (liq >= rule["min_liquidity_usd"] and s["buys_m5"] >= rule["min_buys_m5"]
                and s["buys_m5"] >= rule["min_buy_sell_ratio"] * max(1, s["sells_m5"])
                and lo <= s["change_m5"] <= hi and (s.get("age_min") or 0) <= rule["max_age_min"]
                and (fdv <= 0 or fdv / liq <= rule["max_fdv_liquidity"]))
    except (KeyError, TypeError, ValueError, ZeroDivisionError):
        return False


def _rule_label(rule: dict[str, Any]) -> str:
    lo, hi = rule["change_m5"]
    big = lambda v, unit="": "egal" if v >= 1e9 else f"{v:g}{unit}"
    change = "egal" if hi >= 1e9 else f"{lo:g} bis {hi:g} %"
    return (f"Liq ≥ {rule['min_liquidity_usd'] / 1000:g}k · Käufe ≥ {rule['min_buys_m5']} · Kauf/Verkauf ≥ {rule['min_buy_sell_ratio']:g}"
            f" · 5m {change} · Alter ≤ {big(rule['max_age_min'], ' min')} · Bewertung/Liq ≤ {big(rule['max_fdv_liquidity'], 'x')}")


def search(db_path: Path, cfg: dict[str, Any], since: float = 0.0, top: int = 5) -> str:
    """Every entry rule of ENTRY_GRID with every exit of EXIT_SET, judged honestly: the
    ranking uses the first half of the time only, the second half is shown beside it.
    With hundreds of combinations the best of the first half is partly luck - only what
    holds on the second half counts."""
    fee, slip = float(cfg["paper"]["fee_pct"]), float(cfg["paper"]["slippage_pct"])
    # pool tokens without a safety danger (the bot never buys those), first verdict each
    pool = [c for c in entries(load(db_path, since), None) if not ((c["snapshot"].get("rug") or {}).get("danger"))]
    if len(pool) < 4 * MIN_TRADES:
        return f"Suche: erst {len(pool)} Pool-Tokens mit Kursverlauf – zu wenig (mindestens {4 * MIN_TRADES})"
    half_at = pool[len(pool) // 2]["seen_at"]
    rets = [[simulate(c["price_usd"], c["seen_at"], c["path"], ex, fee, slip)[0] for ex in EXIT_SET] for c in pool]
    rules = [dict(zip(ENTRY_GRID, values)) for values in itertools.product(*ENTRY_GRID.values())]
    found = []
    seen: set[tuple[int, ...]] = set()
    for rule in rules:                                      # the loosest rule first: it names a set of trades
        picked = [i for i, c in enumerate(pool) if _passes(c["snapshot"], rule)]
        first = [i for i in picked if pool[i]["seen_at"] < half_at]
        second = [i for i in picked if pool[i]["seen_at"] >= half_at]
        if len(first) < MIN_TRADES or len(second) < MIN_TRADES // 2 or tuple(picked) in seen:
            continue
        seen.add(tuple(picked))
        for e in range(len(EXIT_SET)):
            a = [rets[i][e] for i in first]
            b = [rets[i][e] for i in second]
            found.append((statistics.mean(a), rule, e, a, b))
    lines = [f"Suche über {len(rules)} Einstiegsregeln ({len(seen)} verschiedene Auswahlen) × {len(EXIT_SET)} Ausstiege auf {len(pool)} Pool-Tokens "
             f"(Rangfolge nur nach der ersten Hälfte, {sum(c['seen_at'] < half_at for c in pool)} Tokens):"]
    all_b = [rets[i][0] for i, c in enumerate(pool) if c["seen_at"] >= half_at]
    lines.append(f"  zum Vergleich, jeder Pool-Token, zweite Hälfte: {stats(all_b)}")
    if not found:
        return "\n".join(lines + ["  keine Regel mit genug Käufen in beiden Hälften"])
    found.sort(key=lambda x: x[0], reverse=True)
    for mean_a, rule, e, a, b in found[:top]:
        lines.append(f"\n  {_rule_label(rule)}\n    Ausstieg: {label(EXIT_SET[e])}")
        lines.append(f"    erste Hälfte:  {stats(a)}")
        lines.append(f"    zweite Hälfte: {stats(b)}")
    both = sum(1 for m, _, _, a, b in found if m > 0 and statistics.mean(b) > 0)
    lines.append(f"\n  {both} von {len(found)} Kombinationen lagen in beiden Hälften im Plus "
                 f"({sum(1 for m, *_ in found if m > 0)} in der ersten)")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    since = float(argv[argv.index("--since") + 1]) if "--since" in argv else 0.0
    if "--since" in argv:
        args = [a for a in args if a != argv[argv.index("--since") + 1]]
    target = Path(args[0])
    db_path = target / "bot.sqlite" if target.is_dir() else target
    cfg = load_config(db_path.parent)
    cfg.pop("_dropped", None)
    print(report(db_path, cfg, since))
    if "--search" in argv:
        print()
        print(search(db_path, cfg, since))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
