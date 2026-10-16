"""The polling loop: discover -> evaluate -> record -> (paper) trade -> manage exits."""
from __future__ import annotations

import threading
import time
from typing import Any, Callable, Optional

from . import settings
from .paper import Paper
from .store import Store
from .strategy import evaluate
from .tracker import Tracker

RESEE_SECONDS = 30 * 60  # do not re-evaluate the same token within half an hour


class Engine:
    def __init__(self, cfg: dict[str, Any], store: Store, dex: Any, rug: Any,
                 clock: Callable[[], float] = time.time) -> None:
        self.cfg = cfg
        self.store = store
        self.dex = dex
        self.rug = rug
        self.clock = clock
        self.paper = Paper(store, cfg)
        self.tracker = Tracker(store, cfg, dex.price)
        self.paused = False
        self.last_poll: Optional[float] = None
        self.last_poll_wall: Optional[float] = None   # real time, for the liveness indicator
        self.last_prices: dict[str, float] = {}
        self.poll_count = 0
        self.errors = 0
        self.started_at = clock()
        self.persist: Optional[Callable[[dict[str, Any]], None]] = None
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._lock = threading.Lock()

    # --- one cycle ------------------------------------------------------
    def poll_once(self) -> dict[str, int]:
        now = self.clock()
        counts = {"seen": 0, "new": 0, "buy": 0, "watch": 0, "skip": 0, "exits": 0}

        found = self.dex.recent_token_addresses(self.cfg["chains"])
        for chain, addresses in found.items():
            if not addresses:
                continue
            for p in self.dex.pairs_for_tokens(chain, addresses):
                counts["seen"] += 1
                last = self.store.last_seen(chain, p["token"])
                if last is not None and now - last < RESEE_SECONDS:
                    continue
                counts["new"] += 1
                rug = self.rug.summary(p["token"]) if chain == "solana" else None
                verdict = evaluate(p, rug, self.cfg)
                decision = verdict["decision"]
                if decision == "buy" and not self.paused:
                    blocked = self.paper.can_open(chain, p["token"])
                    if blocked:
                        decision = "watch"
                        verdict["reasons"].insert(0, f"not opened: {blocked}")
                elif decision == "buy" and self.paused:
                    decision = "watch"
                    verdict["reasons"].insert(0, "not opened: paused")
                counts[decision] += 1
                self.tracker.record({
                    "seen_at": now, "chain": chain, "token": p["token"], "pair": p["pair"],
                    "symbol": p.get("symbol"), "price_usd": p["price_usd"],
                    "score": verdict["score"], "decision": decision,
                    "reasons": verdict["reasons"], "snapshot": p,
                })
                if decision == "buy":
                    self.paper.open(p, now)
                    self.last_prices[p["pair"]] = p["price_usd"]

        for pos in self.store.open_positions():
            price = self.dex.price(pos["chain"], pos["pair"])
            if not price:
                continue
            self.last_prices[pos["pair"]] = price
            before = pos["status"]
            self.paper.update(pos, price, now)
            if pos["status"] != before:
                counts["exits"] += 1

        self.tracker.fill_due(now)
        self.last_poll = now
        self.last_poll_wall = time.time()
        self.poll_count += 1
        return counts

    # --- loop -----------------------------------------------------------
    def run(self) -> None:
        interval = float(self.cfg["poll_seconds"])
        self.store.log("info", f"engine started, mode={self.cfg['mode']}, every {interval:.0f}s")
        while not self._stop.is_set():
            started = time.time()
            try:
                c = self.poll_once()
                if c["new"] or c["exits"]:
                    self.store.log("poll", f"seen {c['seen']}, new {c['new']}: "
                                           f"buy {c['buy']} watch {c['watch']} skip {c['skip']}, "
                                           f"exits {c['exits']}")
            except Exception as error:  # noqa: BLE001 - keep the loop alive
                self.errors += 1
                self.store.log("error", f"{type(error).__name__}: {error}")
            interval = float(self.cfg["poll_seconds"])
            self._wake.wait(max(1.0, interval - (time.time() - started)))
            self._wake.clear()
        self.store.log("info", "engine stopped")

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()

    # --- controls (called from the dashboard thread) --------------------
    def poll_now(self) -> None:
        self._wake.set()

    def set_paused(self, paused: bool) -> None:
        self.paused = bool(paused)
        self.store.log("info", "dashboard: " + ("pausiert" if paused else "fortgesetzt"))

    def apply_config(self, patch: dict[str, Any]) -> dict[str, Any]:
        """Validate, apply live, persist. Returns {'ok', 'errors', 'config'}."""
        clean, errors = settings.validate(patch)
        if not errors:
            cross = settings.apply(self.cfg, clean)
            if cross:
                errors.update(cross)
        if errors:
            return {"ok": False, "errors": errors, "config": settings.flat(self.cfg)}
        if clean:
            if self.persist:
                try:
                    self.persist(clean)
                except OSError as error:
                    self.store.log("error", f"config not saved: {error}")
            self.store.log("info", "dashboard: " + ", ".join(f"{k}={v}" for k, v in clean.items()))
            self._wake.set()
        return {"ok": True, "errors": {}, "config": settings.flat(self.cfg)}

    def close_position(self, pid: int) -> dict[str, Any]:
        with self._lock:
            pos = self.store.position(pid)
            if pos is None or pos["status"] != "open":
                return {"ok": False, "error": "Position ist nicht offen"}
            price = self.dex.price(pos["chain"], pos["pair"]) or self.last_prices.get(pos["pair"])
            if not price:
                return {"ok": False, "error": "Kein Kurs verfügbar"}
            self.paper.close_manually(pos, price, self.clock())
            self.last_prices[pos["pair"]] = price
            return {"ok": True, "position": self.store.position(pid)}

    def reset(self, what: str, bankroll: Optional[float] = None) -> dict[str, Any]:
        if what not in ("positions", "all"):
            return {"ok": False, "error": "what muss 'positions' oder 'all' sein"}
        if bankroll is not None:
            try:
                bankroll = float(str(bankroll).replace(",", "."))
            except ValueError:
                return {"ok": False, "error": "Startkapital ist keine Zahl"}
            if not 10 <= bankroll <= 1e9:
                return {"ok": False, "error": "Startkapital muss zwischen 10 und 1.000.000.000 liegen"}
        with self._lock:
            self.store.reset(what)
            self.last_prices.clear()
            if bankroll is not None:
                self.cfg["bankroll_usd"] = bankroll
                self.paper.initial = bankroll
                if self.persist:
                    try:
                        self.persist({"bankroll_usd": bankroll})
                    except OSError as error:
                        self.store.log("error", f"config not saved: {error}")
            self.store.log("info", "dashboard: reset " + what + (f", Startkapital ${bankroll:,.2f}" if bankroll is not None else ""))
        return {"ok": True, "initial": self.paper.initial}

    def open_from_candidate(self, cid: int) -> dict[str, Any]:
        """Manual paper entry on a token the bot evaluated. The tracker keeps the
        original decision, so manual picks can be compared against the rules."""
        with self._lock:
            c = self.store.candidate(cid)
            if c is None:
                return {"ok": False, "error": "Kandidat nicht gefunden"}
            blocked = self.paper.can_open(c["chain"], c["token"])
            if blocked:
                return {"ok": False, "error": "Nicht eröffnet: " + blocked}
            fresh = self.dex.pair(c["chain"], c["pair"])
            price = fresh["price_usd"] if fresh and fresh["price_usd"] > 0 else None
            if not price:
                return {"ok": False, "error": "Kein aktueller Kurs für diesen Token"}
            p = {"chain": c["chain"], "token": c["token"], "pair": c["pair"], "symbol": c["symbol"], "price_usd": price}
            pid = self.paper.open(p, self.clock())
            self.last_prices[c["pair"]] = price
            self.store.log("trade", f"MANUAL BUY {c['symbol']} via Dashboard (Bot-Urteil: {c['decision']})")
            self._wake.set()
            return {"ok": True, "position": self.store.position(pid)}

    def position_detail(self, pid: int) -> dict[str, Any]:
        pos = self.store.position(pid)
        if pos is None:
            return {"ok": False, "error": "Position nicht gefunden"}
        return {"ok": True, "position": pos, "trades": self.store.trades_for(pid),
                "price": self.last_prices.get(pos["pair"])}

    # --- state for the dashboard ---------------------------------------
    def state(self) -> dict[str, Any]:
        now = self.clock()
        open_positions = []
        unrealized_total = 0.0
        for pos in self.store.open_positions():
            price = self.last_prices.get(pos["pair"])
            unreal = self.paper.unrealized(pos, price)
            unrealized_total += unreal
            open_positions.append({
                **pos, "price": price, "unrealized": round(unreal, 2),
                "gain_pct": round((price / pos["entry_price"] - 1) * 100, 1) if price else None,
                "age_min": round((now - pos["opened_at"]) / 60, 1),
            })
        return {
            "mode": self.cfg["mode"], "paused": self.paused, "now": now,
            "started_at": self.started_at, "poll_seconds": self.cfg["poll_seconds"],
            "wall_now": time.time(), "last_poll_wall": self.last_poll_wall,
            "chains": self.cfg["chains"],
            "last_poll": self.last_poll, "polls": self.poll_count, "errors": self.errors,
            "initial": self.paper.initial, "bankroll": round(self.paper.bankroll(), 2),
            "cash": round(self.paper.cash(), 2), "exposure": round(self.paper.exposure(), 2),
            "unrealized": round(unrealized_total, 2), "daily_pnl": round(self.paper.daily_pnl(), 2),
            "daily_limit_hit": self.paper.daily_limit_hit(),
            "stats": self.store.stats(), "open_positions": open_positions,
            "closed": self.store.closed_positions(50), "candidates": self.store.candidates(80),
            "edge": self.store.edge_report(), "events": self.store.events(60),
            "equity": self.store.equity_curve(),
            "config": settings.flat(self.cfg),
        }
