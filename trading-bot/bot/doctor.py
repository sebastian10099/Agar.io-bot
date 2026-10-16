"""Self-test: is everything this bot depends on reachable, and do the live
answers still parse? Runs against whatever sources the engine was built with,
so in the demo it checks the fakes and on the Mac it checks the real APIs.

  python3 -m bot.doctor          # prints a table
  POST /api/doctor               # the same list for the control page
"""
from __future__ import annotations

import os
import ssl
import sys
import time
from pathlib import Path
from typing import Any, Callable, Optional

REQUIRED = ("token", "pair", "symbol", "price_usd", "liquidity_usd", "volume_m5", "buys_m5", "sells_m5", "change_m5", "age_min")


def _check(name: str, fn: Callable[[], str]) -> dict[str, Any]:
    started = time.time()
    try:
        detail = fn()
        return {"name": name, "ok": True, "ms": round((time.time() - started) * 1000), "detail": detail}
    except Exception as error:  # noqa: BLE001 - every failure is a finding, not a crash
        return {"name": name, "ok": False, "ms": round((time.time() - started) * 1000),
                "detail": f"{type(error).__name__}: {str(error)[:200]}"}


def _parsed(pairs: list[dict[str, Any]]) -> str:
    if not pairs:
        raise RuntimeError("Antwort leer – nichts zum Prüfen")
    missing = [k for k in REQUIRED if k not in pairs[0]]
    if missing:
        raise RuntimeError("Parser: Felder fehlen: " + ", ".join(missing))
    priced = sum(1 for p in pairs if p.get("price_usd", 0) > 0)
    aged = sum(1 for p in pairs if p.get("age_min") is not None)
    return f"{len(pairs)} Paare, {priced} mit Kurs, {aged} mit Alter · z. B. {pairs[0].get('symbol')} " \
           f"Liq ${pairs[0].get('liquidity_usd', 0):,.0f}"


def run_checks(cfg: dict[str, Any], dex: Any, feeds: dict[str, Any], rug: Any,
               home: Optional[Path] = None) -> list[dict[str, Any]]:
    chains = list(cfg.get("chains") or ["solana"])
    chain = chains[0]
    out: list[dict[str, Any]] = []

    def python() -> str:
        try:
            import certifi  # type: ignore
            ca = "certifi " + certifi.where()
        except Exception:  # noqa: BLE001
            ca = "System-Zertifikate" + ("" if ssl.create_default_context().cert_store_stats()["x509_ca"] else " – KEINE CA geladen")
        return f"Python {sys.version.split()[0]} · {ca}"
    out.append(_check("Python & TLS", python))

    if home is not None:
        def data_dir() -> str:
            home.mkdir(parents=True, exist_ok=True)
            probe = home / ".write-test"
            probe.write_text("ok"); probe.unlink()
            db = home / "bot.sqlite"
            size = db.stat().st_size / 1e6 if db.is_file() else 0
            return f"{home} · beschreibbar · bot.sqlite {size:.1f} MB"
        out.append(_check("Datenverzeichnis", data_dir))

    found: dict[str, list[str]] = {}

    def dex_discovery() -> str:
        nonlocal found
        found = dex.recent_token_addresses(chains)
        n = sum(len(v) for v in found.values())
        if not n:
            raise RuntimeError("keine Token-Adressen in Profilen/Boosts (Feed leer oder blockiert)")
        return f"{n} Tokens · " + ", ".join(f"{c}: {len(v)}" for c, v in found.items())
    out.append(_check("DexScreener – Profile & Boosts", dex_discovery))

    def dex_pairs() -> str:
        addrs = (found.get(chain) or [])[:5]
        if not addrs:
            raise RuntimeError("übersprungen – keine Adressen aus der Discovery")
        return _parsed(dex.pairs_for_tokens(chain, addrs))
    out.append(_check("DexScreener – Paare & Parser", dex_pairs))

    gecko = feeds.get("geckoterminal")
    if gecko is not None:
        def gecko_pools() -> str:
            if hasattr(gecko, "_last"):
                gecko._last.pop(chain, None)          # force a real call, not the cached answer
            items = gecko.discover([chain]).get(chain) or []
            return _parsed([i["snapshot"] for i in items if i.get("snapshot")])
        out.append(_check("GeckoTerminal – neue Pools & Parser", gecko_pools))

    def rugcheck() -> str:
        if "solana" not in chains:
            return "übersprungen – Solana nicht aktiv"
        mint = (found.get("solana") or ["So11111111111111111111111111111111111111112"])[0]
        if hasattr(rug, "_cache"):
            rug._cache.pop(mint, None)
        r = rug.summary(mint)
        if r is None:
            raise RuntimeError("keine Antwort (Rate-Limit, blockiert oder Token unbekannt)")
        return f"{mint[:8]}… Score {r['score']:.0f} · {len(r['danger'])} danger · {len(r['warn'])} warn"
    out.append(_check("RugCheck", rugcheck))

    def ai_key() -> str:
        from .ai import credential_source
        src = credential_source()
        mode = (cfg.get("ai") or {}).get("mode", "off")
        if mode != "off" and src == "none":
            raise RuntimeError(f"KI-Modus „{mode}“ an, aber kein Zugang (kein Schlüssel, kein Profil) – „Mit Claude anmelden“ auf der Steuerseite")
        from .ai import ant_path
        return f"Schlüssel: {src} · Modus {mode}" + ("" if src != "none" else
            (" · anmelden: Knopf „Mit Claude anmelden“ oder „ant auth login“" if ant_path() else " · ohne Schlüssel; Anmeldung braucht die ant-CLI (brew install anthropics/tap/ant)"))
    out.append(_check("Claude-Zugang", ai_key))
    return out


def main() -> int:
    from .main import build, data_dir, load_config
    home = data_dir()
    cfg = load_config(home)
    demo = "--demo" in sys.argv
    engine = build(cfg, home, demo)
    try:
        checks = run_checks(cfg, engine.dex, engine.discovery.feeds, engine.rug, home)
    finally:
        engine.store.close()
    width = max(len(c["name"]) for c in checks)
    for c in checks:
        print(f"{'OK ' if c['ok'] else 'FEHLER'}  {c['name']:<{width}}  {c['ms']:>5} ms  {c['detail']}")
    bad = [c for c in checks if not c["ok"]]
    print(f"\n{len(checks) - len(bad)} von {len(checks)} Prüfungen bestanden." + ("" if not bad else " Fehler oben lesen; die Quellen-Karte auf der Steuerseite zeigt dasselbe."))
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
