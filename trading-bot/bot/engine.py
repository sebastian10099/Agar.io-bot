"""The polling loop: discover -> evaluate -> record -> (paper) trade -> manage exits."""
from __future__ import annotations

import threading
import time
from typing import Any, Callable, Optional

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
        self.last_prices: dict[str, float] = {}
        self.poll_count = 0
        self.errors = 0
        self._stop = threading.Event()

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
            self._stop.wait(max(1.0, interval - (time.time() - started)))
        self.store.log("info", "engine stopped")

    def stop(self) -> None:
        self._stop.set()

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
            "last_poll": self.last_poll, "polls": self.poll_count, "errors": self.errors,
            "initial": self.paper.initial, "bankroll": round(self.paper.bankroll(), 2),
            "cash": round(self.paper.cash(), 2), "exposure": round(self.paper.exposure(), 2),
            "unrealized": round(unrealized_total, 2), "daily_pnl": round(self.paper.daily_pnl(), 2),
            "daily_limit_hit": self.paper.daily_limit_hit(),
            "stats": self.store.stats(), "open_positions": open_positions,
            "closed": self.store.closed_positions(50), "candidates": self.store.candidates(80),
            "edge": self.store.edge_report(), "events": self.store.events(60),
            "config": {k: self.cfg[k] for k in ("filters", "exits", "scoring", "risk_per_trade_pct",
                                                "max_open_positions", "daily_loss_limit_pct")},
        }
