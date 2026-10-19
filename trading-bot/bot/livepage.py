"""The Paper-Live test inside the app: GitHub runs the same bot with play money and
publishes a snapshot page on the branch paper-live. github.io does not always serve
it (Pages may be off for the repository); raw.githubusercontent.com does, but as
plain text - so the app fetches it and shows it under /live.

The page comes from elsewhere and is served on the control page's own address:
the Content-Security-Policy sandboxes it (no scripts, its own opaque origin), so it
can never use the bot's API."""
from __future__ import annotations

import html
import time
import urllib.request
from typing import Callable, Optional

from .sources.http import ssl_context

LIVE_URL = "https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/paper-live/index.html"
CACHE_S = 30.0
CSP = ("sandbox allow-popups allow-popups-to-escape-sandbox; default-src 'none'; "
       "style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'")
BANNER = ('<p style="margin:0 0 14px;font:14px system-ui,sans-serif">'
          '<a href="/" style="color:inherit">← zurück zur Steuerung</a> · '
          'der Test auf GitHub: derselbe Bot mit Spielgeld, eigenes Konto</p>')

_cache: dict[str, object] = {"at": 0.0, "body": b""}


def _fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "new-token-bot/0.1", "Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=10, context=ssl_context()) as r:
        return r.read(2_000_000)


def page(fetch: Optional[Callable[[str], bytes]] = None, now: Callable[[], float] = time.time) -> bytes:
    """The snapshot page with a way back; on a failed fetch the last good one, else why not."""
    if _cache["body"] and now() - float(_cache["at"]) < CACHE_S:
        return _cache["body"]  # type: ignore[return-value]
    try:
        body = (fetch or _fetch)(LIVE_URL)
        if b"<main>" not in body:
            raise ValueError("keine Paper-Live-Seite")
        body = body.replace(b"<main>", b"<main>" + BANNER.encode("utf-8"), 1)
        _cache.update(at=now(), body=body)
        return body
    except Exception as error:  # noqa: BLE001 - shown on the page, the app goes on
        if _cache["body"]:
            return _cache["body"]  # type: ignore[return-value]
        why = html.escape(f"{type(error).__name__}: {error}"[:200])
        return ("<!doctype html><meta charset=utf-8><title>Paper-Live</title>"
                "<body style='font:16px system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 16px'>"
                f"{BANNER}<h1 style='font-size:22px'>Paper-Live gerade nicht erreichbar</h1>"
                f"<p>Die Seite des Tests ließ sich nicht von GitHub laden ({why}). Internet da? "
                "In einer Minute noch einmal versuchen.</p>").encode("utf-8")
