"""pump.fun launch feed (no key). Most new Solana memecoins start here, and the
frontend API lists them seconds after creation – minutes before any
aggregator. The feed only contributes the mint and the creation time; the
numbers (liquidity, volume, buys) still come from DexScreener, which indexes
pump.fun bonding curves as dex "pumpfun".

The API is unofficial: its host and shape have changed before. Everything
here is defensive – an unexpected answer yields nothing and the source row
on the control page turns red with the reason, nothing else breaks."""
from __future__ import annotations

import time
from typing import Any, Optional

from .http import get_json

URL = "https://frontend-api-v3.pump.fun/coins?offset=0&limit=50&sort=created_timestamp&order=DESC&includeNsfw=false"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36",
           "Accept": "application/json, text/plain, */*", "Origin": "https://pump.fun", "Referer": "https://pump.fun/"}


def _f(x: Any, default: float = 0.0) -> float:
    try:
        return float(x)
    except (TypeError, ValueError):
        return default


def normalize_coin(coin: dict[str, Any], now: Optional[float] = None) -> Optional[dict[str, Any]]:
    """One pump.fun coin -> a minimal pair dict (token, symbol, age); no prices."""
    mint = coin.get("mint") or coin.get("address")
    if not mint:
        return None
    now = now or time.time()
    created = _f(coin.get("created_timestamp"))
    if created > 1e12:                       # milliseconds
        created /= 1000.0
    age_min = (now - created) / 60.0 if created > 0 else None
    mcap = _f(coin.get("usd_market_cap"))
    return {
        "chain": "solana", "dex": "pumpfun", "pair": coin.get("raydium_pool") or coin.get("bonding_curve") or mint,
        "token": mint, "symbol": coin.get("symbol"), "name": coin.get("name"),
        "url": f"https://pump.fun/coin/{mint}",
        "price_usd": 0.0, "liquidity_usd": 0.0, "liquidity_kind": "unknown", "fdv": mcap, "market_cap": mcap,
        "volume_m5": 0.0, "volume_h1": 0.0, "buys_m5": 0, "sells_m5": 0, "buys_h1": 0, "sells_h1": 0,
        "change_m5": 0.0, "change_h1": 0.0, "age_min": age_min, "boosts": 0,
        "has_socials": bool(coin.get("twitter") or coin.get("telegram") or coin.get("website")),
        "graduated": bool(coin.get("complete")),
    }


class PumpFun:
    """Discovery feed: `discover(chains)` -> {"solana": [{"token", "snapshot"}]}.
    The snapshot carries no market numbers (price 0), so the engine only uses
    it for the listing age; DexScreener supplies the rest."""

    label = "pump.fun – neue Coins"

    def __init__(self, fetch=get_json, min_interval: float = 10.0, clock=time.time) -> None:
        self.fetch = fetch
        self.min_interval = min_interval
        self.clock = clock
        self._last: Optional[tuple[float, list[dict[str, Any]]]] = None
        self._failed: Optional[tuple[float, Exception]] = None   # when and why the last call failed
        self.calls = 0

    def latest(self) -> list[dict[str, Any]]:
        now = self.clock()
        if self._last and now - self._last[0] < self.min_interval:
            return self._last[1]
        if self._failed and now - self._failed[0] < self.min_interval:
            # a blocked feed is not asked more often than a working one; the same error, so the log stays quiet
            raise self._failed[1].with_traceback(None)
        self.calls += 1
        try:
            return self._fetch_latest(now)
        except Exception as error:
            self._failed = (now, error)
            raise

    def _fetch_latest(self, now: float) -> list[dict[str, Any]]:
        data = self.fetch(URL, headers=HEADERS, retries=0)
        if isinstance(data, list):
            coins = data
        elif isinstance(data, dict) and isinstance(data.get("coins", data.get("data")), list):
            coins = data.get("coins", data.get("data"))
        else:
            # a Cloudflare page, an error object or a renamed field: say so instead of "no coins"
            raise RuntimeError("unerwartete Antwort von pump.fun (kein Listenformat) – blockiert oder Format geändert?")
        out = []
        for coin in coins:
            if not isinstance(coin, dict):
                continue
            n = normalize_coin(coin, now)
            if n:
                out.append(n)
        if coins and not out:
            raise RuntimeError("pump.fun-Antwort ohne mint-Feld – Format geändert?")
        self._last = (now, out)
        self._failed = None
        return out

    def discover(self, chains: list[str]) -> dict[str, list[dict[str, Any]]]:
        if "solana" not in chains:
            return {c: [] for c in chains}
        coins = self.latest()
        out = {c: [] for c in chains}
        out["solana"] = [{"token": c["token"], "snapshot": c} for c in coins]
        return out
