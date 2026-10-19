"""SQLite persistence. One file, a handful of tables, no ORM."""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Iterable, Optional

# an outcome above +99,900 % (1000x) is a bad quote, not a market (the tracker books those as unknown
# since; older databases still hold some) - one of them would swamp every average
OUTCOME_CAP_PCT = 99_900.0

SCHEMA = """
CREATE TABLE IF NOT EXISTS candidates (
    id INTEGER PRIMARY KEY,
    seen_at REAL NOT NULL,
    chain TEXT NOT NULL,
    token TEXT NOT NULL,
    pair TEXT NOT NULL,
    symbol TEXT,
    price_usd REAL,
    score REAL,
    decision TEXT NOT NULL,
    reasons TEXT,
    snapshot TEXT
);
CREATE INDEX IF NOT EXISTS idx_candidates_token ON candidates(chain, token, seen_at);

CREATE TABLE IF NOT EXISTS outcomes (
    candidate_id INTEGER NOT NULL,
    horizon_min INTEGER NOT NULL,
    due_at REAL NOT NULL,
    price_usd REAL,
    change_pct REAL,
    filled_at REAL,
    PRIMARY KEY (candidate_id, horizon_min)
);

-- the price of a candidate every poll for an hour after it was judged (pool tokens): what the
-- rules would have earned with any entry and exit settings, without waiting for real trades
CREATE TABLE IF NOT EXISTS paths (
    candidate_id INTEGER NOT NULL,
    at REAL NOT NULL,
    price REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_paths ON paths(candidate_id, at);

CREATE TABLE IF NOT EXISTS positions (
    id INTEGER PRIMARY KEY,
    opened_at REAL NOT NULL,
    closed_at REAL,
    chain TEXT NOT NULL,
    token TEXT NOT NULL,
    pair TEXT NOT NULL,
    symbol TEXT,
    entry_price REAL NOT NULL,
    size_usd REAL NOT NULL,
    remaining_frac REAL NOT NULL DEFAULT 1.0,
    peak_price REAL NOT NULL,
    realized_usd REAL NOT NULL DEFAULT 0,
    ladder_done TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL,
    exit_reason TEXT
);

CREATE TABLE IF NOT EXISTS trades (
    id INTEGER PRIMARY KEY,
    position_id INTEGER NOT NULL,
    at REAL NOT NULL,
    side TEXT NOT NULL,
    price REAL NOT NULL,
    usd REAL NOT NULL,
    frac REAL NOT NULL,
    reason TEXT
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    at REAL NOT NULL,
    level TEXT NOT NULL,
    message TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ticks (
    position_id INTEGER NOT NULL,
    at REAL NOT NULL,
    price REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS ticks_pos ON ticks(position_id, at);

CREATE TABLE IF NOT EXISTS kv (
    key TEXT PRIMARY KEY,
    value TEXT
);
"""


