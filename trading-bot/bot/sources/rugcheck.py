"""RugCheck for Solana mints (no key). Anything flagged 'danger' disqualifies
a token; the normalised score is a second gate.

The full report (not just the summary) also says who holds the supply: the
largest wallets - pools and lockers left out -, insider networks, the
creator's share, and whether RugCheck saw the token rugged already. Holder
concentration is judged with the same lines as the own on-chain check
(solana_rpc.judge_holders), so a token is not bought with a wallet ready to
dump half the supply on the pool. In the live test 6 of 15 buys ended in a
total loss within minutes, mostly by such dumps."""
from __future__ import annotations

import time
from typing import Any, Callable, Optional

from .http import HttpError, get_json
from .solana_rpc import judge_holders

# accounts that hold tokens for others: their share is the pool's or the locker's, not a dumper's
NOT_A_HOLDER = {"amm", "locker", "lp", "pool", "program", "bonding curve", "bondingcurve"}

BASE = "https://api.rugcheck.xyz/v1"
TIMEOUT_S = 8
TRIP_AFTER = 3          # consecutive failures before RugCheck is paused
PAUSE_S = 60.0          # a rate-limited or down RugCheck is not asked again for this long
CACHE_TTL_S = 300.0     # a token turns dangerous later (holders sell, authorities change): look again


class RugCheck:
    def __init__(self, fetch=get_json, clock: Callable[[], float] = time.time) -> None:
        self.fetch = fetch
        self.clock = clock
        self._cache: dict[str, tuple[float, dict[str, Any]]] = {}
        self.calls = 0
        self.fails = 0
        self.last_error = ""
        self._streak = 0
        self._paused_until = 0.0

    def health(self) -> dict[str, Any]:
        return {"calls": self.calls, "fails": self.fails, "last_error": self.last_error,
                "ok": None if not self.calls else (self.last_error == "")}

    def summary(self, mint: str) -> Optional[dict[str, Any]]:
        hit = self._cache.get(mint)
        if hit and self.clock() - hit[0] < CACHE_TTL_S:
            return hit[1]
        if self.clock() < self._paused_until:
            return None                       # unknown: the token is watched, never bought
        self.calls += 1
        try:
            # no retries with back-off sleeps here: they would stall the whole poll
            data = self.fetch(f"{BASE}/tokens/{mint}/report", timeout=TIMEOUT_S, retries=0)
        except Exception as error:  # noqa: BLE001 - unknown is a valid state
            self.fails += 1
            self.last_error = f"{type(error).__name__}: {str(error)[:120]}"
            if isinstance(error, HttpError) and 400 <= error.status < 500 and error.status != 429:
                return None                   # this token only (not indexed yet): no reason to pause for all
            self._streak += 1
            if self._streak >= TRIP_AFTER:
                self._paused_until = self.clock() + PAUSE_S
                self.last_error += f" – Pause {PAUSE_S:.0f} s nach {self._streak} Fehlern"
                self._streak = 0
            return None
        if not isinstance(data, dict):
            self.fails += 1
            self.last_error = "unerwartete Antwort"
            return None
        self.last_error = ""
        self._streak = 0
        result = parse_report(data)
        self._cache[mint] = (self.clock(), result)
        return result


def _f(x: Any) -> float:
    try:
        return float(x)
    except (TypeError, ValueError):
        return 0.0


def parse_report(data: dict[str, Any]) -> dict[str, Any]:
    """RugCheck's report (or its summary) -> score, danger, warn, and what the report
    says about the holders when it has them."""
    risks = data.get("risks") or []
    result: dict[str, Any] = {
        "score": float(data.get("score_normalised", data.get("score", 0)) or 0),
        "danger": [r.get("name") for r in risks if str(r.get("level", "")).lower() == "danger"],
        "warn": [r.get("name") for r in risks if str(r.get("level", "")).lower() == "warn"],
    }
    known = {addr: str((info or {}).get("type") or "").lower()
             for addr, info in (data.get("knownAccounts") or {}).items() if isinstance(info, dict)}
    markets = data.get("markets") or []
    pools = {str(m.get(k)) for m in markets if isinstance(m, dict)
             for k in ("pubkey", "liquidityA", "liquidityB", "liquidityAAccount", "liquidityBAccount") if m.get(k)}
    holders = []
    for h in data.get("topHolders") or []:
        if not isinstance(h, dict):
            continue
        owner, address = str(h.get("owner") or ""), str(h.get("address") or "")
        if owner in pools or address in pools or known.get(owner) in NOT_A_HOLDER or known.get(address) in NOT_A_HOLDER:
            continue
        holders.append((_f(h.get("pct")), bool(h.get("insider"))))
    if holders:
        pcts = sorted((p for p, _ in holders), reverse=True)
        h = {"top1": round(pcts[0], 2), "top10": round(sum(pcts[:10]), 2),
             "insiders": round(sum(p for p, ins in holders if ins), 2), "source": "rugcheck"}
        result["holders"] = h
        danger, warn = judge_holders(h)
        result["danger"] += danger
        result["warn"] += warn
    insiders = int(_f(data.get("graphInsidersDetected")))
    if insiders:
        result["insider_wallets"] = insiders
        result["warn"].append(f"Insider-Netzwerk: {insiders} verbundene Wallets")
    supply = _f((data.get("token") or {}).get("supply"))
    if supply > 0 and data.get("creatorBalance") is not None:
        result["creator_pct"] = round(_f(data.get("creatorBalance")) / supply * 100, 2)
    locked = [_f((m.get("lp") or {}).get("lpLockedPct")) for m in markets if isinstance(m, dict) and m.get("lp")]
    if locked:
        result["lp_locked_pct"] = round(max(locked), 1)
    if data.get("rugged"):
        result["danger"].append("RugCheck: bereits gerugged")
    return result
