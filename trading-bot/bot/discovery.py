"""Where new tokens come from.

A feed answers `discover(chains) -> {chain: [{"token": address, "snapshot":
pair-or-None}]}`. The engine asks every enabled feed in the configured order,
the first feed to name a token owns it (that is what the candidate shows as
its source), and DexScreener then supplies the numbers for all of them. A
token DexScreener has not indexed yet is evaluated from the feed's own
snapshot, so a GeckoTerminal find a few minutes ahead is not thrown away."""
from __future__ import annotations

import time
from typing import Any, Callable, Optional

LABELS = {
    "dexscreener": "DexScreener – Profile & Boosts",
    "geckoterminal": "GeckoTerminal – neue Pools",
    "pumpfun": "pump.fun – neue Coins",
}
DEFAULT_SOURCES = ["dexscreener"]


class DexScreenerFeed:
    """Adapter: the DexScreener client's promoted-token lists as a feed."""

    label = LABELS["dexscreener"]

    def __init__(self, dex: Any) -> None:
        self.dex = dex

    def discover(self, chains: list[str]) -> dict[str, list[dict[str, Any]]]:
        found = self.dex.recent_token_addresses(chains)
        return {chain: [{"token": t, "snapshot": None} for t in addrs] for chain, addrs in found.items()}


class Discovery:
    def __init__(self, cfg: dict[str, Any], feeds: dict[str, Any],
                 log: Optional[Callable[[str, str], None]] = None) -> None:
        self.cfg = cfg
        self.feeds = feeds
        self.log = log or (lambda level, msg: None)
        self._status: dict[str, dict[str, Any]] = {}

    def enabled(self) -> list[str]:
        names = (self.cfg.get("discovery") or {}).get("sources") or DEFAULT_SOURCES
        return [str(n) for n in names]

    def recent(self, chains: list[str]) -> dict[str, dict[str, dict[str, Any]]]:
        """{chain: {token: {"source": feed name, "snapshot": pair-or-None}}}"""
        out: dict[str, dict[str, dict[str, Any]]] = {c: {} for c in chains}
        reported: dict[str, set[tuple[str, str]]] = {}
        for name in self.enabled():
            st = self._status.setdefault(name, {"calls": 0, "found": 0, "unique": 0, "ok": None, "error": "", "at": None})
            feed = self.feeds.get(name)
            if feed is None:
                self._note(name, st, ok=False, error="in dieser Umgebung nicht verfügbar")
                continue
            try:
                found = feed.discover(list(chains))
            except Exception as error:  # noqa: BLE001 - a dead feed must not stop the others
                self._note(name, st, ok=False, error=f"{type(error).__name__}: {str(error)[:160]}")
                continue
            mine = reported.setdefault(name, set())
            for chain, items in (found or {}).items():
                if chain not in out:
                    continue
                for item in items:
                    token = item.get("token")
                    if not token:
                        continue
                    mine.add((chain, token))
                    if token not in out[chain]:              # first feed in the configured order owns the token
                        out[chain][token] = {"source": name, "snapshot": item.get("snapshot")}
                    elif out[chain][token]["snapshot"] is None and item.get("snapshot"):
                        out[chain][token]["snapshot"] = item["snapshot"]   # keep the owner, borrow the numbers
            st.update(calls=st["calls"] + 1, found=len(mine), at=time.time())
            self._note(name, st, ok=True, error="")
        for name, mine in reported.items():                   # "unique": no other feed saw it this poll
            others = set().union(*(s for n, s in reported.items() if n != name)) if len(reported) > 1 else set()
            self._status[name]["unique"] = len(mine - others)
        return out

    def _note(self, name: str, st: dict[str, Any], ok: bool, error: str) -> None:
        if st.get("ok") is not None and (st["ok"] != ok or st["error"] != error):
            self.log("warn" if not ok else "info",
                     f"Quelle {name}: " + (error if error else "wieder erreichbar"))
        elif st.get("ok") is None and not ok:
            self.log("warn", f"Quelle {name}: {error}")
        st["ok"], st["error"] = ok, error

    def status(self) -> list[dict[str, Any]]:
        enabled = self.enabled()
        rows = []
        for name in list(LABELS) + [n for n in enabled if n not in LABELS]:
            st = self._status.get(name, {})
            feed = self.feeds.get(name)
            rows.append({
                "name": name,
                "label": getattr(feed, "label", None) or LABELS.get(name, name),
                "enabled": name in enabled,
                "available": feed is not None,
                "ok": st.get("ok"), "error": st.get("error", ""),
                "throttled": "HTTP 429" in st.get("error", ""),       # up, only asking to slow down
                "found": st.get("found", 0), "unique": st.get("unique", 0),
                "calls": st.get("calls", 0), "at": st.get("at"),
            })
        return rows
