"""Runtime audit of a paper account: does what the bot did add up?

Checks the database of a running (or finished) bot against the rules it is
meant to follow - the accounting of every fill, each exit against the price
that triggered it, every automatic buy against the filters, the re-entry
pause and the holder rule, one position per token, cash never below zero.
Unit tests prove the code on made-up data; this proves the run on real data.

    python3 tools/audit.py <data dir or bot.sqlite> [state.json] [--since-start]

Exit code 0 when every check passes, 1 otherwise. The data dir's config.json
(over the defaults) is the configuration the run is checked against; with
--since-start only what the current run (state.json's started_at) did is held
against it - an earlier run may have had other settings."""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path
from typing import Any, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from bot.main import load_config  # noqa: E402
from bot.strategy import evaluate  # noqa: E402

EPS_USD = 0.02          # rounding of money
EPS_PCT = 0.05          # rounding of thresholds, in percentage points
AUTO_MATCH_S = 2.0      # an automatic buy is recorded as a "buy" verdict in the same poll


def _rows(db: sqlite3.Connection, sql: str, args: tuple = ()) -> list[dict[str, Any]]:
    return [dict(r) for r in db.execute(sql, args)]


def audit(db_path: Path, cfg: dict[str, Any], state: Optional[dict[str, Any]] = None,
          since: float = 0.0) -> list[dict[str, Any]]:
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        return _audit(db, cfg, state, since)
    finally:
        db.close()


