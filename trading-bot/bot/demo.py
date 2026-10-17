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
CYCLE_MIN = 60.0    # every token is re-listed as a "new launch" this often (simulated minutes)


def _path(scenario: str, minutes: float) -> float:
    """Price multiplier vs. listing price after `minutes` on the market."""
    if scenario == "runner":
        return 1 + 2.0 * (1 - math.exp(-minutes / 8)) - (0.9 if minutes > 25 else 0)
    if scenario == "dump":
        return 1 + 0.8 * min(1, minutes / 5) - (1.3 * (minutes - 5) / 10 if minutes > 5 else 0)
    if scenario == "rug":
        return 1 + 0.5 * min(1, minutes / 6) if minutes < 8 else 0.05
    return 1.0


def strip_generation(address: str) -> str:
    return address.split("-g", 1)[0]


class FakeDex:
    """Each fixture token is re-listed every CYCLE_MIN simulated minutes with a
    generation suffix on its addresses, so the demo keeps producing fresh
    launches instead of going quiet once everything has aged out."""

    def __init__(self, accel: float = 60.0, seed: int = 7) -> None:
        self.accel = accel
        self.started = time.time()
        self.rng = random.Random(seed)
        raw = json.loads((FIXTURES / "pairs.json").read_text())
        self.pairs: list[dict[str, Any]] = []
        for p in raw:
            demo = p.pop("_demo")
            p["_listed_at"] = self.started + demo["listed_offset_min"] * 60
            p["_scenario"] = demo["scenario"]
            p["_listed_price"] = float(p["priceUsd"])
            self.pairs.append(p)

    def now(self) -> float:
        return self.started + (time.time() - self.started) * self.accel

    def _generations(self, now: Optional[float] = None) -> list[dict[str, Any]]:
        """Current incarnation of every token: the latest listing at or before now."""
        now = self.now() if now is None else now
        out = []
        for p in self.pairs:
            k = int(max(0.0, now - p["_listed_at"]) // (CYCLE_MIN * 60))
            listed = p["_listed_at"] + k * CYCLE_MIN * 60
            if listed > now:
                continue
            q = dict(p)
            q["baseToken"] = dict(p["baseToken"])
            if k:
                q["pairAddress"] = p["pairAddress"] + f"-g{k}"
                q["baseToken"]["address"] = p["baseToken"]["address"] + f"-g{k}"
            q["pairCreatedAt"] = int(listed * 1000)
            out.append(q)
        return out

    def _priced(self, p: dict[str, Any], now: float) -> dict[str, Any]:
        minutes = (now - p["pairCreatedAt"] / 1000) / 60
        noise = 1 + self.rng.uniform(-0.03, 0.03)
        price = p["_listed_price"] * _path(p["_scenario"], max(0.0, minutes)) * noise
        q = dict(p)
        q["priceUsd"] = str(max(1e-9, price))
        return normalize_pair(q, now)

    def recent_token_addresses(self, chains: Any) -> dict[str, list[str]]:
        out = {c: [] for c in chains}
        for p in self._generations():
            if p["chainId"] in out:
                out[p["chainId"]].append(p["baseToken"]["address"])
        return out

    def pairs_for_tokens(self, chain: str, addresses: list[str]) -> list[dict[str, Any]]:
        now = self.now()
        return [self._priced(p, now) for p in self._generations(now)
                if p["chainId"] == chain and p["baseToken"]["address"] in addresses]

    def pair(self, chain: str, pair_address: str) -> Optional[dict[str, Any]]:
        """Any generation can be looked up, so positions and outcome tracking of
        an older listing keep getting prices after the next re-listing."""
        now = self.now()
        base, _, gen = pair_address.partition("-g")
        for p in self.pairs:
            if p["chainId"] != chain or p["pairAddress"] != base:
                continue
            k = int(gen) if gen else 0
            q = dict(p)
            q["baseToken"] = dict(p["baseToken"])
            if k:
                q["pairAddress"] = pair_address
                q["baseToken"]["address"] = p["baseToken"]["address"] + f"-g{k}"
            q["pairCreatedAt"] = int((p["_listed_at"] + k * CYCLE_MIN * 60) * 1000)
            return self._priced(q, now)
        return None

    def price(self, chain: str, pair_address: str) -> Optional[float]:
        p = self.pair(chain, pair_address)
        return p["price_usd"] if p else None


class FakeRug:
    def __init__(self) -> None:
        self.data = json.loads((FIXTURES / "rugcheck.json").read_text())
        self.calls = 0

    def health(self) -> dict[str, Any]:
        return {"calls": self.calls, "fails": 0, "last_error": "", "ok": True if self.calls else None}

    def summary(self, mint: str) -> Optional[dict[str, Any]]:
        self.calls += 1
        d = self.data.get(strip_generation(mint))
        if d is None:
            return None
        risks = d.get("risks") or []
        return {"score": float(d.get("score_normalised", 0)),
                "danger": [r["name"] for r in risks if r.get("level") == "danger"],
                "warn": [r["name"] for r in risks if r.get("level") == "warn"]}


def _newest(dex: FakeDex, now: float, chain: str, limit: int) -> list[dict[str, Any]]:
    """The `limit` most recently listed demo pairs on a chain, newest first –
    like the real feeds, which always return their latest page, whatever its age."""
    pairs = [p for p in dex._generations(now) if p["chainId"] == chain]
    pairs.sort(key=lambda p: p["pairCreatedAt"], reverse=True)
    return pairs[:limit]


class FakeGecko:
    """Demo stand-in for GeckoTerminal "new pools": the newest listings with
    their own snapshot, never empty while the demo market has tokens."""

    label = "GeckoTerminal – neue Pools (Demo)"
    PAGE = 20

    def __init__(self, dex: FakeDex) -> None:
        self.dex = dex

    def discover(self, chains: list[str]) -> dict[str, list[dict[str, Any]]]:
        now = self.dex.now()
        out: dict[str, list[dict[str, Any]]] = {c: [] for c in chains}
        for chain in out:
            for p in _newest(self.dex, now, chain, self.PAGE):
                snap = self.dex._priced(p, now)
                out[chain].append({"token": snap["token"], "snapshot": snap})
        return out


class FakePump:
    """Demo stand-in for pump.fun: the newest coins, mint and age only (no
    market numbers), like the real feed."""

    label = "pump.fun – neue Coins (Demo)"
    PAGE = 4

    def __init__(self, dex: FakeDex) -> None:
        self.dex = dex

    def discover(self, chains: list[str]) -> dict[str, list[dict[str, Any]]]:
        now = self.dex.now()
        out: dict[str, list[dict[str, Any]]] = {c: [] for c in chains}
        if "solana" not in out:
            return out
        from .sources.pumpfun import normalize_coin
        for p in _newest(self.dex, now, "solana", self.PAGE):
            coin = {"mint": p["baseToken"]["address"], "symbol": p["baseToken"]["symbol"], "name": p["baseToken"]["name"],
                    "created_timestamp": p["pairCreatedAt"], "usd_market_cap": p.get("fdv", 0)}
            out["solana"].append({"token": coin["mint"], "snapshot": normalize_coin(coin, now)})
        return out


def demo_feeds(dex: FakeDex) -> dict[str, Any]:
    from .discovery import DexScreenerFeed
    return {"dexscreener": DexScreenerFeed(dex), "geckoterminal": FakeGecko(dex), "pumpfun": FakePump(dex)}


def fast_clock(dex: FakeDex) -> Callable[[], float]:
    return dex.now
