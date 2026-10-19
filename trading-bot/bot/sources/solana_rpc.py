"""Own safety check straight from the Solana chain, used when RugCheck does not
answer. One public RPC call per token (getAccountInfo on the mint) reveals the
signals that make a token a trap no matter what its chart looks like:

- freeze authority still set   -> the creator can freeze your tokens (honeypot)
- mint authority still set     -> the creator can print unlimited supply
- Token-2022 extensions        -> permanent delegate, transfer hook, pausable,
                                  frozen-by-default accounts, non-transferable:
                                  all let someone take or lock your tokens;
                                  a transfer fee is a warning.

It sees less than RugCheck (no holder or LP analysis), so the strategy gives
it only half of RugCheck's score points. RPC: SOLANA_RPC_URL, default the
public mainnet endpoint (rate-limited, enough for the few tokens that reach
this check)."""
from __future__ import annotations

import os
import time
from typing import Any, Callable, Optional

from .http import post_json

DEFAULT_RPC = "https://api.mainnet-beta.solana.com"
TIMEOUT_S = 8
TRIP_AFTER = 3
PAUSE_S = 60.0

DANGER_EXTENSIONS = {
    "permanentDelegate": "Permanent Delegate (kann Tokens aus jedem Konto ziehen)",
    "transferHook": "Transfer-Hook (fremdes Programm entscheidet über Verkäufe)",
    "pausableConfig": "pausierbar (Handel kann gestoppt werden)",
    "nonTransferable": "nicht übertragbar",
}


def rpc_url() -> str:
    return os.environ.get("SOLANA_RPC_URL") or DEFAULT_RPC


def assess_mint(value: Optional[dict[str, Any]]) -> Optional[dict[str, Any]]:
    """getAccountInfo(jsonParsed).result.value of a mint -> safety summary, or None if it is no SPL mint."""
    if not isinstance(value, dict):
        return None
    data = value.get("data")
    parsed = data.get("parsed") if isinstance(data, dict) else None
    if not isinstance(parsed, dict) or parsed.get("type") != "mint":
        return None
    info = parsed.get("info") or {}
    danger: list[str] = []
    warn: list[str] = []
    if info.get("freezeAuthority"):
        danger.append("Freeze Authority aktiv (Konten können eingefroren werden)")
    if info.get("mintAuthority"):
        warn.append("Mint Authority aktiv (Menge kann erhöht werden)")
    for ext in info.get("extensions") or []:
        name = (ext or {}).get("extension")
        state = (ext or {}).get("state") or {}
        if name in DANGER_EXTENSIONS:
            if name == "permanentDelegate" and not state.get("delegate"):
                continue
            if name == "transferHook" and not state.get("programId"):
                continue
            danger.append(DANGER_EXTENSIONS[name])
        elif name == "defaultAccountState" and str(state.get("accountState", "")).lower() == "frozen":
            danger.append("Konten standardmäßig eingefroren")
        elif name == "transferFeeConfig":
            fee = ((state.get("newerTransferFee") or {}).get("transferFeeBasisPoints")
                   or (state.get("olderTransferFee") or {}).get("transferFeeBasisPoints") or 0)
            if int(fee) > 0:
                warn.append(f"Transfergebühr {int(fee) / 100:g} %")
    return {"score": 0.0, "danger": danger, "warn": warn, "source": "onchain",
            "program": data.get("program") if isinstance(data, dict) else None}


class OnChainCheck:
    label = "Eigenprüfung (Solana-RPC)"

    def __init__(self, post: Callable[..., Any] = post_json, url: Optional[str] = None,
                 clock: Callable[[], float] = time.time) -> None:
        self.post = post
        self.url = url or rpc_url()
        self.clock = clock
        self._cache: dict[str, dict[str, Any]] = {}
        self.calls = 0
        self.fails = 0
        self.last_error = ""
        self._streak = 0
        self._paused_until = 0.0

    def health(self) -> dict[str, Any]:
        return {"calls": self.calls, "fails": self.fails, "last_error": self.last_error,
                "ok": None if not self.calls else (self.last_error == "")}

    def summary(self, mint: str) -> Optional[dict[str, Any]]:
        if mint in self._cache:
            return self._cache[mint]
        if self.clock() < self._paused_until:
            return None
        self.calls += 1
        body = {"jsonrpc": "2.0", "id": 1, "method": "getAccountInfo",
                "params": [mint, {"encoding": "jsonParsed", "commitment": "confirmed"}]}
        try:
            answer = self.post(self.url, body, timeout=TIMEOUT_S)
            if not isinstance(answer, dict):
                raise RuntimeError("unerwartete Antwort")
            if answer.get("error"):
                raise RuntimeError(str((answer["error"] or {}).get("message", answer["error"]))[:120])
            result = assess_mint(((answer.get("result") or {}).get("value")))
            if result is None:
                raise RuntimeError("kein SPL-Token-Mint")
        except Exception as error:  # noqa: BLE001 - unknown stays unknown: the token is watched, never bought
            self.fails += 1
            self._streak += 1
            self.last_error = f"{type(error).__name__}: {str(error)[:120]}"
            if self._streak >= TRIP_AFTER:
                self._paused_until = self.clock() + PAUSE_S
                self.last_error += f" – Pause {PAUSE_S:.0f} s nach {self._streak} Fehlern"
                self._streak = 0
            return None
        self.last_error = ""
        self._streak = 0
        self._cache[mint] = result
        return result


class SafetyCheck:
    """RugCheck first; when it has no answer, the own on-chain check."""

    def __init__(self, rugcheck: Any, onchain: Any) -> None:
        self.rugcheck = rugcheck
        self.onchain = onchain

    def summary(self, mint: str) -> Optional[dict[str, Any]]:
        r = self.rugcheck.summary(mint)
        if r is not None:
            return dict(r, source=r.get("source", "rugcheck"))
        return self.onchain.summary(mint)

    def health(self) -> dict[str, Any]:
        h = dict(self.rugcheck.health())
        h["fallback"] = self.onchain.health()
        return h

    # the self-test pokes at the RugCheck cache and error text
    @property
    def _cache(self) -> dict[str, Any]:
        return self.rugcheck._cache

    @property
    def last_error(self) -> str:
        return self.rugcheck.last_error