def _audit(db: sqlite3.Connection, cfg: dict[str, Any], state: Optional[dict[str, Any]],
           since: float) -> list[dict[str, Any]]:
    fee = float(cfg["paper"]["fee_pct"]) / 100.0
    slip = float(cfg["paper"]["slippage_pct"]) / 100.0
    ex = cfg["exits"]
    every = _rows(db, "SELECT * FROM positions ORDER BY id")
    positions = [p for p in every if p["opened_at"] >= since]        # held against this configuration
    trades = _rows(db, "SELECT * FROM trades ORDER BY at, id")
    by_pos: dict[int, list[dict[str, Any]]] = {}
    for t in trades:
        by_pos.setdefault(t["position_id"], []).append(t)
    checks: list[dict[str, Any]] = []

    def check(name: str, problems: list[str], n: int) -> None:
        checks.append({"name": name, "ok": not problems, "n": n, "problems": problems[:10],
                       "more": max(0, len(problems) - 10)})

    # 1. every position's fills add up to what it shows
    bad: list[str] = []
    for p in positions:
        tag = f"#{p['id']} {p['symbol']}"
        buys = [t for t in by_pos.get(p["id"], []) if t["side"] == "buy"]
        sells = [t for t in by_pos.get(p["id"], []) if t["side"] == "sell"]
        if len(buys) != 1 or abs(buys[0]["price"] - p["entry_price"]) > 1e-12 * max(1.0, p["entry_price"]) \
                or abs(buys[0]["usd"] - p["size_usd"]) > EPS_USD:
            bad.append(f"{tag}: Kauf passt nicht zur Position")
        sold = sum(t["frac"] for t in sells)
        if abs(sold - (1.0 - p["remaining_frac"])) > 1e-6:
            bad.append(f"{tag}: verkauft {sold:.4f}, Rest {p['remaining_frac']:.4f}")
        closed = p["status"] == "closed"
        if closed != (p["remaining_frac"] <= 1e-9) or (closed and (not p["closed_at"] or not p["exit_reason"])):
            bad.append(f"{tag}: Status {p['status']} bei Rest {p['remaining_frac']:.4f}")
        if closed and sells and sells[-1]["reason"] != p["exit_reason"]:
            bad.append(f"{tag}: Ausstiegsgrund {p['exit_reason']} ≠ letzter Verkauf {sells[-1]['reason']}")
        for t in sells:
            expect = p["size_usd"] * t["frac"] * (t["price"] / p["entry_price"]) * (1 - fee)
            if abs(t["usd"] - expect) > EPS_USD:
                bad.append(f"{tag}: Verkauf {t['reason']} bringt {t['usd']:.2f} statt {expect:.2f}")
        realized = sum(t["usd"] - p["size_usd"] * t["frac"] for t in sells) - p["size_usd"] * fee
        if abs(realized - p["realized_usd"]) > EPS_USD:
            bad.append(f"{tag}: realisiert {p['realized_usd']:.2f} statt {realized:.2f}")
    check("Buchhaltung je Position (Kauf, Verkäufe, Gebühren, Rest, Status)", bad, len(positions))

    # 2. each exit fired at a price that meets its rule (the fill is the trigger minus slippage)
    bad = []
    n = 0
    for p in positions:
        for t in (x for x in by_pos.get(p["id"], []) if x["side"] == "sell"):
            n += 1
            trigger = t["price"] / (1 - slip)
            gain = (trigger / p["entry_price"] - 1) * 100
            reason = t["reason"] or ""
            tag = f"#{p['id']} {p['symbol']} {reason}"
            if reason == "stop_loss" and gain > float(ex["stop_loss_pct"]) + EPS_PCT:
                bad.append(f"{tag} bei {gain:+.1f} % (Stop {ex['stop_loss_pct']} %)")
            elif reason.startswith("take_profit_") and gain < float(reason.rsplit("_", 1)[1]) - EPS_PCT:
                bad.append(f"{tag} bei {gain:+.1f} %")
            elif reason == "trailing_stop":
                trail = float(ex["trailing_stop_pct"])
                peak_gain = (p["peak_price"] / p["entry_price"] - 1) * 100
                drawdown = (trigger / p["peak_price"] - 1) * 100
                if peak_gain < trail - EPS_PCT or drawdown > -trail + EPS_PCT:
                    bad.append(f"{tag}: Hoch {peak_gain:+.1f} %, Rückgang {drawdown:+.1f} % (Trailing {trail} %)")
            elif reason == "time_stop" and t["at"] - p["opened_at"] < float(ex["time_stop_minutes"]) * 60 - 1:
                bad.append(f"{tag} nach {(t['at'] - p['opened_at']) / 60:.1f} min")
    check("Ausstiege beim richtigen Kurs (Stop-Loss, Gewinnstufen, Trailing, Zeit)", bad, n)

    # 3. never two open positions in one token
    seen: dict[tuple[str, str], int] = {}
    bad = []
    for p in positions:
        if p["status"] == "open":
            key = (p["chain"], p["token"])
            if key in seen:
                bad.append(f"#{seen[key]} und #{p['id']} {p['symbol']} gleichzeitig offen")
            seen[key] = p["id"]
    check("höchstens eine offene Position je Token", bad, len(seen))

    # 4. cash, replayed fill by fill over the whole account, never below zero (each entry
    #    costs its size plus the fee it actually paid: realized total minus its sells)
    initial = float((state or {}).get("initial") or cfg["bankroll_usd"])
    paid: dict[int, float] = {}
    for p in every:
        sells = sum(t["usd"] - p["size_usd"] * t["frac"] for t in by_pos.get(p["id"], []) if t["side"] == "sell")
        paid[p["id"]] = p["size_usd"] + (sells - p["realized_usd"])
    cash, low, bad = initial, initial, []
    for t in trades:
        cash += t["usd"] if t["side"] == "sell" else -paid.get(t["position_id"], t["usd"])
        low = min(low, cash)
    if low < -EPS_USD:
        bad.append(f"Bargeld fiel auf {low:.2f} $")
    if state is not None and state.get("bankroll") is not None:
        shown = int((state.get("stats") or {}).get("closed", -1)) + len(state.get("open_positions") or [])
        last_fill = max((e["at"] for e in state.get("events") or [] if e.get("level") == "trade"), default=None)
        same = shown == len(every) and (last_fill is None or not trades or abs(last_fill - trades[-1]["at"]) < 1.0)
        if same:                                       # the same moment: same positions, same last fill
            want = initial + sum(p["realized_usd"] for p in every)
            if abs(float(state["bankroll"]) - want) > EPS_USD:
                bad.append(f"Bankroll {state['bankroll']:.2f} ≠ Start + realisiert {want:.2f}")
    check("Bargeld nie negativ, Bankroll = Start + realisiert", bad, len(trades))

    # 5. every automatic buy met the filters, the holder rule and the re-entry pause
    pause = float(cfg.get("reentry_pause_minutes") or 0) * 60
    closed_at = [(p["chain"], p["token"], p["closed_at"]) for p in positions if p["closed_at"]]
    bad = []
    n = 0
    for p in positions:
        c = db.execute("SELECT * FROM candidates WHERE chain=? AND token=? AND decision='buy' AND ABS(seen_at - ?) <= ? "
                       "ORDER BY ABS(seen_at - ?) LIMIT 1",
                       (p["chain"], p["token"], p["opened_at"], AUTO_MATCH_S, p["opened_at"])).fetchone()
        if c is None:
            continue                                   # a manual buy from the control page
        n += 1
        tag = f"#{p['id']} {p['symbol']}"
        snap = json.loads(c["snapshot"] or "{}")
        verdict = evaluate(snap, snap.get("rug"), cfg)
        if verdict["decision"] != "buy":
            bad.append(f"{tag}: nach den Regeln {verdict['decision']} – {'; '.join(verdict['reasons'][:2])}")
        rug = snap.get("rug") or {}
        if cfg["filters"].get("require_holder_check", True) and rug.get("source") == "onchain" \
                and not rug.get("holders") and not rug.get("creator"):
            bad.append(f"{tag}: gekauft ohne Halter- oder Ersteller-Prüfung")
        for chain, token, at in closed_at:
            if (chain, token) == (p["chain"], p["token"]) and 0 <= p["opened_at"] - at < pause:
                bad.append(f"{tag}: {(p['opened_at'] - at) / 60:.0f} min nach dem Verkauf zurückgekauft (Sperre {pause / 60:.0f} min)")
    check("automatische Käufe: Filter, Halter-Regel, Wiedereinstiegs-Sperre", bad, n)

    # 6. no verdict says "buy" while its reasons say it must not be bought
    rows = _rows(db, "SELECT id, symbol, reasons FROM candidates WHERE decision='buy' AND seen_at >= ?", (since,))
    bad = [f"Kandidat #{r['id']} {r['symbol']}: {r['reasons'][:80]}" for r in rows
           if any(k in (r["reasons"] or "") for k in ("watch only", "not opened", "holder check missing"))]
    check("kein Kauf-Urteil mit Sperrgrund", bad, len(rows))
    return checks


def render(checks: list[dict[str, Any]]) -> str:
    lines = []
    for c in checks:
        lines.append(f"{'OK    ' if c['ok'] else 'FEHLER'} {c['name']} ({c['n']} geprüft)")
        lines += [f"         – {p}" for p in c["problems"]]
        if c["more"]:
            lines.append(f"         … und {c['more']} weitere")
    passed = sum(c["ok"] for c in checks)
    lines.append(f"{passed} von {len(checks)} Laufzeit-Prüfungen bestanden.")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    flags = {a for a in argv if a.startswith("--")}
    args = [a for a in argv if not a.startswith("--")]
    target = Path(args[0])
    db_path = target / "bot.sqlite" if target.is_dir() else target
    cfg = load_config(db_path.parent)
    cfg.pop("_dropped", None)
    state = json.loads(Path(args[1]).read_text()) if len(args) > 1 else None
    since = float((state or {}).get("started_at") or 0) if "--since-start" in flags else 0.0
    checks = audit(db_path, cfg, state, since)
    print(render(checks))
    return 0 if all(c["ok"] for c in checks) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
