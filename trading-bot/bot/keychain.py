"""Secrets in the macOS Keychain - and nowhere else.

A secret never goes on a command line (other programs could read it from the
process list while `security` runs): it is written through `security -i`,
which reads its command from stdin. It is never written to a file or a log.
Other systems have no Keychain; there the caller says so and stores nothing."""
from __future__ import annotations

import os
import subprocess
import sys
import time
from typing import Optional

SECURITY = "/usr/bin/security"
CACHE_TTL_S = 30.0
_cache: dict[str, tuple[float, str]] = {}


def available() -> bool:
    return sys.platform == "darwin" and os.path.exists(SECURITY)


def _account() -> str:
    return os.environ.get("USER", "") or "newtokenbot"


def get(service: str, run=subprocess.run) -> str:
    """The stored value, "" when there is none (or no Keychain)."""
    if not available():
        return ""
    hit = _cache.get(service)
    if hit and time.time() - hit[0] < CACHE_TTL_S:
        return hit[1]
    try:
        result = run([SECURITY, "find-generic-password", "-s", service, "-a", _account(), "-w"],
                     capture_output=True, text=True, timeout=10)
        value = result.stdout.strip() if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        value = ""
    _cache[service] = (time.time(), value)
    return value


def put(service: str, value: str, run=subprocess.run) -> Optional[str]:
    """Store `value`; None when stored, else why not (in German, for the page)."""
    if not available():
        return "Den Schlüsselbund gibt es nur auf macOS."
    if not value or any(c in value for c in "\"'\\\n\r\t ") or len(value) > 4096:
        return "Der Wert enthält Zeichen, die hier nicht vorkommen dürfen."
    command = f'add-generic-password -U -s "{service}" -a "{_account()}" -w "{value}"\n'
    try:
        result = run([SECURITY, "-i"], input=command, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"Schlüsselbund nicht erreichbar: {type(error).__name__}"
    _cache.pop(service, None)
    if result.returncode != 0 or "error" in (result.stderr or "").lower():
        return "Der Schlüsselbund hat den Wert nicht angenommen."
    return None


def delete(service: str, run=subprocess.run) -> None:
    if available():
        try:
            run([SECURITY, "delete-generic-password", "-s", service, "-a", _account()],
                capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            pass
    _cache.pop(service, None)