class Store:
    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(str(self.path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.executescript(SCHEMA)

    # --- helpers ---------------------------------------------------------
    def _exec(self, sql: str, params: Iterable[Any] = ()) -> sqlite3.Cursor:
        with self._lock:
            cur = self._conn.execute(sql, tuple(params))
            self._conn.commit()
            return cur

    def _rows(self, sql: str, params: Iterable[Any] = ()) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(r) for r in self._conn.execute(sql, tuple(params)).fetchall()]

    def _one(self, sql: str, params: Iterable[Any] = ()) -> Optional[dict[str, Any]]:
        rows = self._rows(sql, params)
        return rows[0] if rows else None

    # --- events ----------------------------------------------------------
    def log(self, level: str, message: str) -> None:
        self._exec("INSERT INTO events(at, level, message) VALUES (?,?,?)",
                   (time.time(), level, message[:1000]))

    def events(self, limit: int = 100) -> list[dict[str, Any]]:
        return self._rows("SELECT * FROM events ORDER BY id DESC LIMIT ?", (limit,))

    # --- kv --------------------------------------------------------------
    def get(self, key: str, default: Any = None) -> Any:
        row = self._one("SELECT value FROM kv WHERE key=?", (key,))
        return json.loads(row["value"]) if row else default

    def set(self, key: str, value: Any) -> None:
        self._exec("INSERT OR REPLACE INTO kv(key, value) VALUES (?,?)", (key, json.dumps(value)))

    # --- candidates / outcomes ------------------------------------------
    def add_candidate(self, c: dict[str, Any]) -> int:
        cur = self._exec(
            "INSERT INTO candidates(seen_at, chain, token, pair, symbol, price_usd, score, "
            "decision, reasons, snapshot) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (c["seen_at"], c["chain"], c["token"], c["pair"], c.get("symbol"),
             c.get("price_usd"), c.get("score"), c["decision"],
             json.dumps(c.get("reasons", [])), json.dumps(c.get("snapshot", {}))))
        return int(cur.lastrowid)

    def last_seen(self, chain: str, token: str) -> Optional[float]:
        row = self._one("SELECT MAX(seen_at) AS t FROM candidates WHERE chain=? AND token=?",
                        (chain, token))
        return row["t"] if row and row["t"] is not None else None

    def verdicts_since(self, since: float) -> list[dict[str, Any]]:
        """Evaluations since `since`, oldest first (what the engine re-reads after a restart)."""
        rows = self._rows("SELECT seen_at, chain, token, decision, reasons, snapshot FROM candidates "
                          "WHERE seen_at >= ? ORDER BY seen_at, id", (since,))
        for r in rows:
            try:
                r["reasons"] = json.loads(r["reasons"] or "[]")
                r["snapshot"] = json.loads(r["snapshot"] or "{}")
            except json.JSONDecodeError:
                r["reasons"], r["snapshot"] = [], {}
        return rows

    def last_verdict(self, chain: str, token: str) -> Optional[dict[str, Any]]:
        """Most recent evaluation of a token: when, what, and why."""
        row = self._one("SELECT seen_at, decision, reasons FROM candidates WHERE chain=? AND token=? "
                        "ORDER BY seen_at DESC LIMIT 1", (chain, token))
        if not row:
            return None
        try:
            row["reasons"] = json.loads(row["reasons"] or "[]")
        except json.JSONDecodeError:
            row["reasons"] = []
        return row

    def schedule_outcomes(self, candidate_id: int, seen_at: float, horizons: Iterable[int]) -> None:
        for h in horizons:
            self._exec("INSERT OR IGNORE INTO outcomes(candidate_id, horizon_min, due_at) "
                       "VALUES (?,?,?)", (candidate_id, h, seen_at + h * 60))

    def add_path_points(self, points: list[tuple[int, float, float]]) -> None:
        """[(candidate id, time, price)] in one transaction: a poll's samples."""
        if points:
            with self._lock:
                self._conn.executemany("INSERT INTO paths(candidate_id, at, price) VALUES (?,?,?)", points)
                self._conn.commit()

    def paths_since(self, since: float) -> list[dict[str, Any]]:
        """Candidates seen since `since` that have a path, newest last."""
        return self._rows("SELECT DISTINCT c.id, c.chain, c.token, c.pair, c.seen_at FROM candidates c "
                          "JOIN paths p ON p.candidate_id = c.id WHERE c.seen_at >= ? ORDER BY c.seen_at", (since,))

    def due_outcomes(self, now: float, limit: int = 30) -> list[dict[str, Any]]:
        return self._rows(
            "SELECT o.candidate_id, o.horizon_min, o.due_at, c.chain, c.token, c.pair, c.price_usd "
            "FROM outcomes o JOIN candidates c ON c.id = o.candidate_id "
            "WHERE o.filled_at IS NULL AND o.due_at <= ? ORDER BY o.due_at LIMIT ?",
            (now, limit))

    def fill_outcome(self, candidate_id: int, horizon: int, price: Optional[float],
                     change_pct: Optional[float]) -> None:
        self._exec("UPDATE outcomes SET price_usd=?, change_pct=?, filled_at=? "
                   "WHERE candidate_id=? AND horizon_min=?",
                   (price, change_pct, time.time(), candidate_id, horizon))

    def candidates(self, limit: int = 200) -> list[dict[str, Any]]:
        rows = self._rows("SELECT * FROM candidates ORDER BY id DESC LIMIT ?", (limit,))
        for r in rows:
            r["reasons"] = json.loads(r["reasons"] or "[]")
            r["snapshot"] = json.loads(r["snapshot"] or "{}")
            r["outcomes"] = {}
        if rows:
            by_id = {r["id"]: r for r in rows}
            for o in self._rows("SELECT candidate_id, horizon_min, change_pct FROM outcomes "
                                "WHERE filled_at IS NOT NULL AND candidate_id >= ?", (rows[-1]["id"],)):
                c = by_id.get(o["candidate_id"])
                if c is not None:
                    c["outcomes"][str(o["horizon_min"])] = None if o["change_pct"] is None else round(o["change_pct"], 2)
        return rows

    # which filter throws candidates out, and how often (last `limit` candidates)
    REASON_RULES = [
        ("too new", "zu neu (Mindestalter)", "filters.min_age_minutes"),
        ("too old", "zu alt (Höchstalter)", "filters.max_age_minutes"),
        ("age unknown", "Alter unbekannt (Quelle liefert kein Listing-Datum)", None),
        ("liquidity $", "Liquidität zu klein", "filters.min_liquidity_usd"),
        ("liquidity unknown", "Liquidität unbekannt (Bonding-Kurve ohne Angabe)", None),
        ("curve completed", "Kurve abgeschlossen (Handel wechselt in den Pool)", None),
        ("too large for a new token", "Liquidität zu groß", "filters.max_liquidity_usd"),
        ("5m volume", "5-Minuten-Volumen zu klein", "filters.min_volume_m5_usd"),
        ("5m buys", "zu wenige Käufe in 5 min", "filters.min_buys_m5"),
        ("buy/sell", "Käufe/Verkäufe zu niedrig", "filters.min_buy_sell_ratio_m5"),
        ("parabolic", "zu spät, parabolisch", "filters.max_price_change_m5_pct"),
        ("falling", "fallend", "filters.min_price_change_m5_pct"),
        ("thin pool", "Bewertung zu hoch für den Pool", "filters.max_fdv_liquidity_ratio"),
        ("FDV", "FDV zu hoch", "filters.max_fdv_usd"),
        ("no price", "kein Kurs", None),
        ("rugcheck unavailable", "RugCheck nicht erreichbar (nur beobachtet)", "filters.allow_rugcheck_unknown"),
        ("holder check missing", "Halter unbekannt (nur beobachtet)", "filters.require_holder_check"),
        ("LP unknown", "LP-Halter unbekannt – nur Eigenprüfung (nur beobachtet)", "filters.require_rugcheck"),
        ("still on its bonding curve", "noch auf der Bonding-Kurve (nur beobachtet)", "filters.allow_curve_buys"),
        ("rugcheck danger", "RugCheck: Gefahr", "filters.require_rugcheck"),
        ("onchain danger", "Eigenprüfung: Gefahr (Freeze/Mint/Token-2022/Halter)", "filters.require_rugcheck"),
        ("rugcheck score", "RugCheck-Score zu hoch", "filters.max_rugcheck_score"),
        ("score ", "Score unter Schwelle (watch)", "scoring.min_score"),
        ("not opened", "Kauf blockiert (Limit, Pause, Bestand)", "max_open_positions"),
    ]

    def skip_reasons(self, limit: int = 200) -> dict[str, Any]:
        rows = self._rows("SELECT decision, reasons FROM candidates ORDER BY id DESC LIMIT ?", (limit,))
        counts: dict[str, int] = {}
        decisions = {"buy": 0, "watch": 0, "skip": 0}
        for r in rows:
            decisions[r["decision"]] = decisions.get(r["decision"], 0) + 1
            try:
                reasons = json.loads(r["reasons"] or "[]")
            except json.JSONDecodeError:
                reasons = []
            seen: set[str] = set()
            for reason in reasons:
                for needle, label, _ in self.REASON_RULES:
                    if needle in reason and label not in seen:
                        if needle == "score " and not reason.startswith("score "):
                            continue
                        seen.add(label)
                        counts[label] = counts.get(label, 0) + 1
                        break
        n = len(rows)
        by_label = {label: path for _, label, path in self.REASON_RULES}
        out = [{"label": label, "n": c, "share": round(c / n, 3) if n else 0, "path": by_label.get(label)}
               for label, c in sorted(counts.items(), key=lambda kv: -kv[1])]
        return {"n": n, "decisions": decisions, "reasons": out}

    def outcomes_for(self, cid: int) -> list[dict[str, Any]]:
        """Every horizon of one candidate, filled or still pending (due_at tells when)."""
        rows = self._rows("SELECT horizon_min, due_at, price_usd, change_pct, filled_at FROM outcomes "
                          "WHERE candidate_id=? ORDER BY horizon_min", (cid,))
        for r in rows:
            r["change_pct"] = None if r["change_pct"] is None else round(r["change_pct"], 2)
        return rows

    def edge_since(self) -> float:
        """Outcomes before this moment were measured with an older price model (the last
        trade's price, which flatters dying coins); the reports leave them out."""
        return float(self.get("edge_since", 0.0) or 0.0)

    def edge_report(self, key: str = "decision") -> list[dict[str, Any]]:
        """Average forward return per bucket and horizon. key='decision' groups by
        the final decision; 'rule_decision' / 'ai_decision' read the snapshot, so
        the rules and the model can be compared on the same candidates."""
        rows = self._rows(
            "SELECT c.decision, c.snapshot, o.horizon_min, o.change_pct "
            "FROM outcomes o JOIN candidates c ON c.id = o.candidate_id "
            "WHERE o.filled_at IS NOT NULL AND o.change_pct IS NOT NULL AND o.change_pct <= ? AND c.seen_at >= ?",
            (OUTCOME_CAP_PCT, self.edge_since()))
        buckets: dict[tuple, list[float]] = {}
        for r in rows:
            if key == "decision":
                label = r["decision"]
            else:
                try:
                    label = json.loads(r["snapshot"] or "{}").get(key)
                except json.JSONDecodeError:
                    label = None
            if not label:
                continue
            buckets.setdefault((label, r["horizon_min"]), []).append(float(r["change_pct"]))
        order = {"buy": 0, "watch": 1, "skip": 2}
        out = []
        for (label, horizon), vals in sorted(buckets.items(), key=lambda kv: (order.get(kv[0][0], 9), kv[0][1])):
            out.append({"decision": label, "horizon_min": horizon, "n": len(vals),
                        "avg_change_pct": sum(vals) / len(vals),
                        "win_rate": sum(1 for v in vals if v > 0) / len(vals)})
        return out

    # --- positions / trades ---------------------------------------------
    def open_position(self, p: dict[str, Any]) -> int:
        cur = self._exec(
            "INSERT INTO positions(opened_at, chain, token, pair, symbol, entry_price, size_usd, "
            "remaining_frac, peak_price, status) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (p["opened_at"], p["chain"], p["token"], p["pair"], p.get("symbol"),
             p["entry_price"], p["size_usd"], 1.0, p["entry_price"], "open"))
        return int(cur.lastrowid)

    def update_position(self, pid: int, **fields: Any) -> None:
        if not fields:
            return
        cols = ", ".join(f"{k}=?" for k in fields)
        self._exec(f"UPDATE positions SET {cols} WHERE id=?", (*fields.values(), pid))

    def add_trade(self, t: dict[str, Any]) -> None:
        self._exec("INSERT INTO trades(position_id, at, side, price, usd, frac, reason) "
                   "VALUES (?,?,?,?,?,?,?)",
                   (t["position_id"], t["at"], t["side"], t["price"], t["usd"], t["frac"],
                    t.get("reason")))

    def open_positions(self) -> list[dict[str, Any]]:
        rows = self._rows("SELECT * FROM positions WHERE status='open' ORDER BY opened_at")
        for r in rows:
            r["ladder_done"] = json.loads(r["ladder_done"] or "[]")
        return rows

    def closed_positions(self, limit: int = 100) -> list[dict[str, Any]]:
        return self._rows("SELECT * FROM positions WHERE status='closed' "
                          "ORDER BY closed_at DESC LIMIT ?", (limit,))

    def position(self, pid: int) -> Optional[dict[str, Any]]:
        row = self._one("SELECT * FROM positions WHERE id=?", (pid,))
        if row:
            row["ladder_done"] = json.loads(row["ladder_done"] or "[]")
        return row

    def reset(self, what: str) -> None:
        """'positions' wipes the paper book, 'all' also wipes candidates and outcomes
        (the edge data). Events are always kept so the reset itself is on record."""
        with self._lock:
            self._conn.execute("DELETE FROM trades")
            self._conn.execute("DELETE FROM ticks")
            self._conn.execute("DELETE FROM positions")
            if what == "all":
                self._conn.execute("DELETE FROM outcomes")
                self._conn.execute("DELETE FROM paths")
                self._conn.execute("DELETE FROM candidates")
            self._conn.commit()

    # --- price ticks per position (for the detail chart) ------------------
    def tick(self, pid: int, at: float, price: float) -> None:
        with self._lock:
            self._conn.execute("INSERT INTO ticks(position_id, at, price) VALUES (?,?,?)", (pid, at, price))
            self._conn.commit()

    def ticks_for(self, pid: int, limit: int = 3000) -> list[dict[str, Any]]:
        rows = self._rows("SELECT at, price FROM ticks WHERE position_id=? ORDER BY at DESC LIMIT ?", (pid, limit))
        rows.reverse()
        return rows

    def prune_history(self, before: float) -> dict[str, int]:
        """Drop candidates and their outcomes seen before `before` (positions,
        trades and events stay). Keeps the database and the per-poll reports
        bounded on a bot that runs for months."""
        with self._lock:
            o = self._conn.execute("DELETE FROM outcomes WHERE candidate_id IN (SELECT id FROM candidates WHERE seen_at < ?)", (before,)).rowcount
            self._conn.execute("DELETE FROM paths WHERE candidate_id IN (SELECT id FROM candidates WHERE seen_at < ?)", (before,))
            c = self._conn.execute("DELETE FROM candidates WHERE seen_at < ?", (before,)).rowcount
            self._conn.commit()
        return {"candidates": c, "outcomes": o}

    def prune_paths(self, before: float) -> int:
        """Drop price paths recorded before `before` (they are the bulk of the database)."""
        with self._lock:
            n = self._conn.execute("DELETE FROM paths WHERE at < ?", (before,)).rowcount
            self._conn.commit()
        return n

    def prune_ticks(self, before: float) -> int:
        """Drop ticks of positions closed before `before`; open ones keep theirs."""
        with self._lock:
            cur = self._conn.execute(
                "DELETE FROM ticks WHERE position_id IN (SELECT id FROM positions WHERE status='closed' AND closed_at < ?)"
                " OR position_id NOT IN (SELECT id FROM positions)", (before,))
            self._conn.commit()
            return cur.rowcount

    def exit_breakdown(self) -> list[dict[str, Any]]:
        """Closed positions grouped by exit reason: which rule earns, which costs."""
        rows = self._rows(
            "SELECT exit_reason AS reason, COUNT(*) AS n, SUM(realized_usd) AS total_usd, "
            "AVG(realized_usd / size_usd * 100) AS avg_pct, AVG(closed_at - opened_at) / 60 AS avg_minutes, "
            "SUM(CASE WHEN realized_usd > 0 THEN 1 ELSE 0 END) AS wins "
            "FROM positions WHERE status='closed' GROUP BY exit_reason ORDER BY n DESC, total_usd DESC")
        for r in rows:
            r["total_usd"] = round(r["total_usd"] or 0, 2)
            r["avg_pct"] = round(r["avg_pct"] or 0, 2)
            r["avg_minutes"] = round(r["avg_minutes"] or 0, 1)
            r["win_rate"] = round(r["wins"] / r["n"], 3) if r["n"] else 0
        return rows

    def last_closed_at(self, chain: str, token: str) -> Optional[float]:
        row = self._one("SELECT MAX(closed_at) AS at FROM positions WHERE status='closed' AND chain=? AND token=?",
                        (chain, token))
        return row["at"] if row else None

    def has_open_for(self, chain: str, token: str) -> bool:
        return self._one("SELECT 1 FROM positions WHERE status='open' AND chain=? AND token=?",
                         (chain, token)) is not None

    def candidate(self, cid: int) -> Optional[dict[str, Any]]:
        row = self._one("SELECT * FROM candidates WHERE id=?", (cid,))
        if row:
            row["reasons"] = json.loads(row["reasons"] or "[]")
            row["snapshot"] = json.loads(row["snapshot"] or "{}")
        return row

    def trades_for(self, pid: int) -> list[dict[str, Any]]:
        return self._rows("SELECT * FROM trades WHERE position_id=? ORDER BY id", (pid,))

    def trades(self, limit: int = 200) -> list[dict[str, Any]]:
        return self._rows("SELECT * FROM trades ORDER BY id DESC LIMIT ?", (limit,))

    def realized_all(self) -> float:
        """Realized P&L across every position, open ones included (entry fees
        and partial take-profits count the moment they happen)."""
        row = self._one("SELECT COALESCE(SUM(realized_usd),0) AS s FROM positions")
        return float(row["s"]) if row else 0.0

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def realized_since(self, since: float) -> float:
        """Realized P&L of the fills since `since`: partial take-profits and entry
        fees of positions that are still open count the moment they happen, as in
        realized_all(). A position's entry fee is its realized total minus its sells."""
        rows = self._rows(
            "SELECT p.opened_at, p.realized_usd, "
            "COALESCE(SUM(t.usd - p.size_usd * t.frac), 0) AS sells, "
            "COALESCE(SUM(CASE WHEN t.at >= ? THEN t.usd - p.size_usd * t.frac ELSE 0 END), 0) AS sells_since "
            "FROM positions p LEFT JOIN trades t ON t.position_id = p.id AND t.side = 'sell' "
            "WHERE p.opened_at >= ? OR p.id IN (SELECT position_id FROM trades WHERE side = 'sell' AND at >= ?) "
            "GROUP BY p.id", (since, since, since))
        total = 0.0
        for r in rows:
            total += float(r["sells_since"])
            if r["opened_at"] >= since:
                total += float(r["realized_usd"]) - float(r["sells"])      # the entry fee
        return total

    def sweep_samples(self, horizon_min: int) -> list[dict[str, Any]]:
        rows = self._rows(
            "SELECT c.snapshot, o.change_pct FROM outcomes o JOIN candidates c ON c.id = o.candidate_id "
            "WHERE o.filled_at IS NOT NULL AND o.change_pct IS NOT NULL AND o.horizon_min = ? AND o.change_pct <= ? "
            "AND c.seen_at >= ?", (horizon_min, OUTCOME_CAP_PCT, self.edge_since()))
        out = []
        for r in rows:
            try:
                out.append({"snapshot": json.loads(r["snapshot"] or "{}"), "change_pct": r["change_pct"]})
            except json.JSONDecodeError:
                continue
        return out

    def equity_curve(self, limit: int = 2000) -> list[dict[str, Any]]:
        """Realized bankroll after each closed position, oldest first: the
        series behind the equity chart. Entry fees of still-open positions are
        not in here; the dashboard adds the live unrealized value as a last point."""
        rows = self._rows("SELECT closed_at AS at, realized_usd, symbol, exit_reason FROM positions "
                          "WHERE status='closed' ORDER BY closed_at ASC LIMIT ?", (limit,))
        total = 0.0
        for r in rows:
            total += float(r["realized_usd"] or 0)
            r["cum_realized"] = round(total, 4)
        return rows

    def stats(self) -> dict[str, Any]:
        closed = self._one("SELECT COUNT(*) AS n, COALESCE(SUM(realized_usd),0) AS pnl, "
                           "SUM(CASE WHEN realized_usd>0 THEN 1 ELSE 0 END) AS wins "
                           "FROM positions WHERE status='closed'") or {}
        cands = self._one("SELECT COUNT(*) AS n, "
                          "SUM(CASE WHEN decision='buy' THEN 1 ELSE 0 END) AS buys "
                          "FROM candidates") or {}
        return {
            "closed": int(closed.get("n") or 0),
            "wins": int(closed.get("wins") or 0),
            "realized_usd": float(closed.get("pnl") or 0),
            "candidates": int(cands.get("n") or 0),
            "buys": int(cands.get("buys") or 0),
        }
