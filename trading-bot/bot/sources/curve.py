"""Bonding curves: a launchpad's price curve that a new token trades against
before it gets a real pool. DexScreener reports no liquidity for them and
GeckoTerminal a token-side reserve close to the FDV, so without this module
the liquidity filter rejects every one of them, however busy.

For pump.fun the pair address DexScreener lists is the curve's own account
on the chain, and that account holds the curve's reserves. One public RPC
call (getMultipleAccounts) reads them for all curves of a poll. A curve is a
constant product of its virtual reserves, so it fills orders like a pool
holding as much quote as its virtual tokens are worth at the current price:
the liquidity of the pool with the same price impact is
2 x virtual tokens x price. This holds for every pump.fun curve, whatever
its quote token (SOL, USDC, PUMP, ...) and its starting reserves - on live
coins those differ a lot, so the price alone cannot tell the reserves.

Other launchpads (Meteora DBC, LaunchLab) keep their liquidity 'unknown'.

The same reader prices PumpSwap pools - where a pump.fun coin trades once
its curve completes - straight from the chain: the pool's two vaults hold its
reserves, so their ratio is the price this second. DexScreener refreshes a
pair only about every 30 seconds; a stop loss on its figure fires up to half a
minute late, and a buy is booked at a price the market has left."""
from __future__ import annotations

import base64
import struct
import time
from typing import Any, Callable, Optional

from .http import post_json
from .solana_rpc import PAUSE_S, PUMP_PROGRAM, TIMEOUT_S, TRIP_AFTER, b58encode, post_rotating, rpc_url, rpc_urls

PUMPSWAP_PROGRAM = "pAMMBay6oceH9fJKBRHGP5D4bD4sWpmSwMn52FMfXEA"
WSOL = "So11111111111111111111111111111111111111112"
STABLES = {"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",      # USDC
           "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"}      # USDT
POOL_CACHE = 2000             # pool layouts remembered (they never change)
PUMP_DEXES = {"pumpfun", "pump-fun"}
CURVE_DEXES = PUMP_DEXES | {"meteoradbc", "meteora-dbc", "launchlab", "raydium-launchlab"}
TOKEN_DECIMALS = 6            # every pump.fun token
BATCH = 100                   # getMultipleAccounts limit


def is_curve(dex: Any) -> bool:
    return str(dex or "").lower() in CURVE_DEXES


def parse_pump_curve(data: bytes) -> Optional[dict[str, Any]]:
    """pump.fun BondingCurve account: 8-byte discriminator, then u64 virtual
    token reserves, virtual quote reserves, real token reserves, real quote
    reserves, token total supply, and the 'complete' flag."""
    if len(data) < 49:
        return None
    v_tok, v_quote, r_tok, r_quote, supply = struct.unpack_from("<5Q", data, 8)
    if v_tok <= 0:
        return None
    scale = 10 ** TOKEN_DECIMALS
    return {"virtual_tokens": v_tok / scale, "real_tokens": r_tok / scale, "supply": supply / scale,
            "virtual_quote_raw": v_quote, "real_quote_raw": r_quote, "complete": data[48] == 1}


def parse_pumpswap_pool(data: bytes) -> Optional[dict[str, str]]:
    """PumpSwap Pool account: 8-byte discriminator, u8 bump, u16 index, then
    the creator, base mint, quote mint, LP mint, base vault and quote vault."""
    if len(data) < 203:
        return None
    keys = [b58encode(data[o:o + 32]) for o in range(11, 203, 32)]
    return {"base_mint": keys[1], "quote_mint": keys[2], "base_vault": keys[4], "quote_vault": keys[5]}


def token_amount(data: bytes) -> Optional[int]:
    """SPL token account (either token program): mint, owner, then the u64 amount."""
    return struct.unpack_from("<Q", data, 64)[0] if len(data) >= 72 else None


def mint_decimals(data: bytes) -> Optional[int]:
    """SPL mint (either token program): authority option, u64 supply, then the decimals."""
    return data[44] if len(data) >= 46 and data[45] == 1 else None      # 45: is_initialized


def pool_liquidity(virtual_tokens: float, price_usd: float) -> float:
    return 2.0 * virtual_tokens * price_usd


