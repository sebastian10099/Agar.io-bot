"""Claude as a second opinion (or the decider) on candidates that passed the
hard filters.

The hard filters (rug flags, liquidity, age) are never delegated to the model:
it only sees tokens that already cleared them. Its verdict is recorded next to
the rule verdict on every candidate, so the edge report can show whether the
model's picks earn more than the rules' picks before anyone trusts it with
more than paper money.

Requires the official SDK (`pip install anthropic`) and a key: ANTHROPIC_API_KEY,
an `ant auth login` profile, or - on macOS - the Keychain item this module stores.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from typing import Any, Optional

KEYCHAIN_SERVICE = "NewTokenBot Anthropic"
KEYCHAIN_SERVICES = {"anthropic": "NewTokenBot Anthropic", "openrouter": "NewTokenBot OpenRouter"}
DEFAULT_MODEL = "claude-opus-5-5"
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
DEFAULT_OPENROUTER_MODEL = "meta-llama/llama-3.3-70b-instruct:free"
PROVIDERS = ("anthropic", "openrouter")

# $ per million tokens, Claude Opus 5.5 (input / output / cache read / cache write)
PRICES = {
    "claude-opus-5-5": (4.0, 20.0, 0.20, 5.0),
    "claude-opus-5": (5.0, 25.0, 0.25, 6.25),
    "claude-sonnet-5-5": (2.0, 10.0, 0.20, 2.5),
    "claude-haiku-5-5": (0.10, 0.50, 0.01, 0.125),
}

SYSTEM = """Du bist der zweite Blick eines Paper-Trading-Bots für frisch gelistete Krypto-Tokens (Solana, Memecoins).
Der Bot hält Positionen nur Minuten bis eine Stunde. Jeder Kandidat, den du siehst, hat die harten
Sicherheitsfilter (RugCheck-Gefahrenflags, Mindestliquidität, Altersfenster) bereits bestanden.

Deine Aufgabe: Beurteile anhand der Kennzahlen, ob ein kurzfristiger Einstieg mehr Chance als Risiko hat.
Bewerte nüchtern. Typische Warnzeichen: Käufe/Verkäufe-Verhältnis fällt, Volumen ohne Liquidität,
parabolischer Anstieg (zu spät), kein Social-Nachweis, konzentrierte Halter laut RugCheck-Warnungen,
Kursanstieg bei fallender Aktivität. Typische Chancen: stetiger Kaufdruck bei wachsender Liquidität,
junges Alter mit gesunder Aktivität, Volumen-zu-Liquidität in einem gesunden Band.

Du kannst Kurse nicht vorhersagen. Sag das nicht jedes Mal - handle danach: Im Zweifel "watch" oder "skip",
"buy" nur mit nachvollziehbarem Grund. Die Vertrauenszahl ist deine ehrliche Einschätzung, keine Formsache.
Antworte ausschließlich mit dem geforderten JSON."""

SCHEMA = {
    "type": "object",
    "properties": {
        "decision": {"type": "string", "enum": ["buy", "watch", "skip"]},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "reasons": {"type": "array", "items": {"type": "string"}, "maxItems": 3,
                    "description": "Bis zu drei kurze Gründe, Deutsch, je ein Satz."},
        "risk_flags": {"type": "array", "items": {"type": "string"}, "maxItems": 4,
                       "description": "Konkrete Warnzeichen, leer wenn keine."},
    },
    "required": ["decision", "confidence", "reasons", "risk_flags"],
    "additionalProperties": False,
}


def keychain_key(provider: str = "anthropic") -> str:
    if sys.platform != "darwin":
        return ""
    try:
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICES.get(provider, KEYCHAIN_SERVICE),
             "-a", os.environ.get("USER", ""), "-w"],
            capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def profile_dir() -> str:
    return os.environ.get("ANTHROPIC_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".config", "anthropic")


def has_profile() -> bool:
    """An `ant auth login` profile: credentials/<profile>.json under the config dir.
    A bare Anthropic() client picks it up by itself, no key to paste."""
    cred = os.path.join(profile_dir(), "credentials")
    try:
        return any(n.endswith(".json") for n in os.listdir(cred))
    except OSError:
        return False


def credential_source() -> str:
    """Where a credential would come from, in the SDK's own resolution order."""
    if os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"):
        return "env"
    if keychain_key():
        return "keychain"
    if has_profile():
        return "profile"
    return "none"


ANT_INSTALL = "brew install anthropics/tap/ant && xattr -d com.apple.quarantine \"$(brew --prefix)/bin/ant\""


