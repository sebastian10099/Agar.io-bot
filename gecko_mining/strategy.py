"""Erkennung von Anstiegen/Faellen in den letzten 6, 8, 20, 60 Minuten.

Pro Zeitfenster wird geschaut, ob der Kurs innerhalb des Fensters von seinem
Tief bis zu seinem Hoch gelaufen ist (Tief *vor* Hoch = Anstieg / Pump) oder
umgekehrt vom Hoch bis zum Tief (Hoch *vor* Tief = Fall / Dump). Ueberschreitet
die Bewegung die Schwelle des Fensters, entsteht ein Signal:

* mode="reversal": nach Pump -> SHORT, nach Dump -> LONG
* mode="momentum": Pump -> LONG, Dump -> SHORT
"""

from __future__ import annotations

import dataclasses
from typing import List, Optional, Sequence

from .config import BotConfig
from .data import Candle

LONG = "long"
SHORT = "short"


@dataclasses.dataclass(frozen=True)
class Move:
    window_minutes: int
    direction: str  # "up" oder "down"
    move_pct: float  # Groesse der Bewegung Tief->Hoch bzw. Hoch->Tief in %
    threshold_pct: float
    retrace_pct: float  # wie viel der Bewegung der aktuelle Kurs schon zurueckgegeben hat (0-100+)
    start_price: float
    extreme_price: float

    @property
    def strength(self) -> float:
        return self.move_pct / self.threshold_pct if self.threshold_pct else 0.0

    @property
    def triggered(self) -> bool:
        return self.move_pct >= self.threshold_pct

    def to_dict(self) -> dict:
        return dataclasses.asdict(self) | {"triggered": self.triggered}


@dataclasses.dataclass(frozen=True)
class Signal:
    coin: str
    side: str
    price: float
    ts: float
    move: Move

    @property
    def reason(self) -> str:
        up = self.move.direction == "up"
        label, sign = ("Anstieg", "+") if up else ("Fall", "-")
        return f"{label} {sign}{self.move.move_pct:.2f}% in {self.move.window_minutes} min"

    def to_dict(self) -> dict:
        return {"coin": self.coin, "side": self.side, "price": self.price, "ts": self.ts,
                "reason": self.reason, "move": self.move.to_dict()}


def measure_window(candles: Sequence[Candle], window_candles: int, window_minutes: int, threshold_pct: float) -> Optional[Move]:
    """Misst die dominante Bewegung in den letzten ``window_candles`` Kerzen."""
    if window_candles < 2 or len(candles) < 2:
        return None
    recent = list(candles[-window_candles:])
    lows = [c.low for c in recent]
    highs = [c.high for c in recent]
    low_i = min(range(len(recent)), key=lambda i: lows[i])
    high_i = max(range(len(recent)), key=lambda i: highs[i])
    low, high = lows[low_i], highs[high_i]
    if low <= 0 or high <= low:
        return None
    close = recent[-1].close
    if low_i < high_i:
        # Tief zuerst, dann Hoch -> Anstieg
        move = (high - low) / low * 100
        retrace = (high - close) / (high - low) * 100
        return Move(window_minutes, "up", move, threshold_pct, retrace, low, high)
    if high_i < low_i:
        move = (high - low) / high * 100
        retrace = (close - low) / (high - low) * 100
        return Move(window_minutes, "down", move, threshold_pct, retrace, high, low)
    # Hoch und Tief in derselben Kerze: Richtung aus der Kerzenfarbe
    candle = recent[high_i]
    if candle.is_green:
        return Move(window_minutes, "up", (high - low) / low * 100, threshold_pct,
                    (high - close) / (high - low) * 100, low, high)
    return Move(window_minutes, "down", (high - low) / high * 100, threshold_pct,
                (close - low) / (high - low) * 100, high, low)


def analyze(candles: Sequence[Candle], cfg: BotConfig) -> List[Move]:
    """Bewegungen fuer alle konfigurierten Fenster (auch die ohne Signal)."""
    moves = []
    for minutes, threshold in zip(cfg.windows_minutes, cfg.move_threshold_pct):
        n = max(2, -(-minutes // cfg.candle_minutes))  # aufrunden
        move = measure_window(candles, n, minutes, threshold)
        if move is not None:
            moves.append(move)
    return moves


def _side_for(move: Move, cfg: BotConfig) -> str:
    if cfg.mode == "reversal":
        return SHORT if move.direction == "up" else LONG
    return LONG if move.direction == "up" else SHORT


def _confirmed(move: Move, last: Candle, side: str, cfg: BotConfig) -> bool:
    if cfg.mode == "reversal":
        if not cfg.require_confirmation:
            return True
        # Short erst, wenn nach dem Pump eine rote Kerze kommt; Long erst nach gruener Kerze.
        if side == SHORT and last.is_green:
            return False
        if side == LONG and not last.is_green:
            return False
        # Zu spaet: Gegenbewegung schon groesstenteils gelaufen.
        return move.retrace_pct <= 60
    # momentum: Bewegung muss noch intakt sein (nicht mehr als 1/3 zurueckgegeben).
    return move.retrace_pct <= 33


def generate_signal(coin: str, candles: Sequence[Candle], cfg: BotConfig) -> Optional[Signal]:
    """Staerkstes ausgeloestes Fenster -> ein Signal (oder None)."""
    if len(candles) < 2:
        return None
    last = candles[-1]
    best: Optional[Signal] = None
    for move in analyze(candles, cfg):
        if not move.triggered:
            continue
        side = _side_for(move, cfg)
        if side == LONG and not cfg.allow_long:
            continue
        if side == SHORT and not cfg.allow_short:
            continue
        if not _confirmed(move, last, side, cfg):
            continue
        if best is None or move.strength > best.move.strength:
            best = Signal(coin, side, last.close, last.ts, move)
    return best
