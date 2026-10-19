"""DexScreener public API (no key). Discovery of recently promoted tokens and
pair snapshots with liquidity, volume, transactions and age."""
from __future__ import annotations

import time
from typing import Any, Iterable, Optional

from . import curve
from .http import get_json

BASE = "https://api.dexscreener.com"
# where a bonding curve's token trades once the curve completes; any other pool next to a
# running curve (someone's own pool, often at a very different price) never prices it.
# Only pump.fun's is unmistakable - PumpSwap is pump.fun's own exchange. Meteora DBC and
# LaunchLab graduate into ordinary Meteora/Raydium pools, which anyone can open too: their
# curves keep their own price while listed and follow the token only once the pair is gone.
CURVE_SUCCESSORS = {"pumpfun": {"pumpswap"}, "pump-fun": {"pumpswap"}}
SUCCESSOR_MIN_LIQ = 1000.0    # a real pool this deep outranks a bonding curve: the curve has completed and moved there


def _f(x: Any, default: float = 0.0) -> float:
    try:
        return float(x)
    except (TypeError, ValueError):
        return default


def canon(address: Any) -> Any:
    """One spelling per token: EVM addresses (0x...) are case-insensitive - DexScreener writes
    them checksummed, GeckoTerminal in lower case - Solana's base58 addresses are not."""
    return address.lower() if isinstance(address, str) and address.startswith("0x") else address


def safe_url(value: Any) -> Optional[str]:
    """Only http(s) links reach the control page; a token can set anything
    in its API record, including javascript: URLs."""
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value if value.lower().startswith(("https://", "http://")) and len(value) <= 500 else None


def normalize_pair(p: dict[str, Any], now: Optional[float] = None) -> dict[str, Any]:
    """Flatten one DexScreener pair object into the fields the strategy uses."""
    now = now or time.time()
    base = p.get("baseToken") or {}
    quote = p.get("quoteToken") or {}
    txns = p.get("txns") or {}
    m5 = txns.get("m5") or {}
    h1 = txns.get("h1") or {}
    vol = p.get("volume") or {}
    chg = p.get("priceChange") or {}
    # bonding curves come without a liquidity figure (pump.fun's is read from the chain later)
    reported = (p.get("liquidity") or {}).get("usd")
    created_ms = p.get("pairCreatedAt")
    age_min = (now - created_ms / 1000.0) / 60.0 if created_ms else None
    return {
        "chain": p.get("chainId"),
        "dex": p.get("dexId"),
        "pair": p.get("pairAddress"),
        "token": canon(base.get("address")),
        "quote_token": canon(quote.get("address")),
        "symbol": base.get("symbol"),
        "name": base.get("name"),
        "url": safe_url(p.get("url")),
        "price_usd": _f(p.get("priceUsd")),
        "price_native": _f(p.get("priceNative")),        # the base token in units of the quote token
        "liquidity_usd": _f(reported),
        "liquidity_kind": "reported" if reported is not None else "unknown",
        "curve": curve.is_curve(p.get("dexId")),
        "fdv": _f(p.get("fdv")),
        "market_cap": _f(p.get("marketCap")),
        "volume_m5": _f(vol.get("m5")),
        "volume_h1": _f(vol.get("h1")),
        "buys_m5": int(_f(m5.get("buys"))),
        "sells_m5": int(_f(m5.get("sells"))),
        "buys_h1": int(_f(h1.get("buys"))),
        "sells_h1": int(_f(h1.get("sells"))),
        "change_m5": _f(chg.get("m5")),
        "change_h1": _f(chg.get("h1")),
        "age_min": age_min,
        "boosts": int(_f((p.get("boosts") or {}).get("active"))),
        "has_socials": bool(((p.get("info") or {}).get("socials")) or
                            ((p.get("info") or {}).get("websites"))),
    }


def token_price(n: dict[str, Any], token: Optional[str]) -> Optional[float]:
    """USD price of `token` in this pair. DexScreener's priceUsd is the BASE token's;
    a pool can list our token as the quote side (and DexScreener may flip a pool's
    sides between two calls) - then the price is priceUsd / priceNative. A pair the
    token is not part of gives no price rather than another token's."""
    token = canon(token)
    if not token or canon(n.get("token")) == token:
        return n["price_usd"] if n["price_usd"] > 0 else None
    if canon(n.get("quote_token")) == token and n["price_usd"] > 0 and n.get("price_native", 0) > 0:
        return n["price_usd"] / n["price_native"]
    return None


def _rank(n: dict[str, Any]) -> tuple[int, float]:
    """Which pair speaks for a token: a real pool with reported liquidity first
    (after a pump.fun curve completes, its PumpSwap pool), then the curve, then
    whatever dust pool someone opened next to a running curve."""
    real = not n.get("curve") and n.get("liquidity_kind", "reported") == "reported" and n["liquidity_usd"] >= SUCCESSOR_MIN_LIQ
    return (2 if real else 1 if n.get("curve") else 0, n["liquidity_usd"])


