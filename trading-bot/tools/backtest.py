"""Backtest on recorded price paths: what would the rules have earned?

The tracker follows every pool token it judges for an hour (the paths table:
its price every poll, reserve prices). This replays entry rules and exit
settings on those paths - hundreds of trades an hour instead of the handful
the paper account can hold - with the paper account's own costs and exit
logic (stop loss first, then the profit ladder, the trailing stop, the time
stop).

    python3 tools/backtest.py <data dir or bot.sqlite> [--since EPOCH]

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
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
