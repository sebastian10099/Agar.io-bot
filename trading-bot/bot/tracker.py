"""Forward-return tracker. Records what happened to EVERY candidate after
5, 15 and 60 minutes - bought, skipped or watched - so the edge report can
compare the buckets. Without this you are guessing."""
from __future__ import annotations

import time
from typing import Any, Callable, Optional

from .store import Store


class Tracker:
    def __init__(self, store: Store, cfg: dict[str, Any],
                 price_of: Callable[[str, str], Optional[float]]) -> None:
        self.store = store
        self.horizons = [int(h) for h in cfg["tracker"]["horizons_minutes"]]
        self.price_of = price_of

    def record(self, candidate: dict[str, Any]) -> int:
        cid = self.store.add_candidate(candidate)
        self.store.schedule_outcomes(cid, candidate["seen_at"], self.horizons)
        return cid

    def fill_due(self, now: Optional[float] = None, max_lookups: int = 20) -> int:
        now = now or time.time()
        filled = 0
        cache: dict[tuple[str, str], Optional[float]] = {}
        for row in self.store.due_outcomes(now, limit=max_lookups):
            key = (row["chain"], row["pair"])
            if key not in cache:
                cache[key] = self.price_of(row["chain"], row["pair"])
            price = cache[key]
            base = row["price_usd"] or 0
            change = (price / base - 1) * 100 if price and base > 0 else None
            self.store.fill_outcome(row["candidate_id"], row["horizon_min"], price, change)
            filled += 1
        return filled
