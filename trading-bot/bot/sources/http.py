"""Tiny HTTP helper. Uses certifi when present because the python.org build
on macOS ships without CA certificates; falls back to the system store."""
from __future__ import annotations

import json
import ssl
import time
import urllib.error
import urllib.request
from typing import Any, Optional

_CTX: Optional[ssl.SSLContext] = None


def ssl_context() -> ssl.SSLContext:
    global _CTX
    if _CTX is None:
        try:
            import certifi  # type: ignore
            _CTX = ssl.create_default_context(cafile=certifi.where())
        except Exception:  # noqa: BLE001 - certifi is optional
            _CTX = ssl.create_default_context()
    return _CTX


class HttpError(Exception):
    def __init__(self, status: int, body: str) -> None:
        super().__init__(f"HTTP {status}: {_gist(status, body)}")
        self.status = status
        self.body = body


def _gist(status: int, body: str) -> str:
    """An error page's gist for the log, not its HTML. Only a challenge page is a block:
    Cloudflare also serves the 5xx pages of a server that is simply down."""
    head = body.lstrip()[:4000].lower()
    if head.startswith(("<!doctype", "<html")):
        if status in (403, 429, 503) and any(m in head for m in ("just a moment", "cf-chl", "attention required")):
            return "von Cloudflare blockiert (Browser-Prüfung) – von dieser Internetadresse aus nicht abrufbar"
        return "HTML-Seite statt Daten"
    return body[:200]


def post_json(url: str, body: Any, timeout: float = 60, headers: Optional[dict] = None) -> Any:
    """One POST with a JSON body; HTTP errors raise HttpError with the body."""
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"User-Agent": "new-token-bot/0.1", "Accept": "application/json",
                                          "Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl_context()) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise HttpError(e.code, e.read().decode("utf-8", "replace")) from None


def get_json(url: str, timeout: float = 15, retries: int = 2, headers: Optional[dict] = None) -> Any:
    last: Exception = RuntimeError("no attempt")
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, headers={"User-Agent": "new-token-bot/0.1",
                                                   "Accept": "application/json",
                                                   **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=ssl_context()) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            last = HttpError(e.code, body)
            if e.code == 429 or e.code >= 500:
                if attempt < retries:                 # wait only when another attempt follows
                    time.sleep(1.5 * (attempt + 1))
                continue
            raise last
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as e:
            last = e
            if attempt < retries:
                time.sleep(1.0 * (attempt + 1))
    raise last
