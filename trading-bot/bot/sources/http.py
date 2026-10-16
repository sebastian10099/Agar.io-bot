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
        super().__init__(f"HTTP {status}: {body[:200]}")
        self.status = status
        self.body = body


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
                time.sleep(1.5 * (attempt + 1))
                continue
            raise last
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as e:
            last = e
            time.sleep(1.0 * (attempt + 1))
    raise last
