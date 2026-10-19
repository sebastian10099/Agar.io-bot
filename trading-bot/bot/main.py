#!/usr/bin/env python3
"""Entry point.

  python3 -m bot.main            paper mode against the live market
  python3 -m bot.main --demo     offline demo with simulated prices
  python3 -m bot.main --once     one polling cycle, then exit (for checks)
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import signal
import sys
import threading
import time
import webbrowser
from pathlib import Path
from typing import Any

from .engine import Engine
from .server import make_server
from .store import Store

HERE = Path(__file__).parent


def data_dir() -> Path:
    override = os.environ.get("NEW_TOKEN_BOT_HOME")
    if override:
        return Path(override)
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "NewTokenBot"
    return Path.home() / ".new-token-bot"


def _write_atomic(path: Path, text: str) -> None:
    """Write via a temp file and rename, so a crash mid-write never leaves half a file."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def _read_user_config(user: Path) -> dict[str, Any]:
    """The user's config.json, or {} if it is missing or unreadable. A broken file
    is kept as config.json.kaputt-<time> and replaced, so the bot still starts."""
    if not user.is_file():
        return {}
    try:
        data = json.loads(user.read_text())
        if not isinstance(data, dict):
            raise ValueError("kein JSON-Objekt")
        return data
    except (ValueError, UnicodeDecodeError) as error:
        backup = user.with_name(f"config.json.kaputt-{int(time.time())}")
        try:
            os.replace(user, backup)
        except OSError:
            backup = user
        print(f"Warnung: {user} war nicht lesbar ({error}); gesichert als {backup.name}, starte mit Standardwerten.")
        return {}


def load_config(home: Path) -> dict[str, Any]:
    from . import settings

    defaults = json.loads((HERE / "config.json").read_text())
    cfg = copy.deepcopy(defaults)
    user = home / "config.json"
    override = _read_user_config(user)
    for key, value in override.items():
        if key.startswith("_"):
            continue
        if isinstance(value, dict) and isinstance(cfg.get(key), dict):
            cfg[key].update(value)
        else:
            cfg[key] = value

    # every value the form could set goes through the form's own validation
    dropped = []
    for entry in settings.SCHEMA:
        path = entry["path"]
        value = settings.get_path(cfg, path)
        if value == settings.get_path(defaults, path):
            continue
        clean, errors = settings.validate({path: value})
        if errors:
            settings.set_path(cfg, path, settings.get_path(defaults, path))
            dropped.append(f"{path}={value!r} ({errors[path]})")
        else:
            settings.set_path(cfg, path, clean[path])
    for path in settings.cross_check(cfg):
        settings.set_path(cfg, path, settings.get_path(defaults, path))
        dropped.append(f"{path} (passt nicht zum Gegenwert)")
    try:
        bankroll = float(cfg.get("bankroll_usd"))
        if not 10 <= bankroll <= 1e9:
            raise ValueError
        cfg["bankroll_usd"] = bankroll
    except (TypeError, ValueError):
        cfg["bankroll_usd"] = defaults["bankroll_usd"]
        dropped.append("bankroll_usd")
    if dropped:
        print("Warnung: ungültige Werte in config.json ignoriert, Standard genommen: " + "; ".join(dropped))
    cfg["_dropped"] = dropped

    if not user.is_file():
        home.mkdir(parents=True, exist_ok=True)
        _write_atomic(user, json.dumps({"_hint": "Werte hier ueberschreiben, Rest kommt aus bot/config.json"}, indent=2))
    return cfg


def persist_to(home: Path):
    """Write validated changes into the user's config.json, nested like the
    bundled file, so the next start picks them up."""
    from .settings import set_path

    def save(clean: dict[str, Any]) -> None:
        user = home / "config.json"
        current = _read_user_config(user)
        current.pop("_hint", None)
        for path, value in clean.items():
            set_path(current, path, value)
        _write_atomic(user, json.dumps(current, indent=2, ensure_ascii=False) + "\n")

    return save


PORT_TRIES = 10


def bind_server(engine: Engine, host: str, port: int, tries: int = PORT_TRIES, factory=None):
    """Bind the dashboard on `port` or the next free one. Another program on
    the port (Local Studio and friends like 8765 too) must not stop the bot."""
    factory = factory or make_server
    for candidate in range(port, port + tries):
        try:
            return factory(engine, host, candidate), candidate
        except OSError as error:
            print(f"Port {candidate} belegt ({error.strerror or error}), versuche {candidate + 1}")
    return None, port


def build(cfg: dict[str, Any], home: Path, demo: bool) -> Engine:
    store = Store(home / ("demo.sqlite" if demo else "bot.sqlite"))
    if demo:
        from .demo import FakeDex, FakeRug, demo_feeds, fast_clock
        dex = FakeDex()
        return Engine(cfg, store, dex, FakeRug(), clock=fast_clock(dex), feeds=demo_feeds(dex))
    from .discovery import DexScreenerFeed
    from .sources.dexscreener import DexScreener
    from .sources.geckoterminal import GeckoTerminal
    from .sources.pumpfun import PumpFun
    from .sources.rugcheck import RugCheck
    dex = DexScreener()
    return Engine(cfg, store, dex, RugCheck(),
                  feeds={"dexscreener": DexScreenerFeed(dex), "geckoterminal": GeckoTerminal(), "pumpfun": PumpFun()})


def main(argv: list[str] = None) -> int:
    ap = argparse.ArgumentParser(description="New-token trading bot (paper first)")
    ap.add_argument("--demo", action="store_true", help="offline demo with simulated market")
    ap.add_argument("--once", action="store_true", help="run one poll and exit")
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--no-open", action="store_true", help="do not open the browser")
    args = ap.parse_args(argv)

    home = data_dir()
    cfg = load_config(home)
    if args.demo:
        cfg["poll_seconds"] = 3

    if cfg.get("mode") != "paper":
        print("mode muss 'paper' sein. Echtgeld-Ausfuehrung ist nicht enthalten (siehe bot/live.py).")
        return 2

    dropped = cfg.pop("_dropped", [])
    engine = build(cfg, home, args.demo)
    engine.persist = persist_to(home)
    if dropped:
        engine.store.log("warn", "config.json: ungültige Werte ignoriert, Standard genommen: " + "; ".join(dropped))
    engine.home = home
    engine.demo = args.demo

    if args.once:
        counts = engine.poll_once()
        print(json.dumps(counts))
        return 0

    host = cfg["dashboard"]["host"]
    port = args.port or int(cfg["dashboard"]["port"])
    server, port = bind_server(engine, host, port)
    if server is None:
        print(f"Kein freier Port zwischen {port} und {port + PORT_TRIES - 1} auf {host}.")
        return 3
    threading.Thread(target=server.serve_forever, daemon=True, name="dashboard").start()
    thread = threading.Thread(target=engine.run, daemon=True, name="engine")
    thread.start()

    url = f"http://{host}:{port}/"
    print(f"Dashboard: {url}   (Daten in {home})   Ctrl+C beendet.")
    if not args.no_open:
        webbrowser.open(url)

    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    while not stop.is_set() and thread.is_alive():
        stop.wait(0.5)
    engine.stop()
    server.shutdown()
    thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
