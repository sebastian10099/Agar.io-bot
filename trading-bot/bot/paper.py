"""Paper trading engine: real prices, simulated fills, honest costs.

Fees and slippage are charged on every fill. Exits: stop loss, a take-profit
ladder, a trailing stop that only arms in profit, and a time stop. Position
size is derived from risk per trade and the stop distance.
"""
from __future__ import annotations

import json
import time
from datetime import datetime
from typing import Any, Optional

from .store import Store


class Paper:
    def __init__(self, store: Store, cfg: dict[str, Any]) -> None:
        self.store = store
        self.cfg = cfg
        self.initial = float(cfg["bankroll_usd"])
        pc = cfg.get("paper", {})
        self.fee_pct = float(pc.get("fee_pct", 1.0))
        self.slippage_pct = float(pc.get("slippage_pct", 2.0))

    # --- accounting -----------------------------------------------------
    def bankroll(self) -> float:
        return self.initial + self.store.realized_all()

    def exposure(self) -> float:
        return sum(p["size_usd"] * p["remaining_frac"] for p in self.store.open_positions())

    def cash(self) -> float:
        return self.bankroll() - self.exposure()

    def daily_pnl(self) -> float:
        midnight = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        return self.store.realized_since(midnight)

    def daily_limit_hit(self) -> bool:
        limit = -self.initial * float(self.cfg["daily_loss_limit_pct"]) / 100.0
        return self.daily_pnl() <= limit

    def position_size(self) -> float:
        risk_usd = self.bankroll() * float(self.cfg["risk_per_trade_pct"]) / 100.0
        stop = abs(float(self.cfg["exits"]["stop_loss_pct"])) / 100.0
        size = risk_usd / max(0.05, stop)
        return max(0.0, min(size, self.cash()))

    # --- entries --------------------------------------------------------
    def can_open(self, chain: str, token: str) -> Optional[str]:
        if self.store.has_open_for(chain, token):
            return "already holding"
        if len(self.store.open_positions()) >= int(self.cfg["max_open_positions"]):
            return "max open positions"
        if self.daily_limit_hit():
            return "daily loss limit hit"
        if self.position_size() < 5.0:
            return "not enough cash"
        return None

    def open(self, p: dict[str, Any], now: Optional[float] = None) -> int:
        now = now or time.time()
        size = self.position_size()
        fill = p["price_usd"] * (1 + self.slippage_pct / 100.0)
        fee = size * self.fee_pct / 100.0
        pid = self.store.open_position({
            "opened_at": now, "chain": p["chain"], "token": p["token"], "pair": p["pair"],
            "symbol": p.get("symbol"), "entry_price": fill, "size_usd": size,
        })
        # the entry fee is realized immediately so the bankroll is never flattered
        self.store.update_position(pid, realized_usd=-fee)
        self.store.add_trade({"position_id": pid, "at": now, "side": "buy", "price": fill,
                              "usd": size, "frac": 1.0, "reason": "entry"})
        self.store.log("trade", f"BUY {p.get('symbol')} ${size:.2f} @ {fill:.8g} (paper)")
        return pid

    # --- exits ----------------------------------------------------------
    def _sell(self, pos: dict[str, Any], frac: float, price: float, reason: str, now: float) -> None:
        frac = min(frac, pos["remaining_frac"])
        if frac <= 0:
            return
        fill = price * (1 - self.slippage_pct / 100.0)
        gross = pos["size_usd"] * frac * (fill / pos["entry_price"])
        fee = gross * self.fee_pct / 100.0
        pnl = gross - fee - pos["size_usd"] * frac
        pos["remaining_frac"] = round(pos["remaining_frac"] - frac, 9)
        pos["realized_usd"] = pos["realized_usd"] + pnl
        self.store.add_trade({"position_id": pos["id"], "at": now, "side": "sell", "price": fill,
                              "usd": gross - fee, "frac": frac, "reason": reason})
        fields: dict[str, Any] = {"remaining_frac": pos["remaining_frac"],
                                  "realized_usd": pos["realized_usd"]}
        if pos["remaining_frac"] <= 1e-9:
            fields.update(status="closed", closed_at=now, exit_reason=reason, remaining_frac=0.0)
            pos["status"] = "closed"
        self.store.update_position(pos["id"], **fields)
        self.store.log("trade", f"SELL {pos.get('symbol')} {frac * 100:.0f}% @ {fill:.8g} "
                                f"{reason} pnl {pnl:+.2f} (paper)")

    def update(self, pos: dict[str, Any], price: float, now: Optional[float] = None) -> None:
        """Apply exit rules to one open position given a fresh price."""
        now = now or time.time()
        ex = self.cfg["exits"]
        if price > pos["peak_price"]:
            pos["peak_price"] = price
            self.store.update_position(pos["id"], peak_price=price)

        gain = (price / pos["entry_price"] - 1) * 100
        peak_gain = (pos["peak_price"] / pos["entry_price"] - 1) * 100
        drawdown = (price / pos["peak_price"] - 1) * 100

        if gain <= float(ex["stop_loss_pct"]):
            self._sell(pos, pos["remaining_frac"], price, "stop_loss", now)
            return

        done = list(pos.get("ladder_done") or [])
        for i, (threshold, frac) in enumerate(ex["take_profit_ladder"]):
            if i in done or gain < float(threshold):
                continue
            self._sell(pos, float(frac), price, f"take_profit_{int(threshold)}", now)
            done.append(i)
            pos["ladder_done"] = done
            self.store.update_position(pos["id"], ladder_done=json.dumps(done))
            if pos["status"] == "closed":
                return

        trail = float(ex["trailing_stop_pct"])
        if peak_gain >= trail and drawdown <= -trail:
            self._sell(pos, pos["remaining_frac"], price, "trailing_stop", now)
            return

        if now - pos["opened_at"] >= float(ex["time_stop_minutes"]) * 60:
            self._sell(pos, pos["remaining_frac"], price, "time_stop", now)

    def unrealized(self, pos: dict[str, Any], price: Optional[float]) -> float:
        if not price:
            return 0.0
        fill = price * (1 - self.slippage_pct / 100.0)
        gross = pos["size_usd"] * pos["remaining_frac"] * (fill / pos["entry_price"])
        return gross * (1 - self.fee_pct / 100.0) - pos["size_usd"] * pos["remaining_frac"]
