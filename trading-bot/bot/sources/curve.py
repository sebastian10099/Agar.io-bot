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

Other launchpads (Meteora DBC, LaunchLab) keep their liquidity 'unknown'."""
from __future__ import annotations

import base64
import struct
import time
from typing import Any, Callable, Optional

from .http import post_json
from .solana_rpc import PAUSE_S, TIMEOUT_S, TRIP_AFTER, rpc_url

PUMP_PROGRAM = "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P"
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


def pool_liquidity(virtual_tokens: float, price_usd: float) -> float:
    return 2.0 * virtual_tokens * price_usd


class CurveReader:
    """Reads pump.fun curve accounts in batches and fills in their liquidity."""

    label = "pump.fun-Kurven (Solana-RPC)"

    def __init__(self, post: Callable[..., Any] = post_json, url: Optional[str] = None,
                 clock: Callable[[], float] = time.time) -> None:
        self.post = post
        self.url = url or rpc_url()
        self.clock = clock
        self.calls = 0
        self.fails = 0
        self.last_error = ""
        self._streak = 0
        self._paused_until = 0.0

    def health(self) -> dict[str, Any]:
        return {"calls": self.calls, "fails": self.fails, "last_error": self.last_error,
                "ok": None if not self.calls else (self.last_error == "")}

    def read(self, accounts: list[str]) -> dict[str, dict[str, Any]]:
        """{account: curve state} for the accounts that are pump.fun curves.
        An RPC failure leaves the rest out (their liquidity stays unknown)."""
        out: dict[str, dict[str, Any]] = {}
        accounts = list(dict.fromkeys(a for a in accounts if a))
        for i in range(0, len(accounts), BATCH):
            if self.clock() < self._paused_until:
                break
            chunk = accounts[i:i + BATCH]
            self.calls += 1
            body = {"jsonrpc": "2.0", "id": 1, "method": "getMultipleAccounts",
                    "params": [chunk, {"encoding": "base64", "commitment": "confirmed"}]}
            try:
                answer = self.post(self.url, body, timeout=TIMEOUT_S)
                if not isinstance(answer, dict):
                    raise RuntimeError("unerwartete Antwort")
                if answer.get("error"):
                    raise RuntimeError(str((answer["error"] or {}).get("message", answer["error"]))[:120])
                values = (answer.get("result") or {}).get("value")
                if not isinstance(values, list) or len(values) != len(chunk):
                    raise RuntimeError("Antwort passt nicht zur Anfrage")
            except Exception as error:  # noqa: BLE001 - unknown stays unknown: the token is skipped
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
                if not isinstance(value, dict) or value.get("owner") != PUMP_PROGRAM:
                    continue
                try:
                    data = base64.b64decode((value.get("data") or [""])[0])
                except (TypeError, ValueError, IndexError):
                    continue
                state = parse_pump_curve(data)
                if state is not None:
                    out[account] = state
        return out

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
