"""Konfiguration fuer den Gecko-Mining-Bot.

Alle Werte koennen per Umgebungsvariable ueberschrieben werden, damit der
API-Key nie im Code landen muss:

    GECKO_API_KEY       CoinGecko API-Key (Demo- oder Pro-Key)
    GECKO_API_PLAN      "demo" (Standard) oder "pro"
    GECKO_COINS         Kommagetrennte Coin-IDs, z.B. "bitcoin,kaspa,monero"
    GECKO_MAX_POSITIONS Maximale Anzahl gleichzeitig offener Positionen
"""

from __future__ import annotations

import dataclasses
import os
from typing import Tuple

# Typische Mining-Coins (Proof-of-Work) als Startliste.
DEFAULT_COINS: Tuple[str, ...] = (
    "bitcoin",
    "litecoin",
    "monero",
    "kaspa",
    "ethereum-classic",
    "dogecoin",
    "ravencoin",
    "zcash",
    "bitcoin-cash",
    "dash",
)


@dataclasses.dataclass
class BotConfig:
    # --- Datenquelle -------------------------------------------------------
    api_key: str = ""
    api_plan: str = "demo"  # "demo" -> api.coingecko.com, "pro" -> pro-api.coingecko.com
    vs_currency: str = "usd"
    coins: Tuple[str, ...] = DEFAULT_COINS
    candle_minutes: int = 1  # Kerzengroesse in Minuten
    history_minutes: int = 120  # wie viele Minuten Kursverlauf geladen/angezeigt werden

    # --- Bewegungserkennung -----------------------------------------------
    # Zeitfenster (Minuten), in denen ein Anstieg "von unten nach oben" bzw.
    # ein Fall "von oben nach unten" gemessen wird.
    windows_minutes: Tuple[int, ...] = (6, 8, 20, 60)
    # Mindest-Bewegung in Prozent je Fenster (gleiche Reihenfolge wie oben).
    # Laengere Fenster brauchen groessere Bewegungen, um als Pump/Dump zu zaehlen.
    move_threshold_pct: Tuple[float, ...] = (1.5, 2.0, 3.0, 5.0)
    # "reversal": nach Pump shorten, nach Dump long (Gegenbewegung handeln)
    # "momentum": Anstieg long mitnehmen, Fall shorten (mit dem Trend)
    mode: str = "reversal"
    allow_long: bool = True
    allow_short: bool = True
    # Bei "reversal" erst einsteigen, wenn die letzte Kerze gegen die Bewegung
    # schliesst (z.B. rote Kerze nach Pump) - verhindert Short in den Pump hinein.
    require_confirmation: bool = True

    # --- Positionen -------------------------------------------------------
    max_open_positions: int = 10
    max_positions_per_coin: int = 2
    position_size_usd: float = 100.0
    # Puffer ueber 10 x 100 $, damit nach ersten Verlusten weiterhin 10 Positionen moeglich sind.
    starting_capital_usd: float = 2000.0
    take_profit_pct: float = 3.0
    stop_loss_pct: float = 1.5
    max_hold_minutes: int = 120
    fee_pct: float = 0.1  # pro Seite (Ein- und Ausstieg)

    # --- Laufzeit ---------------------------------------------------------
    poll_seconds: int = 60
    state_file: str = "gecko_state.json"

    def validate(self) -> None:
        if len(self.windows_minutes) != len(self.move_threshold_pct):
            raise ValueError("windows_minutes und move_threshold_pct muessen gleich lang sein")
        if self.mode not in ("reversal", "momentum"):
            raise ValueError("mode muss 'reversal' oder 'momentum' sein")
        if self.api_plan not in ("demo", "pro"):
            raise ValueError("api_plan muss 'demo' oder 'pro' sein")
        if self.max_open_positions < 1:
            raise ValueError("max_open_positions muss mindestens 1 sein")
        if self.max_positions_per_coin < 1:
            raise ValueError("max_positions_per_coin muss mindestens 1 sein")
        if self.candle_minutes < 1:
            raise ValueError("candle_minutes muss mindestens 1 sein")
        if self.stop_loss_pct <= 0 or self.take_profit_pct <= 0:
            raise ValueError("stop_loss_pct und take_profit_pct muessen > 0 sein")

    @classmethod
    def from_env(cls, **overrides) -> "BotConfig":
        cfg = cls(**overrides)
        cfg.api_key = os.environ.get("GECKO_API_KEY", cfg.api_key)
        cfg.api_plan = os.environ.get("GECKO_API_PLAN", cfg.api_plan)
        coins = os.environ.get("GECKO_COINS")
        if coins:
            cfg.coins = tuple(c.strip() for c in coins.split(",") if c.strip())
        max_pos = os.environ.get("GECKO_MAX_POSITIONS")
        if max_pos:
            cfg.max_open_positions = int(max_pos)
        cfg.validate()
        return cfg
