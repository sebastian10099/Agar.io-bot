"""SQLite persistence. One file, a handful of tables, no ORM."""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Iterable, Optional

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

    def schedule_outcomes(self, candidate_id: int, seen_at: float, horizons: Iterable[int]) -> None:
        for h in horizons:
            self._exec("INSERT OR IGNORE INTO outcomes(candidate_id, horizon_min, due_at) "
                       "VALUES (?,?,?)", (candidate_id, h, seen_at + h * 60))

    def due_outcomes(self, now: float, limit: int = 30) -> list[dict[str, Any]]:
        return self._rows(
            "SELECT o.candidate_id, o.horizon_min, c.chain, c.token, c.pair, c.price_usd "
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
        return rows

    def edge_report(self) -> list[dict[str, Any]]:
        """Average forward return per decision bucket and horizon. This is the
        number that says whether the filter has an edge at all."""
        return self._rows(
            "SELECT c.decision, o.horizon_min, COUNT(*) AS n, "
            "AVG(o.change_pct) AS avg_change_pct, "
            "SUM(CASE WHEN o.change_pct > 0 THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS win_rate "
            "FROM outcomes o JOIN candidates c ON c.id = o.candidate_id "
            "WHERE o.filled_at IS NOT NULL AND o.change_pct IS NOT NULL "
            "GROUP BY c.decision, o.horizon_min ORDER BY c.decision, o.horizon_min")

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
            self._conn.execute("DELETE FROM positions")
            if what == "all":
                self._conn.execute("DELETE FROM outcomes")
                self._conn.execute("DELETE FROM candidates")
            self._conn.commit()

    def has_open_for(self, chain: str, token: str) -> bool:
        return self._one("SELECT 1 FROM positions WHERE status='open' AND chain=? AND token=?",
                         (chain, token)) is not None

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
        row = self._one("SELECT COALESCE(SUM(realized_usd),0) AS s FROM positions "
                        "WHERE closed_at IS NOT NULL AND closed_at >= ?", (since,))
        return float(row["s"]) if row else 0.0

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
