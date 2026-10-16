"""RugCheck summary for Solana mints (no key). Anything flagged 'danger'
disqualifies a token; the normalised score is a second gate."""
from __future__ import annotations

from typing import Any, Optional

from .http import get_json

BASE = "https://api.rugcheck.xyz/v1"


class RugCheck:
    def __init__(self, fetch=get_json) -> None:
        self.fetch = fetch
        self._cache: dict[str, dict[str, Any]] = {}
        self.calls = 0
        self.fails = 0
        self.last_error = ""

    def health(self) -> dict[str, Any]:
        return {"calls": self.calls, "fails": self.fails, "last_error": self.last_error,
                "ok": None if not self.calls else (self.last_error == "")}

    def summary(self, mint: str) -> Optional[dict[str, Any]]:
        if mint in self._cache:
            return self._cache[mint]
        self.calls += 1
        try:
            data = self.fetch(f"{BASE}/tokens/{mint}/report/summary", timeout=12)
        except Exception as error:  # noqa: BLE001 - unknown is a valid state
            self.fails += 1
            self.last_error = f"{type(error).__name__}: {str(error)[:120]}"
            return None
        if not isinstance(data, dict):
            self.fails += 1
            self.last_error = "unerwartete Antwort"
            return None
        self.last_error = ""
        risks = data.get("risks") or []
        result = {
            "score": float(data.get("score_normalised", data.get("score", 0)) or 0),
            "danger": [r.get("name") for r in risks if str(r.get("level", "")).lower() == "danger"],
            "warn": [r.get("name") for r in risks if str(r.get("level", "")).lower() == "warn"],
        }
        self._cache[mint] = result
        return result
