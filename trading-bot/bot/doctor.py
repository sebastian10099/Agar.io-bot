"""Self-test: is everything this bot depends on reachable, and do the live
answers still parse? Runs against whatever sources the engine was built with,
so in the demo it checks the fakes and on the Mac it checks the real APIs.

  python3 -m bot.doctor          # prints a table
  POST /api/doctor               # the same list for the control page
"""
from __future__ import annotations

import ssl
import sys
import time
from pathlib import Path
from typing import Any, Callable, Optional

REQUIRED = ("token", "pair", "symbol", "price_usd", "liquidity_usd", "volume_m5", "buys_m5", "sells_m5", "change_m5", "age_min")


class Degraded(Exception):
    """Not working, but something else covers for it: a note, not a failure."""


def _check(name: str, fn: Callable[[], str]) -> dict[str, Any]:
    started = time.time()
    try:
        detail = fn()
        return {"name": name, "ok": True, "ms": round((time.time() - started) * 1000), "detail": detail}
    except Degraded as note:
        return {"name": name, "ok": True, "warn": True, "ms": round((time.time() - started) * 1000), "detail": str(note)[:300]}
    except Exception as error:  # noqa: BLE001 - every failure is a finding, not a crash
        if "HTTP 429" in str(error):
            # the source is up and only wants to be asked less often (in operation the bot does)
            return {"name": name, "ok": True, "warn": True, "ms": round((time.time() - started) * 1000),
                    "detail": "Rate-Limit (HTTP 429): die Quelle antwortet, will aber seltener gefragt werden – "
                              "im Betrieb fragt der Bot sie gedrosselt; Selbsttest in einer Minute wiederholen"}
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
    first = pairs[0]
    liq = (f"Liq ${first.get('liquidity_usd', 0):,.0f}" if first.get("liquidity_kind", "reported") == "reported"
           else f"Bonding-Kurve ({first.get('dex')}), Liquidität "
                + ("aus dem Kurven-Konto auf der Chain" if first.get("dex") in ("pumpfun", "pump-fun") else "unbekannt"))
    return f"{len(pairs)} Paare, {priced} mit Kurs, {aged} mit Alter · z. B. {first.get('symbol')} {liq}"


