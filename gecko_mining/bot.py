"""Bot-Schleife: Kurse holen -> Kerzen bauen -> Exits pruefen -> Signale handeln."""

from __future__ import annotations

import json
import logging
import os
import tempfile
import time
from typing import Callable, Dict, List, Optional

from .config import BotConfig
from .data import Candle, CoinGeckoClient, CoinGeckoError, SimulatedFeed, TickStore, build_candles
from .positions import PositionManager
from .strategy import Signal, analyze, generate_signal

log = logging.getLogger("gecko_mining")


class GeckoMiningBot:
    def __init__(self, cfg: BotConfig, client: Optional[CoinGeckoClient] = None,
                 feed: Optional[SimulatedFeed] = None, clock: Optional[Callable[[], float]] = None):
        cfg.validate()
        self.cfg = cfg
        self.client = client
        self.feed = feed
        self.clock = clock or (feed.clock if feed is not None else time.time)
        self.store = TickStore(keep_seconds=cfg.history_minutes * 60)
        self.positions = PositionManager(cfg)
        self.signals: List[dict] = []  # Verlauf der letzten Signale (auch abgelehnte)
        self.last_error = ""
        self.last_update = 0.0
        self._last_signal_candle: Dict[str, float] = {}

    @property
    def candle_seconds(self) -> int:
        return self.cfg.candle_minutes * 60

    # --- Daten ---------------------------------------------------------
    def seed_history(self) -> None:
        """Startet mit Kursverlauf, damit Chart und Fenster sofort gefuellt sind."""
        if self.feed is not None:
            for coin, ticks in self.feed.history(self.cfg.history_minutes).items():
                self.store.extend(coin, ticks)
            return
        now = self.clock()
        if self.client is None:
            return
        cutoff = now - self.cfg.history_minutes * 60
        for coin in self.cfg.coins:
            try:
                ticks = self.client.recent_ticks(coin, self.cfg.vs_currency)
            except CoinGeckoError as exc:
                self.last_error = f"{coin}: {exc}"
                log.warning("History fuer %s fehlgeschlagen: %s", coin, exc)
                continue
            self.store.extend(coin, [t for t in ticks if t[0] >= cutoff])

    def fetch_prices(self) -> Dict[str, float]:
        if self.feed is not None:
            return self.feed.step()
        if self.client is None:
            return {}
        return self.client.simple_prices(self.cfg.coins, self.cfg.vs_currency)

    def candles(self, coin: str) -> List[Candle]:
        return build_candles(self.store.ticks(coin), self.candle_seconds)

    def last_prices(self) -> Dict[str, float]:
        return {c: p for c in self.store.coins() if (p := self.store.last_price(c)) is not None}

    # --- Ein Durchlauf -------------------------------------------------
    def step(self, prices: Optional[Dict[str, float]] = None) -> List[dict]:
        """Ein Bot-Durchlauf. Gibt die Ereignisse (Eroeffnungen/Schliessungen) zurueck."""
        if prices is None:
            try:
                prices = self.fetch_prices()
                self.last_error = ""
            except CoinGeckoError as exc:
                self.last_error = str(exc)
                log.warning("Kursabfrage fehlgeschlagen: %s", exc)
                return []
        now = self.clock()
        for coin, price in prices.items():
            self.store.add(coin, now, price)
        self.last_update = now

        events: List[dict] = []
        for coin in prices:
            candles = self.candles(coin)
            if not candles:
                continue
            last = candles[-1]
            for pos in self.positions.check_exits(coin, last.high, last.low, last.close, now):
                events.append({"type": "close", "position": pos.to_dict(fee_pct=self.cfg.fee_pct)})
            signal = generate_signal(coin, candles, self.cfg)
            if signal is None:
                continue
            # Pro Kerze nur ein Signal je Coin, sonst oeffnet jeder Poll eine neue Position.
            if self._last_signal_candle.get(coin) == last.ts:
                continue
            self._last_signal_candle[coin] = last.ts
            events.append(self._handle_signal(signal))
        return events

    def _handle_signal(self, signal: Signal) -> dict:
        entry = signal.to_dict()
        why_not = self.positions.can_open(signal)
        if why_not:
            entry["status"] = f"abgelehnt: {why_not}"
            event = {"type": "skip", "signal": entry}
        else:
            pos = self.positions.open(signal)
            entry["status"] = f"eroeffnet #{pos.id}"
            event = {"type": "open", "position": pos.to_dict(signal.price), "signal": entry}
            log.info("%s %s @ %.6g (%s)", signal.side.upper(), signal.coin, signal.price, signal.reason)
        self.signals.append(entry)
        del self.signals[:-50]
        return event

    # --- Zustand fuer das Dashboard -----------------------------------
    def snapshot(self) -> dict:
        prices = self.last_prices()
        fee = self.cfg.fee_pct
        coins = {}
        for coin in self.cfg.coins:
            candles = self.candles(coin)
            coins[coin] = {
                "price": prices.get(coin),
                "candles": [c.to_dict() for c in candles],
                "moves": [m.to_dict() for m in analyze(candles, self.cfg)],
            }
        open_pos = self.positions.open_positions()
        return {
            "updated": self.last_update,
            "error": self.last_error,
            "mode": self.cfg.mode,
            "candle_minutes": self.cfg.candle_minutes,
            "windows_minutes": list(self.cfg.windows_minutes),
            "max_open_positions": self.cfg.max_open_positions,
            "equity": round(self.positions.equity(prices), 2),
            "realized_pnl": round(self.positions.realized_pnl, 2),
            "coins": coins,
            "open_positions": [p.to_dict(prices.get(p.coin), fee) for p in open_pos],
            "closed_positions": [p.to_dict(fee_pct=fee) for p in self.positions.closed_positions()[-30:]],
            "signals": list(reversed(self.signals[-20:])),
        }

    def write_state(self, path: Optional[str] = None) -> None:
        """Schreibt den Zustand atomar, damit das Dashboard nie halbe Dateien liest."""
        path = path or self.cfg.state_file
        directory = os.path.dirname(os.path.abspath(path))
        fd, tmp = tempfile.mkstemp(dir=directory, suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(self.snapshot(), fh)
        os.replace(tmp, path)

    def run(self, iterations: Optional[int] = None, sleep: Callable[[float], None] = time.sleep) -> None:
        self.seed_history()
        done = 0
        while iterations is None or done < iterations:
            for event in self.step():
                log.info("%s", event)
            self.write_state()
            done += 1
            if iterations is None or done < iterations:
                sleep(self.cfg.poll_seconds)
