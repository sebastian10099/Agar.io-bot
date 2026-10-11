"""Startpunkt: ``python -m gecko_mining [dashboard|run] [--demo]``."""

from __future__ import annotations

import argparse
import logging

from .bot import GeckoMiningBot
from .config import BotConfig
from .data import CoinGeckoClient, SimulatedFeed


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(prog="gecko_mining", description="Gecko-Mining-Bot (Paper-Trading)")
    parser.add_argument("command", nargs="?", default="dashboard", choices=("dashboard", "run"),
                        help="dashboard = Bot + Web-Chart, run = nur Bot (schreibt State-Datei)")
    parser.add_argument("--demo", action="store_true", help="simulierte Kurse statt CoinGecko")
    parser.add_argument("--max-positions", type=int, help="max. gleichzeitig offene Positionen (Standard 10)")
    parser.add_argument("--mode", choices=("reversal", "momentum"))
    parser.add_argument("--poll", type=int, help="Sekunden zwischen den Abfragen")
    parser.add_argument("--iterations", type=int, help="nur fuer 'run': Anzahl Durchlaeufe")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8050)
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    overrides = {}
    if args.mode:
        overrides["mode"] = args.mode
    if args.poll:
        overrides["poll_seconds"] = args.poll
    elif args.demo:
        overrides["poll_seconds"] = 2  # Demo laeuft im Zeitraffer
    cfg = BotConfig.from_env(**overrides)
    if args.max_positions:
        cfg.max_open_positions = args.max_positions
        cfg.validate()

    if args.demo:
        bot = GeckoMiningBot(cfg, feed=SimulatedFeed(cfg.coins))
    else:
        if not cfg.api_key:
            logging.warning("Kein GECKO_API_KEY gesetzt - oeffentliche API mit engem Rate-Limit")
        bot = GeckoMiningBot(cfg, client=CoinGeckoClient(cfg.api_key, cfg.api_plan))

    if args.command == "run":
        bot.run(iterations=args.iterations)
    else:
        from .server import serve
        serve(bot, args.host, args.port)


if __name__ == "__main__":
    main()
