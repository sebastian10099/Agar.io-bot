"""GeckoTerminal public API (no key, 30 calls/min). Its "new pools" feed lists
pools in the order they were created, so a launch shows up here a few minutes
before DexScreener promotes it as a profile or boost. The pair is normalised
into the same shape DexScreener delivers, so the strategy does not care where
a candidate came from."""
from __future__ import annotations

import time
from datetime import datetime, timezone
from typing import Any, Optional

from . import curve
from .http import get_json

BASE = "https://api.geckoterminal.com/api/v2"
NETWORKS = {"solana": "solana", "ethereum": "eth", "base": "base", "bsc": "bsc"}
HEADERS = {"Accept": "application/json;version=20230302"}


def _f(x: Any, default: float = 0.0) -> float:
    try:
        return float(x)
    except (TypeError, ValueError):
        return default


def _iso(s: Any) -> Optional[float]:
    if not isinstance(s, str) or not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()
    except ValueError:
        return None


def normalize_pool(pool: dict[str, Any], chain: str, tokens: dict[str, dict[str, Any]],
                   now: Optional[float] = None) -> Optional[dict[str, Any]]:
    """One GeckoTerminal pool object -> the flat pair dict the strategy uses."""
    now = now or time.time()
    a = pool.get("attributes") or {}
    rel = pool.get("relationships") or {}
    base_id = ((rel.get("base_token") or {}).get("data") or {}).get("id") or ""
    token = base_id.split("_", 1)[1] if "_" in base_id else base_id
    pair = a.get("address")
    if not token or not pair:
        return None
    info = tokens.get(base_id) or {}
    name = a.get("name") or ""
    symbol = info.get("symbol") or name.split(" / ")[0].strip() or None
    vol = a.get("volume_usd") or {}
    tx = a.get("transactions") or {}
    m5, h1 = tx.get("m5") or {}, tx.get("h1") or {}
    chg = a.get("price_change_percentage") or {}
    created = _iso(a.get("pool_created_at"))
    net = NETWORKS.get(chain, chain)
    dex = ((rel.get("dex") or {}).get("data") or {}).get("id")
    liquidity, kind = _f(a.get("reserve_in_usd")), "reported" if a.get("reserve_in_usd") is not None else "unknown"
    if curve.is_curve(dex):
        # a curve's "reserve" is the unsold token side (close to the FDV), not pool liquidity;
        # pump.fun's real figure is read from the chain later
        liquidity, kind = 0.0, "unknown"
    return {
        "chain": chain,
        "dex": dex,
        "pair": pair,
        "token": token,
        "symbol": symbol,
        "name": info.get("name") or name,
        "url": f"https://www.geckoterminal.com/{net}/pools/{pair}",
        "price_usd": _f(a.get("base_token_price_usd")),
        "liquidity_usd": liquidity,
        "liquidity_kind": kind,
        "curve": curve.is_curve(dex),
        "fdv": _f(a.get("fdv_usd")),
        "market_cap": _f(a.get("market_cap_usd")),
        "volume_m5": _f(vol.get("m5")),
        "volume_h1": _f(vol.get("h1")),
        "buys_m5": int(_f(m5.get("buys"))),
        "sells_m5": int(_f(m5.get("sells"))),
        "buys_h1": int(_f(h1.get("buys"))),
        "sells_h1": int(_f(h1.get("sells"))),
        "change_m5": _f(chg.get("m5")),
        "change_h1": _f(chg.get("h1")),
        "age_min": (now - created) / 60.0 if created else None,
        "boosts": 0,
        "has_socials": False,
    }


class GeckoTerminal:
    """Discovery feed. `discover(chains)` -> {chain: [{"token", "snapshot"}]}.

    The free tier allows 30 calls a minute; `min_interval` caps calls per
    chain and the last answer is replayed in between, so a 2-second poll
    interval with four chains stays well inside the limit."""

    label = "GeckoTerminal – neue Pools"

    def __init__(self, fetch=get_json, min_interval: float = 15.0, clock=time.time) -> None:
        self.fetch = fetch
        self.min_interval = min_interval
        self.clock = clock
        self._last: dict[str, tuple[float, list[dict[str, Any]]]] = {}
        self.calls = 0

    def new_pools(self, chain: str) -> list[dict[str, Any]]:
        net = NETWORKS.get(chain)
        if net is None:
            return []
        cached = self._last.get(chain)
        now = self.clock()
        if cached and now - cached[0] < self.min_interval:
            return cached[1]
        self.calls += 1
        data = self.fetch(f"{BASE}/networks/{net}/new_pools?include=base_token&page=1", headers=HEADERS)
        tokens = {t.get("id"): (t.get("attributes") or {})
                  for t in (data or {}).get("included") or [] if t.get("type") == "token"}
        out = []
        for pool in (data or {}).get("data") or []:
            n = normalize_pool(pool, chain, tokens, now)
            if n:
                out.append(n)
        self._last[chain] = (now, out)
        return out

    def discover(self, chains: list[str]) -> dict[str, list[dict[str, Any]]]:
        out: dict[str, list[dict[str, Any]]] = {}
        errors: list[str] = []
        for chain in chains:
            try:
                out[chain] = [{"token": p["token"], "snapshot": p} for p in self.new_pools(chain)]
            except Exception as error:  # noqa: BLE001 - one chain failing must not hide the others
                errors.append(f"{chain}: {type(error).__name__}: {str(error)[:120]}")
                out[chain] = []
        if errors and not any(out.values()):
            raise RuntimeError("; ".join(errors))
        return out
