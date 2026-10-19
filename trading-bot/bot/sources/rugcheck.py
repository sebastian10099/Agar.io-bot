"""RugCheck summary for Solana mints (no key). Anything flagged 'danger'
disqualifies a token; the normalised score is a second gate."""
from __future__ import annotations

import time
from typing import Any, Callable, Optional

from .http import get_json

BASE = "https://api.rugcheck.xyz/v1"
TIMEOUT_S = 8
TRIP_AFTER = 3          # consecutive failures before RugCheck is paused
PAUSE_S = 60.0          # a rate-limited or down RugCheck is not asked again for this long


class RugCheck:
    def __init__(self, fetch=get_json, clock: Callable[[], float] = time.time) -> None:
        self.fetch = fetch
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
            return None                       # unknown: the token is watched, never bought
        self.calls += 1
        try:
            # no retries with back-off sleeps here: they would stall the whole poll
            data = self.fetch(f"{BASE}/tokens/{mint}/report/summary", timeout=TIMEOUT_S, retries=0)
        except Exception as error:  # noqa: BLE001 - unknown is a valid state
            self.fails += 1
            self._streak += 1
            self.last_error = f"{type(error).__name__}: {str(error)[:120]}"
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
        risks = data.get("risks") or []
        result = {
            "score": float(data.get("score_normalised", data.get("score", 0)) or 0),
            "danger": [r.get("name") for r in risks if str(r.get("level", "")).lower() == "danger"],
            "warn": [r.get("name") for r in risks if str(r.get("level", "")).lower() == "warn"],
        }
        self._cache[mint] = result
        return result
