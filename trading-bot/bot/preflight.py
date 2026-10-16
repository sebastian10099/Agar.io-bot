"""Start check that repairs the two things that most often break a fresh Mac:
the python.org build ships without CA certificates (every HTTPS call fails
with CERTIFICATE_VERIFY_FAILED), and the Anthropic SDK is not installed.
Both are fixed with a one-off `pip install --user`, done here so nobody has
to open a terminal for it.

  python3 -m bot.preflight          # exit 0 when HTTPS works (SDK is a warning)
  python3 -m bot.preflight --demo   # offline demo: nothing to check
"""
from __future__ import annotations

import importlib
import site
import ssl
import subprocess
import sys
from typing import Any, Callable, Optional

PROBE_URL = "https://api.dexscreener.com/token-profiles/latest/v1"
PIP_TIMEOUT = 240


def _say(msg: str) -> None:
    print("preflight: " + msg, flush=True)


def pip_install(package: str, run: Callable[..., Any] = subprocess.run) -> bool:
    """`python -m pip install --user <package>`, quiet, time-boxed. False on any failure."""
    try:
        result = run([sys.executable, "-m", "pip", "install", "--user", "--quiet", "--disable-pip-version-check", package],
                     capture_output=True, text=True, timeout=PIP_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as error:
        _say(f"pip install {package} fehlgeschlagen: {error}")
        return False
    if result.returncode != 0:
        _say(f"pip install {package} fehlgeschlagen: {(result.stderr or result.stdout).strip()[-300:]}")
        return False
    # a freshly created user site dir is not on sys.path yet
    try:
        site.addsitedir(site.getusersitepackages())
    except Exception:  # noqa: BLE001
        pass
    importlib.invalidate_caches()
    return True


def https_ok(fetch: Optional[Callable[..., Any]] = None) -> tuple[bool, str]:
    """Can this interpreter reach the market API over TLS? Uses the bot's own
    HTTP helper (certifi when present), so the answer matches what the bot does."""
    from .sources import http
    http._CTX = None                       # re-read the CA store (certifi may have just been installed)
    fetch = fetch or (lambda: http.get_json(PROBE_URL, timeout=15, retries=0))
    try:
        fetch()
        return True, "HTTPS ok"
    except ssl.SSLError as error:
        return False, f"TLS: {error}"
    except Exception as error:  # noqa: BLE001
        msg = str(error)
        if "CERTIFICATE_VERIFY_FAILED" in msg or "SSL" in type(error).__name__:
            return False, f"TLS: {msg[:160]}"
        return False, f"{type(error).__name__}: {msg[:160]}"


def ensure_https(fetch: Optional[Callable[..., Any]] = None, run: Callable[..., Any] = subprocess.run) -> tuple[bool, str]:
    ok, why = https_ok(fetch)
    if ok:
        return True, why
    if not why.startswith("TLS"):
        return False, why                   # offline or blocked: certifi would not help
    _say(f"{why} – installiere certifi (CA-Zertifikate) …")
    if not pip_install("certifi", run):
        return False, why + " (certifi-Installation fehlgeschlagen)"
    return https_ok(fetch)


def sdk_version(importer: Callable[[str], Any] = importlib.import_module) -> Optional[str]:
    try:
        mod = importer("anthropic")
    except ImportError:
        return None
    return str(getattr(mod, "__version__", "?"))


def ensure_sdk(importer: Callable[[str], Any] = importlib.import_module, run: Callable[..., Any] = subprocess.run) -> tuple[bool, str]:
    version = sdk_version(importer)
    if version:
        return True, f"Anthropic-SDK {version}"
    _say("Anthropic-SDK fehlt – installiere anthropic (einmalig, für den KI-Modus) …")
    if not pip_install("anthropic", run):
        return False, "Anthropic-SDK fehlt; KI-Modus bleibt aus, bis `pip install anthropic` geklappt hat"
    version = sdk_version(importer)
    return (True, f"Anthropic-SDK {version} installiert") if version else (False, "Anthropic-SDK nach Installation nicht importierbar")


def main(argv: Optional[list[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    _say(f"Python {sys.version.split()[0]} ({sys.executable})")
    if sys.version_info < (3, 9):
        _say("Python ist zu alt – mindestens 3.9")
        return 2
    if "--demo" in argv:
        _say("Demo-Modus: keine Netzprüfung")
        return 0
    ok, why = ensure_https()
    _say(why)
    if not ok:
        if why.startswith("TLS"):
            _say("Abhilfe: in Finder /Applications/Python 3.x/ 'Install Certificates.command' doppelklicken, "
                 "oder: python3 -m pip install --user certifi")
        else:
            _say("Keine Verbindung zum Markt-API – Internet, VPN oder Firewall prüfen; der Bot braucht api.dexscreener.com")
        return 1
    sdk_ok, sdk_why = ensure_sdk()
    _say(sdk_why)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