def ant_path() -> str:
    import shutil
    found = shutil.which("ant")
    if found:
        return found
    for candidate in ("/opt/homebrew/bin/ant", "/usr/local/bin/ant",     # launchd/.command shells have a short PATH
                      os.path.expanduser("~/NewTokenBot/bin/ant")):     # install-app.sh without Homebrew
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return ""


def start_login(runner=None) -> dict[str, Any]:
    """Launch `ant auth login`, which opens the browser; the profile appears on
    disk when the login completes. Returns right away so the page can poll."""
    if has_profile():
        return {"ok": True, "already": True, "detail": "Schon angemeldet – Profil vorhanden."}
    exe = ant_path()
    if not exe:
        return {"ok": False, "error": "Die Anthropic-CLI „ant“ fehlt. Im Terminal einmal installieren:", "install": ANT_INSTALL}
    try:
        if runner is not None:
            runner([exe, "auth", "login"])
        else:
            subprocess.Popen([exe, "auth", "login"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as error:
        return {"ok": False, "error": f"„ant auth login“ ließ sich nicht starten: {error}"}
    return {"ok": True, "already": False, "detail": "Browser geöffnet – dort mit deinem Claude-Konto anmelden. Die Seite merkt es von selbst."}


def openrouter_key() -> str:
    return os.environ.get("OPENROUTER_API_KEY") or keychain_key("openrouter")


def openrouter_source() -> str:
    if os.environ.get("OPENROUTER_API_KEY"):
        return "env"
    if keychain_key("openrouter"):
        return "keychain"
    return "none"


def store_key(value: str, provider: str = "anthropic") -> dict[str, Any]:
    value = (value or "").strip()
    if provider not in KEYCHAIN_SERVICES:
        return {"ok": False, "error": "Unbekannter Anbieter."}
    if len(value) < 20 or any(c.isspace() for c in value):
        return {"ok": False, "error": "Der Schlüssel sieht nicht gültig aus."}
    if sys.platform != "darwin":
        env = "ANTHROPIC_API_KEY" if provider == "anthropic" else "OPENROUTER_API_KEY"
        return {"ok": False, "error": f"Schlüsselbund gibt es nur auf macOS. Setze {env} in der Umgebung."}
    try:
        result = subprocess.run(
            ["/usr/bin/security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICES[provider],
             "-a", os.environ.get("USER", ""), "-w", value],
            capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"ok": False, "error": f"Schlüsselbund nicht erreichbar: {error}"}
    if result.returncode != 0:
        return {"ok": False, "error": "Der Schlüssel konnte nicht gespeichert werden."}
    return {"ok": True}


def _default_post(url: str, body: Any, headers: Optional[dict] = None) -> Any:
    from .sources.http import post_json
    return post_json(url, body, timeout=90, headers=headers)


def _estimate_cost(model: str, usage: Any) -> float:
    base = next((v for k, v in PRICES.items() if model.startswith(k)), PRICES[DEFAULT_MODEL])
    inp, out, cread, cwrite = base
    g = lambda name: float(getattr(usage, name, 0) or 0)  # noqa: E731
    return (g("input_tokens") * inp + g("output_tokens") * out +
            g("cache_read_input_tokens") * cread + g("cache_creation_input_tokens") * cwrite) / 1e6


class ClaudeAdvisor:
    def __init__(self, cfg: dict[str, Any], log=None, client: Any = None) -> None:
        self.cfg = cfg
        self.log = log or (lambda level, msg: None)
        self._client = client
        self._post = None                      # injectable HTTP POST for OpenRouter (tests)
        self._client_error: Optional[str] = None
        self._calls: list[float] = []
        self._last_error: Optional[str] = None
        self.calls_total = 0
        self.cost_total = 0.0
        self._fallbacks_ok = True

    # --- configuration ----------------------------------------------------
    @property
    def settings(self) -> dict[str, Any]:
        return self.cfg.get("ai", {})

    @property
    def enabled(self) -> bool:
        return self.settings.get("mode", "off") in ("advise", "decide")

    @property
    def provider(self) -> str:
        p = self.settings.get("provider", "anthropic")
        return p if p in PROVIDERS else "anthropic"

    @property
    def model(self) -> str:
        if self.provider == "openrouter":
            return self.settings.get("openrouter_model") or DEFAULT_OPENROUTER_MODEL
        return self.settings.get("model") or DEFAULT_MODEL

    def _client_or_none(self) -> Any:
        if self._client is not None:
            return self._client
        if self._client_error:
            return None
        try:
            import anthropic  # noqa: WPS433 - optional dependency
        except ImportError:
            self._client_error = "SDK fehlt: pip install anthropic"
            return None
        if credential_source() == "none":
            self._client_error = ("Kein Schlüssel gefunden: ANTHROPIC_API_KEY setzen, Schlüssel unten im "
                                  "Schlüsselbund speichern oder `ant auth login` ausführen")
            return None
        key = os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN") or keychain_key()
        try:
            self._client = anthropic.Anthropic(api_key=key) if key else anthropic.Anthropic()
        except Exception as error:  # noqa: BLE001 - missing credentials surfaces here
            self._client_error = f"Kein Zugang: {error}"
            return None
        return self._client

    def status(self) -> dict[str, Any]:
        s = self.settings
        now = time.time()
        self._calls = [t for t in self._calls if now - t < 3600]
        if self.provider == "openrouter":
            available = bool(openrouter_key()) if self.enabled else False
            reason = ("Kein OpenRouter-Schlüssel: unten speichern oder OPENROUTER_API_KEY setzen" if self.enabled and not available else "") or self._last_error or ""
            return {
                "mode": s.get("mode", "off"), "provider": "openrouter", "model": self.model,
                "available": available, "reason": reason,
                "calls_last_hour": len(self._calls), "calls_total": self.calls_total,
                "cost_total_usd": round(self.cost_total, 4),
                "key_source": openrouter_source(),
            }
        client = self._client_or_none() if self.enabled else None
        return {
            "mode": s.get("mode", "off"), "provider": "anthropic", "model": self.model,
            "available": client is not None, "reason": self._client_error or self._last_error or "",
            "calls_last_hour": len(self._calls), "calls_total": self.calls_total,
            "cost_total_usd": round(self.cost_total, 4),
            "key_source": credential_source(),
        }

    # --- the call -----------------------------------------------------------
    def judge(self, pair: dict[str, Any], rug: Optional[dict[str, Any]],
              rules: dict[str, Any]) -> Optional[dict[str, Any]]:
        if not self.enabled:
            return None
        if self.provider == "openrouter":
            return self._judge_openrouter(pair, rug, rules)
        client = self._client_or_none()
        if client is None:
            return None
        now = time.time()
        self._calls = [t for t in self._calls if now - t < 3600]
        if len(self._calls) >= int(self.settings.get("max_calls_per_hour", 60)):
            self._last_error = "Stundenlimit für KI-Anfragen erreicht"
            return None

        model = self.model
        user = self._user_message(pair, rug, rules)
        request = dict(
            model=model, max_tokens=2048,
            system=[{"type": "text", "text": SYSTEM, "cache_control": {"type": "ephemeral"}}],
            messages=[{"role": "user", "content": user}],
            output_config={"effort": self.settings.get("effort", "medium"),
                           "format": {"type": "json_schema", "schema": SCHEMA}},
        )
        try:
            import anthropic
            errors: tuple = (anthropic.APIError,)
        except ImportError:  # the injected test client does not need the SDK
            anthropic = None  # type: ignore[assignment]
            errors = (Exception,)

        self._calls.append(now)
        self.calls_total += 1
        try:
            response = self._create(client, request)
        except errors as error:  # noqa: BLE001 - mapped below
            self._last_error = self._describe(anthropic, error)
            self.log("error", "KI: " + self._last_error)
            return None

        self.cost_total += _estimate_cost(model, getattr(response, "usage", None))
        if getattr(response, "stop_reason", None) == "refusal":
            details = getattr(response, "stop_details", None)
            self._last_error = "KI hat die Anfrage abgelehnt" + (f" ({details.category})" if details and getattr(details, "category", None) else "")
            return None
        text = next((b.text for b in response.content if getattr(b, "type", "") == "text"), "")
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            self._last_error = "KI-Antwort war kein JSON"
            return None
        if data.get("decision") not in ("buy", "watch", "skip"):
            self._last_error = "KI-Antwort ohne gültige Entscheidung"
            return None
        self._last_error = None
        return {
            "decision": data["decision"],
            "confidence": max(0.0, min(1.0, float(data.get("confidence", 0)))),
            "reasons": [str(r)[:200] for r in (data.get("reasons") or [])][:3],
            "risk_flags": [str(r)[:100] for r in (data.get("risk_flags") or [])][:4],
            "model": getattr(response, "model", model),
        }

    @staticmethod
    def _user_message(pair: dict[str, Any], rug: Optional[dict[str, Any]], rules: dict[str, Any]) -> str:
        facts = {k: pair.get(k) for k in ("symbol", "name", "chain", "dex", "age_min", "price_usd", "liquidity_usd",
                                           "fdv", "volume_m5", "volume_h1", "buys_m5", "sells_m5", "buys_h1", "sells_h1",
                                           "change_m5", "change_h1", "boosts", "has_socials")}
        payload = {"token": facts, "rugcheck": rug, "regel_urteil": rules}
        return ("Kandidat (Kennzahlen von DexScreener, RugCheck-Zusammenfassung, Urteil der Regeln):\n"
                + json.dumps(payload, ensure_ascii=False, default=str))

    @staticmethod
    def _parse_verdict(text: str) -> Optional[dict[str, Any]]:
        text = (text or "").strip()
        if text.startswith("```"):
            text = text.strip("`")
            text = text[4:] if text.lower().startswith("json") else text
        start, end = text.find("{"), text.rfind("}")
        if start < 0 or end < 0:
            return None
        try:
            data = json.loads(text[start:end + 1])
        except json.JSONDecodeError:
            return None
        return data if isinstance(data, dict) else None

    # --- OpenRouter: any OpenAI-compatible model, free ones included -----------------
    def _judge_openrouter(self, pair: dict[str, Any], rug: Optional[dict[str, Any]],
                          rules: dict[str, Any]) -> Optional[dict[str, Any]]:
        key = openrouter_key()
        if not key:
            self._last_error = "Kein OpenRouter-Schlüssel"
            return None
        now = time.time()
        self._calls = [t for t in self._calls if now - t < 3600]
        if len(self._calls) >= int(self.settings.get("max_calls_per_hour", 60)):
            self._last_error = "Stundenlimit für KI-Anfragen erreicht"
            return None
        model = self.model
        body = {
            "model": model, "max_tokens": 600, "temperature": 0.2,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": SYSTEM + "\n\nAntworte NUR mit einem JSON-Objekt mit genau diesen Feldern: "
                 "decision (\"buy\"|\"watch\"|\"skip\"), confidence (Zahl 0-1), reasons (Liste mit bis zu 3 kurzen deutschen Sätzen), "
                 "risk_flags (Liste konkreter Warnzeichen, leer wenn keine)."},
                {"role": "user", "content": self._user_message(pair, rug, rules)},
            ],
        }
        headers = {"Authorization": f"Bearer {key}", "HTTP-Referer": "https://github.com/sebastian10099/Agar.io-bot", "X-Title": "New Token Bot"}
        post = self._post or _default_post
        self._calls.append(now)
        self.calls_total += 1
        try:
            response = post(OPENROUTER_URL, body, headers=headers)
        except Exception as error:  # noqa: BLE001 - mapped below
            self._last_error = self._describe_http(error)
            self.log("error", "KI (OpenRouter): " + self._last_error)
            return None
        if isinstance(response, dict) and response.get("error"):
            err = response["error"]
            self._last_error = f"OpenRouter: {err.get('message', err) if isinstance(err, dict) else err}"[:200]
            self.log("error", "KI (OpenRouter): " + self._last_error)
            return None
        try:
            text = response["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError):
            self._last_error = "OpenRouter-Antwort ohne Inhalt"
            return None
        usage = response.get("usage") or {}
        self.cost_total += float(usage.get("cost") or 0)     # OpenRouter reports $ cost; free models say 0
        data = self._parse_verdict(text if isinstance(text, str) else "")
        if not data:
            self._last_error = "KI-Antwort war kein JSON"
            return None
        if data.get("decision") not in ("buy", "watch", "skip"):
            self._last_error = "KI-Antwort ohne gültige Entscheidung"
            return None
        self._last_error = None
        return {
            "decision": data["decision"],
            "confidence": max(0.0, min(1.0, float(data.get("confidence", 0) or 0))),
            "reasons": [str(r)[:200] for r in (data.get("reasons") or [])][:3],
            "risk_flags": [str(r)[:100] for r in (data.get("risk_flags") or [])][:4],
            "model": str(response.get("model") or model),
        }

    @staticmethod
    def _describe_http(error: Exception) -> str:
        status = getattr(error, "status", None)
        if status == 401:
            return "OpenRouter-Schlüssel ungültig (401)"
        if status == 402:
            return "OpenRouter: kein Guthaben für dieses Modell (402) – ein Modell mit „:free“ wählen"
        if status == 404:
            return "OpenRouter: Modell nicht gefunden (404) – ai.openrouter_model prüfen"
        if status == 429:
            return "OpenRouter: Rate-Limit (429) – freie Modelle erlauben nur wenige Anfragen pro Minute"
        if status:
            return f"OpenRouter-Fehler {status}: {str(getattr(error, 'body', ''))[:120]}"
        return f"Keine Verbindung zu OpenRouter: {type(error).__name__}: {str(error)[:120]}"

    def _create(self, client: Any, request: dict[str, Any]) -> Any:
        """Beta endpoint with server-side refusal fallbacks; if the platform
        rejects the fallback parameter, retry once without it and remember."""
        if self._fallbacks_ok:
            try:
                return client.beta.messages.create(
                    betas=["server-side-fallback-2026-07-01"], fallbacks="default", **request)
            except Exception as error:  # noqa: BLE001 - only the fallback-specific 400 is swallowed
                msg = str(error).lower()
                if "fallback" in msg and getattr(error, "status_code", 400) == 400:
                    self._fallbacks_ok = False
                    self.log("info", "KI: Server-Fallbacks hier nicht verfügbar, weiter ohne")
                else:
                    raise
        return client.messages.create(**request)

    @staticmethod
    def _describe(anthropic: Any, error: Exception) -> str:
        if anthropic is not None:
            if isinstance(error, anthropic.AuthenticationError):
                return "Schlüssel ungültig (401)"
            if isinstance(error, anthropic.PermissionDeniedError):
                return "Schlüssel ohne Berechtigung (403)"
            if isinstance(error, anthropic.NotFoundError):
                return "Modell nicht gefunden - ai.model prüfen"
            if isinstance(error, anthropic.RateLimitError):
                return "Rate-Limit der API (429)"
            if isinstance(error, anthropic.BadRequestError):
                return f"Anfrage abgelehnt (400): {getattr(error, 'message', error)}"
            if isinstance(error, anthropic.APIStatusError):
                return f"API-Fehler {error.status_code}"
            if isinstance(error, anthropic.APIConnectionError):
                return "Keine Verbindung zur API"
        return f"{type(error).__name__}: {error}"


def _self_check(argv: list[str]) -> int:
    """`python3 -m bot.ai` - one real call on a fixture candidate, prints the verdict and cost."""
    import argparse
    from pathlib import Path

    ap = argparse.ArgumentParser(description="Einmaliger KI-Selbsttest mit einem Beispiel-Kandidaten")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--effort", default="medium", choices=["low", "medium", "high"])
    ap.add_argument("--provider", default="anthropic", choices=list(PROVIDERS))
    ap.add_argument("--openrouter-model", default=DEFAULT_OPENROUTER_MODEL)
    args = ap.parse_args(argv)

    cfg = {"ai": {"mode": "advise", "provider": args.provider, "model": args.model, "openrouter_model": args.openrouter_model,
                  "effort": args.effort, "max_calls_per_hour": 5}}
    advisor = ClaudeAdvisor(cfg, log=lambda level, msg: print(f"[{level}] {msg}"))
    status = advisor.status()
    print(f"Modell {status['model']} · Schlüsselquelle: {status['key_source']}")
    if not status["available"]:
        print("Nicht verfügbar:", status["reason"])
        return 1

    fixtures = Path(__file__).parent.parent / "tests" / "fixtures" / "pairs.json"
    raw = next(p for p in json.loads(fixtures.read_text()) if p["baseToken"]["symbol"] == "RUN")
    raw.pop("_demo", None)
    raw["pairCreatedAt"] = int((time.time() - 12 * 60) * 1000)
    from .sources.dexscreener import normalize_pair
    pair = normalize_pair(raw)
    rug = {"score": 120, "danger": [], "warn": []}
    rules = {"decision": "buy", "score": 64.4, "reasons": ["liquidity 7", "activity 10", "pressure 15", "momentum 8", "age 10", "socials 5", "rugcheck 9"]}

    print(f"Frage {'OpenRouter' if args.provider == 'openrouter' else 'Claude'} nach dem Beispiel-Token RUN ...")
    started = time.time()
    verdict = advisor.judge(pair, rug, rules)
    took = time.time() - started
    if verdict is None:
        print("Kein Urteil:", advisor.status()["reason"])
        return 2
    print(f"Urteil: {verdict['decision']} ({verdict['confidence']:.0%}) in {took:.1f}s · {verdict['model']}")
    for r in verdict["reasons"]:
        print("  -", r)
    for f in verdict["risk_flags"]:
        print("  ! ", f)
    print(f"Kosten dieser Anfrage: ≈ ${advisor.cost_total:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_self_check(sys.argv[1:]))