class CurveReader:
    """Reads pump.fun curve accounts in batches and fills in their liquidity."""

    label = "pump.fun-Kurven (Solana-RPC)"

    def __init__(self, post: Callable[..., Any] = post_json, url: Optional[str] = None,
                 clock: Callable[[], float] = time.time) -> None:
        self.post = post
        self.url = url or rpc_url()
        self.urls = rpc_urls() if url is None else [url]        # tried in turn when one throttles
        self.clock = clock
        self.calls = 0
        self.fails = 0
        self.last_error = ""
        self._streak = 0
        self._paused_until = 0.0
        self._pools: dict[str, Optional[dict[str, Any]]] = {}   # pair -> PumpSwap layout, None: not one

    def health(self) -> dict[str, Any]:
        return {"calls": self.calls, "fails": self.fails, "last_error": self.last_error,
                "ok": None if not self.calls else (self.last_error == "")}

    def _accounts(self, accounts: list[str]) -> dict[str, Optional[tuple[str, bytes]]]:
        """{account: (owner, data)}, None for an account that does not exist. An RPC
        failure leaves its batch out: unknown stays unknown."""
        out: dict[str, Optional[tuple[str, bytes]]] = {}
        accounts = list(dict.fromkeys(a for a in accounts if a))
        for i in range(0, len(accounts), BATCH):
            if self.clock() < self._paused_until:
                break
            chunk = accounts[i:i + BATCH]
            self.calls += 1
            body = {"jsonrpc": "2.0", "id": 1, "method": "getMultipleAccounts",
                    "params": [chunk, {"encoding": "base64", "commitment": "confirmed"}]}
            try:
                answer = post_rotating(self.post, self.urls, body, TIMEOUT_S)
                values = (answer.get("result") or {}).get("value")
                if not isinstance(values, list) or len(values) != len(chunk):
                    raise RuntimeError("Antwort passt nicht zur Anfrage")
            except Exception as error:  # noqa: BLE001
                self.fails += 1
                self._streak += 1
                self.last_error = f"{type(error).__name__}: {str(error)[:120]}"
                if self._streak >= TRIP_AFTER:
                    self._paused_until = self.clock() + PAUSE_S
                    self.last_error += f" – Pause {PAUSE_S:.0f} s nach {self._streak} Fehlern"
                    self._streak = 0
                continue
            self.last_error = ""
            self._streak = 0
            for account, value in zip(chunk, values):
                try:
                    out[account] = (str(value.get("owner")), base64.b64decode((value.get("data") or [""])[0])) \
                        if isinstance(value, dict) else None
                except (TypeError, ValueError, IndexError):
                    out[account] = None
        return out

    def read(self, accounts: list[str]) -> dict[str, dict[str, Any]]:
        """{account: curve state} for the accounts that are pump.fun curves."""
        out: dict[str, dict[str, Any]] = {}
        for account, found in self._accounts(accounts).items():
            state = parse_pump_curve(found[1]) if found and found[0] == PUMP_PROGRAM else None
            if state is not None:
                out[account] = state
        return out

    def pool_prices(self, pairs: dict[str, str], quote_usd: dict[str, float]) -> dict[str, float]:
        """{pair: USD price this second} for the pairs ({pair: token}) that are
        PumpSwap pools of that token against SOL or a dollar coin. The pool's
        layout is read once; after that one call reads every pool's vaults."""
        new = [p for p in pairs if p not in self._pools]
        if new:
            found = self._accounts(new)
            mints: dict[str, dict[str, str]] = {}
            for pair in new:
                if pair not in found:
                    continue                                     # the call failed: ask again next time
                account = found[pair]
                pool = parse_pumpswap_pool(account[1]) if account and account[0] == PUMPSWAP_PROGRAM else None
                if pool is None or pool["base_mint"] != pairs[pair] or not (pool["quote_mint"] == WSOL or pool["quote_mint"] in STABLES):
                    self._remember(pair, None)                   # no PumpSwap pool of this token: DexScreener prices it
                else:
                    mints[pair] = pool
            if mints:
                got = self._accounts(sorted({m for pool in mints.values() for m in (pool["base_mint"], pool["quote_mint"])}))
                for pair, pool in mints.items():
                    base, quote = got.get(pool["base_mint"]), got.get(pool["quote_mint"])
                    dec = (mint_decimals(base[1]) if base else None, mint_decimals(quote[1]) if quote else None)
                    if None not in dec:
                        self._remember(pair, dict(pool, base_decimals=dec[0], quote_decimals=dec[1]))
        known = {p: self._pools[p] for p in pairs if self._pools.get(p)}
        if not known:
            return {}
        vaults = self._accounts([v for pool in known.values() for v in (pool["base_vault"], pool["quote_vault"])])
        out: dict[str, float] = {}
        for pair, pool in known.items():
            base, quote = vaults.get(pool["base_vault"]), vaults.get(pool["quote_vault"])
            b = token_amount(base[1]) if base else None
            q = token_amount(quote[1]) if quote else None
            usd = 1.0 if pool["quote_mint"] in STABLES else quote_usd.get(pool["quote_mint"])
            if b and q and usd and usd > 0:
                out[pair] = (q / 10 ** pool["quote_decimals"]) / (b / 10 ** pool["base_decimals"]) * usd
        return out

    def _remember(self, pair: str, pool: Optional[dict[str, Any]]) -> None:
        if len(self._pools) >= POOL_CACHE:
            self._pools.pop(next(iter(self._pools)))
        self._pools[pair] = pool

    def enrich(self, pairs: list[dict[str, Any]]) -> int:
        """Fill liquidity_usd of pump.fun curve pairs in place; returns how many got a figure."""
        todo = [p for p in pairs if p.get("dex") in PUMP_DEXES and p.get("liquidity_kind") != "reported"
                and p.get("pair") and p.get("price_usd", 0) > 0]
        if not todo:
            return 0
        states = self.read([p["pair"] for p in todo])
        done = 0
        for p in todo:
            st = states.get(p["pair"])
            if st is None:
                continue
            if st["complete"]:
                p.update(liquidity_usd=0.0, liquidity_kind="graduated")
            else:
                p.update(liquidity_usd=pool_liquidity(st["virtual_tokens"], p["price_usd"]), liquidity_kind="curve")
            done += 1
        return done
