"""Offline demo market. Same interface as the real sources, prices follow
scripted scenarios, and the clock runs 60x so a 45-minute trade takes 45s."""
from __future__ import annotations

import json
import math
import random
import time
from pathlib import Path
from typing import Any, Callable, Optional

from .sources.dexscreener import normalize_pair

FIXTURES = Path(__file__).parent.parent / "tests" / "fixtures"


def _path(scenario: str, minutes: float) -> float:
    """Price multiplier vs. listing price after `minutes` on the market."""
    if scenario == "runner":
        return 1 + 2.0 * (1 - math.exp(-minutes / 8)) - (0.9 if minutes > 25 else 0)
    if scenario == "dump":
        return 1 + 0.8 * min(1, minutes / 5) - (1.3 * (minutes - 5) / 10 if minutes > 5 else 0)
    if scenario == "rug":
        return 1 + 0.5 * min(1, minutes / 6) if minutes < 8 else 0.05
    return 1.0


class FakeDex:
    def __init__(self, accel: float = 60.0, seed: int = 7) -> None:
        self.accel = accel
        self.started = time.time()
        self.rng = random.Random(seed)
        raw = json.loads((FIXTURES / "pairs.json").read_text())
        self.pairs: list[dict[str, Any]] = []
        for p in raw:
            demo = p.pop("_demo")
            p["pairCreatedAt"] = int((self.started + demo["listed_offset_min"] * 60) * 1000)
            p["_scenario"] = demo["scenario"]
            p["_listed_price"] = float(p["priceUsd"])
            self.pairs.append(p)

    def now(self) -> float:
        return self.started + (time.time() - self.started) * self.accel

    def _priced(self, p: dict[str, Any]) -> dict[str, Any]:
        now = self.now()
        minutes = (now - p["pairCreatedAt"] / 1000) / 60
        noise = 1 + self.rng.uniform(-0.03, 0.03)
        price = p["_listed_price"] * _path(p["_scenario"], max(0.0, minutes)) * noise
        q = dict(p)
        q["priceUsd"] = str(max(1e-9, price))
        return normalize_pair(q, now)

    def recent_token_addresses(self, chains: Any) -> dict[str, list[str]]:
        now = self.now()
        out = {c: [] for c in chains}
        for p in self.pairs:
            if p["chainId"] in out and p["pairCreatedAt"] / 1000 <= now:
                out[p["chainId"]].append(p["baseToken"]["address"])
        return out

    def pairs_for_tokens(self, chain: str, addresses: list[str]) -> list[dict[str, Any]]:
        return [self._priced(p) for p in self.pairs
                if p["chainId"] == chain and p["baseToken"]["address"] in addresses]

    def pair(self, chain: str, pair_address: str) -> Optional[dict[str, Any]]:
        for p in self.pairs:
            if p["chainId"] == chain and p["pairAddress"] == pair_address:
                return self._priced(p)
        return None

    def price(self, chain: str, pair_address: str) -> Optional[float]:
        p = self.pair(chain, pair_address)
        return p["price_usd"] if p else None


class FakeRug:
    def __init__(self) -> None:
        self.data = json.loads((FIXTURES / "rugcheck.json").read_text())

    def summary(self, mint: str) -> Optional[dict[str, Any]]:
        d = self.data.get(mint)
        if d is None:
            return None
        risks = d.get("risks") or []
        return {"score": float(d.get("score_normalised", 0)),
                "danger": [r["name"] for r in risks if r.get("level") == "danger"],
                "warn": [r["name"] for r in risks if r.get("level") == "warn"]}


def fast_clock(dex: FakeDex) -> Callable[[], float]:
    return dex.now