def run_checks(cfg: dict[str, Any], dex: Any, feeds: dict[str, Any], rug: Any,
               home: Optional[Path] = None, curves: Any = None) -> list[dict[str, Any]]:
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

    if hasattr(dex, "prices"):
        def dex_batch() -> str:
            addrs = (found.get(chain) or [])[:8]
            pairs = [p["pair"] for p in dex.pairs_for_tokens(chain, addrs)] if addrs else []
            if len(pairs) < 2:
                raise RuntimeError("übersprungen – weniger als zwei Paare zum Prüfen")
            got = dex.prices(chain, pairs[:5])
            if not got:
                raise RuntimeError("Sammelabfrage lieferte keinen Kurs – Endpunkt geändert?")
            return f"{len(got)} von {min(5, len(pairs))} Paaren in einer Abfrage bepreist"
        out.append(_check("DexScreener – Sammelkurse (Tracker)", dex_batch))

    gecko = feeds.get("geckoterminal")
    if gecko is not None:
        def gecko_pools() -> str:
            if hasattr(gecko, "_last"):
                gecko._last.pop(chain, None)          # force a real call, not the cached answer (a 429 pause stays)
            items = gecko.discover([chain]).get(chain) or []
            return _parsed([i["snapshot"] for i in items if i.get("snapshot")])
        out.append(_check("GeckoTerminal – neue Pools & Parser", gecko_pools))

    pump = feeds.get("pumpfun")
    if pump is not None:
        def pump_coins() -> str:
            if hasattr(pump, "_last"):
                pump._last = None
            items = pump.discover(["solana"]).get("solana") or []
            if not items:
                raise RuntimeError("pump.fun meldet keine Coins (Feed leer oder blockiert)")
            aged = sum(1 for i in items if (i.get("snapshot") or {}).get("age_min") is not None)
            return f"{len(items)} Coins, {aged} mit Alter · z. B. {(items[0].get('snapshot') or {}).get('symbol')}"
        out.append(_check("pump.fun – neue Coins", pump_coins))

    def rugcheck() -> str:
        if "solana" not in chains:
            return "übersprungen – Solana nicht aktiv"
        rc = getattr(rug, "rugcheck", rug)           # RugCheck alone, never the fallback behind it
        mint = (found.get("solana") or ["So11111111111111111111111111111111111111112"])[0]
        if hasattr(rc, "_cache"):
            rc._cache.pop(mint, None)
        if hasattr(rc, "_paused_until"):
            rc._paused_until = 0.0
        r = rc.summary(mint)
        if r is None:
            why = getattr(rc, "last_error", "") or "Rate-Limit, blockiert oder Token unbekannt"
            if getattr(rug, "onchain", None) is not None:
                # covered by the own check: a note, unless that one fails too (next row)
                raise Degraded(f"keine Antwort – {why} – die Eigenprüfung über Solana-RPC springt ein (nächste Zeile)")
            raise RuntimeError(f"keine Antwort – {why}")
        return f"{mint[:8]}… Score {r['score']:.0f} · {len(r['danger'])} danger · {len(r['warn'])} warn"
    out.append(_check("RugCheck", rugcheck))

    onchain = getattr(rug, "onchain", None)
    if onchain is not None:
        def own_check() -> str:
            if "solana" not in chains:
                return "übersprungen – Solana nicht aktiv"
            mint = (found.get("solana") or ["EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"])[0]
            onchain._cache.pop(mint, None)
            r = onchain.summary(mint)
            if r is None:
                raise RuntimeError(f"keine Antwort – {onchain.last_error or 'RPC nicht erreichbar'}")
            h = r.get("holders")
            line = (f"{mint[:8]}… · {len(r['danger'])} Gefahr · {len(r['warn'])} Warnung · {r.get('program')}"
                    + (f" · größte Wallet {h['top1']:.1f} %, Top 10 {h['top10']:.1f} %, Programme {h['programs']:.1f} %" if h else "")
                    + " – springt ein, wenn RugCheck nicht antwortet")
            if h is None:
                raise Degraded(line + " – die Halter-Abfrage (getTokenLargestAccounts) bekam keine Antwort")
            return line
        out.append(_check("Eigenprüfung über Solana-RPC (Ersatz für RugCheck)", own_check))

    if curves is not None and hasattr(curves, "read"):
        def curve_reserves() -> str:
            if "solana" not in chains:
                return "übersprungen – Solana nicht aktiv"
            accounts: list[str] = []
            pump_feed = feeds.get("pumpfun")
            if pump_feed is not None and getattr(pump_feed, "_last", None):
                accounts = [c["pair"] for c in pump_feed._last[1] if c.get("pair") and c["pair"] != c.get("token")][:5]
            if not accounts:
                pairs = dex.pairs_for_tokens("solana", (found.get("solana") or [])[:30]) if found.get("solana") else []
                accounts = [p["pair"] for p in pairs if p.get("dex") in ("pumpfun", "pump-fun")][:5]
            if not accounts:
                return "übersprungen – gerade keine pump.fun-Kurve in den Quellen"
            states = curves.read(accounts)
            if not states:
                raise RuntimeError(f"keine Kurve gelesen – {getattr(curves, 'last_error', '') or 'Konten nicht gefunden'}")
            st = next(iter(states.values()))
            return (f"{len(states)} von {len(accounts)} Kurven gelesen · z. B. {st['virtual_tokens'] / 1e6:,.0f} Mio. "
                    f"virtuelle Tokens{' · abgeschlossen' if st['complete'] else ''} – liefert die Liquidität der Kurven-Coins")
        out.append(_check("pump.fun-Kurven (Solana-RPC)", curve_reserves))

    def sdk() -> str:
        from .preflight import sdk_version
        ai = cfg.get("ai") or {}
        needed = ai.get("mode", "off") != "off" and ai.get("provider", "anthropic") == "anthropic"
        v = sdk_version()
        if v:
            return f"anthropic {v}"
        if needed:
            raise RuntimeError("Anthropic-SDK fehlt, der KI-Modus mit Claude braucht es – der nächste Start über die App oder launch.sh installiert es (pip install --user anthropic)")
        # without the Claude mode nothing uses the SDK: not a fault, just a note
        return "nicht installiert – nur für den KI-Modus mit Claude nötig, wird beim nächsten Start nachinstalliert"
    out.append(_check("Anthropic-SDK", sdk))

    def ai_key() -> str:
        from .ai import credential_source, openrouter_source
        provider = (cfg.get("ai") or {}).get("provider", "anthropic")
        mode = (cfg.get("ai") or {}).get("mode", "off")
        if provider == "openrouter":
            src = openrouter_source()
            if mode != "off" and src == "none":
                raise RuntimeError(f"KI-Modus „{mode}“ mit OpenRouter, aber kein Schlüssel – unten im KI-Bereich speichern (kostenlos auf openrouter.ai)")
            return f"OpenRouter-Schlüssel: {src} · Modus {mode}"
        src = credential_source()
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
        checks = run_checks(cfg, engine.dex, engine.discovery.feeds, engine.rug, home, engine.curves)
    finally:
        engine.store.close()
    width = max(len(c["name"]) for c in checks)
    for c in checks:
        mark = "FEHLER" if not c["ok"] else "HINWEIS" if c.get("warn") else "OK "
        print(f"{mark}  {c['name']:<{width}}  {c['ms']:>5} ms  {c['detail']}")
    bad = [c for c in checks if not c["ok"]]
    notes = [c for c in checks if c.get("warn")]
    print(f"\n{len(checks) - len(bad)} von {len(checks)} Prüfungen bestanden"
          + (f", {len(notes)} mit Hinweis" if notes else "") + "."
          + ("" if not bad else " Fehler oben lesen; die Quellen-Karte auf der Steuerseite zeigt dasselbe."))
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
