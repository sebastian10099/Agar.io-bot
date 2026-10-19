"""Forward-return tracker. Records what happened to EVERY candidate after
5, 15 and 60 minutes - bought, skipped or watched - so the edge report can
compare the buckets. Without this you are guessing.

Two things keep the numbers honest:
- prices are fetched in batches (up to 30 pairs per request), so a busy
  poll does not build a backlog that would measure a "5-minute" outcome
  forty minutes late;
- a pair that stops being priced while the source still prices the others
  has been pulled (a rug): that outcome is a total loss, -100 %, not a gap.
  Leaving it out would flatter every bucket that contains rugs.
"""
from __future__ import annotations

import time
from typing import Any, Callable, Optional

from .store import Store

VANISHED_GRACE_S = 10 * 60     # no price this long past due, while others are priced -> -100 %
GIVE_UP_S = 60 * 60            # no answer at all this long past due -> unknown (never a loss)
LATE_OK_S = 120                # a price this late (or half the horizon) still measures the horizon; later
                               # (an outage, a restart) it would be another horizon's outcome -> unknown
OUTCOME_MAX = 1000.0           # a price this many times the one seen is a bad quote (a pool at a made-up
                               # price), not an outcome: it would swamp every average -> unknown
BATCH = 30                     # pairs per request (DexScreener's limit)
MAX_DUE = 600                  # outcomes handled per poll
MAX_SINGLE = 20                # single lookups per poll when no batch source exists


class Tracker:
    def __init__(self, store: Store, cfg: dict[str, Any],
                 price_of: Callable[[str, str], Optional[float]],
                 prices_of: Optional[Callable[[str, list[str], dict[str, str]], dict[str, float]]] = None) -> None:
        self.store = store
        self.horizons = [int(h) for h in cfg["tracker"]["horizons_minutes"]]
        self.price_of = price_of
        self.prices_of = prices_of

    def record(self, candidate: dict[str, Any]) -> int:
        cid = self.store.add_candidate(candidate)
        self.store.schedule_outcomes(cid, candidate["seen_at"], self.horizons)
        return cid

    def _lookup(self, rows: list[dict[str, Any]]) -> tuple[dict[tuple[str, str], float], set[tuple[str, str]]]:
        """Prices for the due rows, and the pairs whose request the source answered: only
        there does a missing price mean the pair is gone (a failed request means nothing)."""
        prices: dict[tuple[str, str], float] = {}
        answered: set[tuple[str, str]] = set()
        by_chain: dict[str, list[str]] = {}
        tokens: dict[str, str] = {}
        for r in rows:
            pairs = by_chain.setdefault(r["chain"], [])
            if r["pair"] not in pairs:
                pairs.append(r["pair"])
            tokens[r["pair"]] = r["token"]
        for chain, pairs in by_chain.items():
            if self.prices_of is not None:
                for i in range(0, len(pairs), BATCH):
                    chunk = pairs[i:i + BATCH]
                    try:
                        # a graduated curve is priced from its new pool, not counted as a rug
                        got = self.prices_of(chain, chunk, {p: tokens[p] for p in chunk}) or {}
                    except Exception:  # noqa: BLE001 - an outage is handled like "no answer"
                        continue
                    hits = {pair: float(price) for pair, price in got.items() if price and price > 0}
                    for pair, price in hits.items():
                        prices[(chain, pair)] = price
                    if hits:                               # the request was answered: its silent pairs are gone
                        answered.update((chain, pair) for pair in chunk)
            else:
                asked = pairs[:MAX_SINGLE]
                for pair in asked:
                    try:
                        price = self.price_of(chain, pair)
                    except Exception:  # noqa: BLE001
                        price = None
                    if price and price > 0:
                        prices[(chain, pair)] = float(price)
                        answered.add((chain, pair))
        return prices, answered

    def fill_due(self, now: Optional[float] = None, max_lookups: int = MAX_DUE) -> int:
        now = now or time.time()
        rows = self.store.due_outcomes(now, limit=max_lookups)
        if not rows:
            return 0
        prices, answered = self._lookup(rows)
        filled = 0
        for row in rows:
            price = prices.get((row["chain"], row["pair"]))
            base = row["price_usd"] or 0
            late = now - row["due_at"]
            if price and base > 0 and price > base * OUTCOME_MAX:
                self.store.fill_outcome(row["candidate_id"], row["horizon_min"], None, None)
            elif price and late <= max(LATE_OK_S, row["horizon_min"] * 30):
                change = (price / base - 1) * 100 if base > 0 else None
                self.store.fill_outcome(row["candidate_id"], row["horizon_min"], price, change)
            elif price:
                self.store.fill_outcome(row["candidate_id"], row["horizon_min"], None, None)   # too late to say
            elif (row["chain"], row["pair"]) in answered and late >= VANISHED_GRACE_S:
                self.store.fill_outcome(row["candidate_id"], row["horizon_min"], 0.0, -100.0 if base > 0 else None)
            elif late >= GIVE_UP_S:
                self.store.fill_outcome(row["candidate_id"], row["horizon_min"], None, None)
            else:
                continue                                    # try again next poll
            filled += 1
        return filled
