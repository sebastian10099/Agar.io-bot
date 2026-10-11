"""Paper-Trading-Positionen (Long und Short) mit Limit auf offene Positionen."""

from __future__ import annotations

import dataclasses
import itertools
from typing import Dict, List, Optional

from .config import BotConfig
from .strategy import LONG, SHORT, Signal


@dataclasses.dataclass
class Position:
    id: int
    coin: str
    side: str
    entry_price: float
    quantity: float
    opened_ts: float
    stop_loss: float
    take_profit: float
    reason: str = ""
    exit_price: Optional[float] = None
    closed_ts: Optional[float] = None
    exit_reason: str = ""

    @property
    def is_open(self) -> bool:
        return self.exit_price is None

    @property
    def notional(self) -> float:
        return self.entry_price * self.quantity

    def pnl(self, price: float, fee_pct: float = 0.0) -> float:
        direction = 1 if self.side == LONG else -1
        gross = (price - self.entry_price) * self.quantity * direction
        fees = (self.entry_price + price) * self.quantity * fee_pct / 100
        return gross - fees

    def pnl_pct(self, price: float, fee_pct: float = 0.0) -> float:
        return self.pnl(price, fee_pct) / self.notional * 100 if self.notional else 0.0

    def to_dict(self, price: Optional[float] = None, fee_pct: float = 0.0) -> dict:
        d = dataclasses.asdict(self)
        mark = self.exit_price if self.exit_price is not None else price
        if mark is not None:
            d["mark_price"] = mark
            d["pnl"] = round(self.pnl(mark, fee_pct), 4)
            d["pnl_pct"] = round(self.pnl_pct(mark, fee_pct), 3)
        return d


class PositionManager:
    def __init__(self, cfg: BotConfig):
        self.cfg = cfg
        self.positions: List[Position] = []
        self.realized_pnl = 0.0
        self._ids = itertools.count(1)

    # --- Abfragen --------------------------------------------------------
    def open_positions(self, coin: Optional[str] = None) -> List[Position]:
        return [p for p in self.positions if p.is_open and (coin is None or p.coin == coin)]

    def closed_positions(self) -> List[Position]:
        return [p for p in self.positions if not p.is_open]

    def free_slots(self) -> int:
        return max(0, self.cfg.max_open_positions - len(self.open_positions()))

    def margin_in_use(self) -> float:
        return sum(p.notional for p in self.open_positions())

    def equity(self, prices: Dict[str, float]) -> float:
        unrealized = sum(p.pnl(prices.get(p.coin, p.entry_price), self.cfg.fee_pct) for p in self.open_positions())
        return self.cfg.starting_capital_usd + self.realized_pnl + unrealized

    def can_open(self, signal: Signal) -> Optional[str]:
        """``None`` wenn eroeffnet werden darf, sonst der Grund dagegen."""
        if self.free_slots() <= 0:
            return f"Maximum von {self.cfg.max_open_positions} offenen Positionen erreicht"
        same_coin = self.open_positions(signal.coin)
        if len(same_coin) >= self.cfg.max_positions_per_coin:
            return f"Maximum von {self.cfg.max_positions_per_coin} Positionen fuer {signal.coin} erreicht"
        if any(p.side != signal.side for p in same_coin):
            return f"Gegenposition auf {signal.coin} offen"
        available = self.cfg.starting_capital_usd + self.realized_pnl - self.margin_in_use()
        if available < self.cfg.position_size_usd:
            return "Nicht genug freies Kapital"
        if signal.price <= 0:
            return "Ungueltiger Preis"
        return None

    # --- Aktionen --------------------------------------------------------
    def open(self, signal: Signal) -> Position:
        why_not = self.can_open(signal)
        if why_not:
            raise ValueError(why_not)
        price = signal.price
        sl, tp = self.cfg.stop_loss_pct / 100, self.cfg.take_profit_pct / 100
        if signal.side == LONG:
            stop, target = price * (1 - sl), price * (1 + tp)
        else:
            stop, target = price * (1 + sl), price * (1 - tp)
        pos = Position(
            id=next(self._ids), coin=signal.coin, side=signal.side, entry_price=price,
            quantity=self.cfg.position_size_usd / price, opened_ts=signal.ts,
            stop_loss=stop, take_profit=target, reason=signal.reason,
        )
        self.positions.append(pos)
        return pos

    def close(self, pos: Position, price: float, ts: float, reason: str) -> float:
        if not pos.is_open:
            raise ValueError(f"Position {pos.id} ist bereits geschlossen")
        pos.exit_price, pos.closed_ts, pos.exit_reason = price, ts, reason
        pnl = pos.pnl(price, self.cfg.fee_pct)
        self.realized_pnl += pnl
        return pnl

    def check_exits(self, coin: str, high: float, low: float, close: float, ts: float) -> List[Position]:
        """Prueft Stop-Loss / Take-Profit / Haltedauer gegen die letzte Kerze.

        Liegen SL und TP beide in der Kerze, wird konservativ der Stop-Loss
        angenommen.
        """
        closed = []
        for pos in self.open_positions(coin):
            if pos.side == LONG:
                hit_sl, hit_tp = low <= pos.stop_loss, high >= pos.take_profit
            else:
                hit_sl, hit_tp = high >= pos.stop_loss, low <= pos.take_profit
            if hit_sl:
                self.close(pos, pos.stop_loss, ts, "Stop-Loss")
            elif hit_tp:
                self.close(pos, pos.take_profit, ts, "Take-Profit")
            elif ts - pos.opened_ts >= self.cfg.max_hold_minutes * 60:
                self.close(pos, close, ts, "Max. Haltedauer")
            else:
                continue
            closed.append(pos)
        return closed

    def close_all(self, prices: Dict[str, float], ts: float, reason: str = "Manuell") -> List[Position]:
        closed = []
        for pos in self.open_positions():
            if pos.coin in prices:
                self.close(pos, prices[pos.coin], ts, reason)
                closed.append(pos)
        return closed