class DexScreener:
    def __init__(self, fetch=get_json) -> None:
        self.fetch = fetch

    def recent_token_addresses(self, chains: Iterable[str]) -> dict[str, list[str]]:
        """Recently promoted tokens (profiles + boosts). New launches show up here
        within minutes; it is the cheapest keyless discovery feed there is."""
        wanted = set(chains)
        out: dict[str, list[str]] = {c: [] for c in wanted}
        errors = []
        for path in ("/token-profiles/latest/v1", "/token-boosts/latest/v1"):
            try:
                items = self.fetch(BASE + path)
            except Exception as error:  # noqa: BLE001 - one feed failing must not stop the other
                errors.append(error)
                continue
            for item in items if isinstance(items, list) else []:
                chain = item.get("chainId")
                addr = canon(item.get("tokenAddress"))
                if chain in wanted and addr and addr not in out[chain]:
                    out[chain].append(addr)
        if len(errors) == 2:                       # both lists failed: an outage, not "nothing new"
            raise errors[0]
        return out

    def _token_pairs(self, chain: str, addresses: list[str]) -> list[dict[str, Any]]:
        """Every pair of these tokens, 30 tokens per request."""
        out: list[dict[str, Any]] = []
        for i in range(0, len(addresses), 30):
            chunk = addresses[i:i + 30]
            try:
                pairs = self.fetch(f"{BASE}/tokens/v1/{chain}/{','.join(chunk)}")
            except Exception:  # noqa: BLE001
                continue
            for p in pairs if isinstance(pairs, list) else []:
                n = normalize_pair(p)
                if n["token"] and n["pair"]:
                    out.append(n)
        return out

    def pairs_for_tokens(self, chain: str, addresses: list[str]) -> list[dict[str, Any]]:
        """Best pair per token (see _rank). Max 30 addresses per call."""
        best: dict[str, dict[str, Any]] = {}
        wanted = {canon(a) for a in addresses}
        for n in self._token_pairs(chain, addresses):
            if n["token"] not in wanted:
                continue                                 # a pool listing the token as its quote side: its numbers are the other token's
            cur = best.get(n["token"])
            if cur is None or _rank(n) > _rank(cur):
                best[n["token"]] = n
        return list(best.values())

    def pair(self, chain: str, pair_address: str) -> Optional[dict[str, Any]]:
        try:
            data = self.fetch(f"{BASE}/latest/dex/pairs/{chain}/{pair_address}")
        except Exception:  # noqa: BLE001
            return None
        pairs = (data or {}).get("pairs") or []
        return normalize_pair(pairs[0]) if pairs else None

    def prices(self, chain: str, pair_addresses: list[str],
               follow: Optional[dict[str, str]] = None) -> dict[str, float]:
        """Current price for up to 30 pairs in one request: {pair address: price}.
        Pairs missing from the answer are simply absent (pulled or unknown).

        `follow` ({pair: token}) keeps a holding priced when its pair stops
        being the market: a pair that is gone is priced from the token's best
        remaining pool, and a bonding curve whose token now trades in a real
        pool (pump.fun -> PumpSwap after the curve completes; the curve's own
        price freezes there) is priced from that pool."""
        out: dict[str, float] = {}
        curves: dict[str, str] = {}              # curve pair -> its dex
        for i in range(0, len(pair_addresses), 30):
            chunk = pair_addresses[i:i + 30]
            data = self.fetch(f"{BASE}/latest/dex/pairs/{chain}/{','.join(chunk)}")
            for raw in (data or {}).get("pairs") or []:
                n = normalize_pair(raw)
                if not n["pair"]:
                    continue
                price = token_price(n, (follow or {}).get(n["pair"]))
                if price:
                    out[n["pair"]] = price
                if n["curve"]:
                    curves[n["pair"]] = str(n.get("dex") or "").lower()
        ask: dict[str, list[str]] = {}
        for pair in pair_addresses:
            token = (follow or {}).get(pair)
            if token and (pair not in out or pair in curves):
                ask.setdefault(token, []).append(pair)
        if ask:
            markets: dict[str, list[tuple[dict[str, Any], float]]] = {}   # token -> (pair, its price there)
            ask = {canon(t): pairs for t, pairs in ask.items()}
            for n in self._token_pairs(chain, list(ask)):
                for side in {n["token"], n.get("quote_token")} & set(ask):
                    price = token_price(n, side)
                    if price:
                        markets.setdefault(side, []).append((n, price))
            for token, pairs in ask.items():
                for pair in pairs:
                    others = [(n, pr) for n, pr in markets.get(token, []) if n["pair"] != pair]
                    if pair not in out:                  # gone: the token's best remaining market - never a dust pool
                        pick = [(n, pr) for n, pr in others if _rank(n)[0] >= 1]
                    else:                                # a listed curve: only the pool it graduates into
                        pick = [(n, pr) for n, pr in others if _rank(n)[0] == 2
                                and str(n.get("dex") or "").lower() in CURVE_SUCCESSORS.get(curves[pair], ())]
                    if pick:
                        out[pair] = max(pick, key=lambda x: _rank(x[0]))[1]
        return out

    def price(self, chain: str, pair_address: str, token: Optional[str] = None) -> Optional[float]:
        p = self.pair(chain, pair_address)
        return token_price(p, token) if p else None
