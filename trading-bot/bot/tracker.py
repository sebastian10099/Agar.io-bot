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

from .sources.dexscreener import payout_price
from .store import OUTCOME_CAP_PCT, Store

VANISHED_GRACE_S = 10 * 60     # no price this long past due, while others are priced -> -100 %
GIVE_UP_S = 60 * 60            # no answer at all this long past due -> unknown (never a loss)
LATE_OK_S = 120                # a price this late (or half the horizon) still measures the horizon; later
                               # (an outage, a restart) it would be another horizon's outcome -> unknown
OUTCOME_MAX = 1 + OUTCOME_CAP_PCT / 100   # 1000x the price seen is a bad quote (a pool at a made-up
                                          # price), not an outcome: it would swamp every average -> unknown
PATH_MINUTES = 60              # a pool candidate's price is followed this long after its verdict ...
PATH_MIN_LIQ = 5000.0          # ... if its pool holds at least this much (smaller ones nobody could trade)
PATH_MAX = 240                 # at most this many at once (8 requests a poll, a second or two)
PATH_STAKE_USD = 33.0          # paths and outcomes are what a stake this size gets out of the pool
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
        # candidate id -> chain, pair, token, until, last price and when a price was last seen
        self._paths: dict[int, dict[str, Any]] = {}
        self._paths_restored = False

    def record(self, candidate: dict[str, Any]) -> int:
        cid = self.store.add_candidate(candidate)
        self.store.schedule_outcomes(cid, candidate["seen_at"], self.horizons)
        self._follow_path(cid, candidate)
        return cid

    def _follow_path(self, cid: int, c: dict[str, Any]) -> None:
        """A pool token's first verdict starts its price path (see the paths table)."""
        snap = c.get("snapshot") or {}
        pool = not snap.get("curve") and snap.get("liquidity_kind", "reported") == "reported"
        if (self.prices_of is None or not pool or len(self._paths) >= PATH_MAX
                or float(snap.get("liquidity_usd") or 0) < PATH_MIN_LIQ or not (c.get("price_usd") or 0) > 0
                or any(p["token"] == c["token"] and p["chain"] == c["chain"] for p in self._paths.values())):
            return
        self._paths[cid] = {"chain": c["chain"], "pair": c["pair"], "token": c["token"],
                            "until": c["seen_at"] + PATH_MINUTES * 60, "last": None, "seen": c["seen_at"]}

    def sample_paths(self, now: float) -> int:
        """One price per followed candidate, stored when it changed (DexScreener moves a
        pair about every 30 s). A pair that stops being priced while the request is
        answered is gone: a last point at 0 ends its path, as the outcomes count it."""
        if not self._paths_restored:                       # after a restart: the paths still running
            self._paths_restored = True
            for r in self.store.paths_since(now - PATH_MINUTES * 60):
                self._paths.setdefault(r["id"], {"chain": r["chain"], "pair": r["pair"], "token": r["token"],
                                                 "until": r["seen_at"] + PATH_MINUTES * 60, "last": None, "seen": now})
        for cid in [k for k, p in self._paths.items() if now > p["until"]]:
            del self._paths[cid]
        if not self._paths:
            return 0
        rows = [{"chain": p["chain"], "pair": p["pair"], "token": p["token"]} for p in self._paths.values()]
        prices, answered = self._lookup(rows)
        points: list[tuple[int, float, float]] = []
        for cid, p in list(self._paths.items()):
            price = prices.get((p["chain"], p["pair"]))
            if price:
                p["seen"] = now
                if price != p["last"]:
                    p["last"] = price
                    points.append((cid, now, price))
            elif (p["chain"], p["pair"]) in answered and now - p["seen"] >= VANISHED_GRACE_S:
                points.append((cid, now, 0.0))
                del self._paths[cid]
        self.store.add_path_points(points)
        return len(points)

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
        depth_of = getattr(getattr(self.prices_of, "__self__", None), "depth", None)
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
                        # what a typical stake would get out: an emptied pool's dust "price" is not a gain
                        prices[(chain, pair)] = payout_price(price, (depth_of or {}).get(pair), PATH_STAKE_USD)
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
        self.sample_paths(now)
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
