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

    def summary(self, mint: str) -> Optional[dict[str, Any]]:
        if mint in self._cache:
            return self._cache[mint]
        try:
            data = self.fetch(f"{BASE}/tokens/{mint}/report/summary", timeout=12)
        except Exception:  # noqa: BLE001 - unknown is a valid state
            return None
        if not isinstance(data, dict):
            return None
        risks = data.get("risks") or []
        result = {
            "score": float(data.get("score_normalised", data.get("score", 0)) or 0),
            "danger": [r.get("name") for r in risks if str(r.get("level", "")).lower() == "danger"],
            "warn": [r.get("name") for r in risks if str(r.get("level", "")).lower() == "warn"],
        }
        self._cache[mint] = result
        return result
