"""Solana trading bot utilities.

This module implements a paper-trading bot for the Solana (SOL) token that
fetches historical price data from the public CoinGecko API, computes
technical indicators, and performs simple portfolio management.  The goal is to
provide a solid starting point for building real trading automation.  The bot
is intentionally designed for clarity and extensibility rather than raw
performance.

Example usage (paper trading back-test):

```
python trading_bot.py backtest --start 2023-01-01 --end 2023-12-31 \
    --fast-window 5 --slow-window 20 --capital 1000
```

Example usage (live signal print-out):

```
python trading_bot.py signal --fast-window 10 --slow-window 40
```

The default configuration downloads up to 90 days of historical data, which is
free on CoinGecko without authentication.  Requests are rate-limited with a
minimal delay to remain polite to the public API.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import math
import statistics
import time
import urllib.error
import urllib.request
from collections import deque
from typing import Deque, List, Sequence

COINGECKO_BASE_URL = "https://api.coingecko.com/api/v3"
SOLANA_ASSET_ID = "solana"
DEFAULT_VS_CURRENCY = "usd"
MAX_RANGE_DAYS = 90
REQUEST_SLEEP_SECONDS = 1.5  # Conservative rate-limiting delay.


class CoinGeckoError(RuntimeError):
    """Error raised when the CoinGecko API fails."""


@dataclasses.dataclass(frozen=True)
class Candle:
    """Represents a single OHLCV candle."""

    timestamp: dt.datetime
    price: float
    volume: float


class CoinGeckoClient:
    """Minimal client for CoinGecko's public API."""

    def __init__(self, base_url: str = COINGECKO_BASE_URL, user_agent: str = "SolanaBot/1.0"):
        self._base_url = base_url.rstrip("/")
        self._user_agent = user_agent

    def fetch_market_chart(self, *, start: dt.datetime, end: dt.datetime, vs_currency: str = DEFAULT_VS_CURRENCY) -> List[Candle]:
        """Fetches candles for SOL between ``start`` and ``end``.

        CoinGecko's free tier allows 90 days of data per request.  For longer
        ranges we chunk the interval into multiple requests and concatenate the
        results.
        """

        if start >= end:
            raise ValueError("start must be earlier than end")

        start = start.replace(tzinfo=dt.timezone.utc)
        end = end.replace(tzinfo=dt.timezone.utc)
        candles: List[Candle] = []
        chunk_start = start
        while chunk_start < end:
            chunk_end = min(chunk_start + dt.timedelta(days=MAX_RANGE_DAYS), end)
            candles.extend(self._fetch_chunk(chunk_start, chunk_end, vs_currency))
            chunk_start = chunk_end
            if chunk_start < end:
                time.sleep(REQUEST_SLEEP_SECONDS)
        return candles

    def _fetch_chunk(self, start: dt.datetime, end: dt.datetime, vs_currency: str) -> List[Candle]:
        url = (
            f"{self._base_url}/coins/{SOLANA_ASSET_ID}/market_chart/range"
            f"?vs_currency={vs_currency}"
            f"&from={math.floor(start.timestamp())}"
            f"&to={math.floor(end.timestamp())}"
        )
        request = urllib.request.Request(url, headers={"User-Agent": self._user_agent})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status != 200:
                    raise CoinGeckoError(f"CoinGecko request failed: {response.status} {response.reason}")
                payload = json.load(response)
        except urllib.error.URLError as exc:  # pragma: no cover - network errors
            raise CoinGeckoError(f"CoinGecko request failed: {exc}") from exc
        prices = payload.get("prices") or []
        volumes = payload.get("total_volumes") or []
        if not prices:
            raise CoinGeckoError("CoinGecko response did not contain price data")
        volume_lookup = {int(ts): vol for ts, vol in volumes}
        candles = [
            Candle(
                timestamp=dt.datetime.fromtimestamp(ts / 1000, tz=dt.timezone.utc),
                price=float(price),
                volume=float(volume_lookup.get(int(ts), 0.0)),
            )
            for ts, price in prices
        ]
        return candles


class MovingAverageStrategy:
    """Moving average crossover strategy."""

    def __init__(self, fast_window: int, slow_window: int):
        if fast_window <= 0 or slow_window <= 0:
            raise ValueError("Moving average windows must be positive")
        if fast_window >= slow_window:
            raise ValueError("fast_window must be smaller than slow_window")
        self.fast_window = fast_window
        self.slow_window = slow_window

    def generate_signals(self, prices: Sequence[float]) -> List[int]:
        """Returns 1 for long, 0 for flat based on moving averages."""

        fast_ma = _moving_average(prices, self.fast_window)
        slow_ma = _moving_average(prices, self.slow_window)
        signals = [1 if f > s else 0 for f, s in zip(fast_ma, slow_ma)]
        # Ensure that we stay flat until both averages are defined.
        warmup = max(self.fast_window, self.slow_window) - 1
        for i in range(warmup):
            if i < len(signals):
                signals[i] = 0
        return signals


@dataclasses.dataclass
class Trade:
    timestamp: dt.datetime
    side: str
    price: float
    quantity: float
    cash_before: float
    cash_after: float


class PaperBroker:
    """Simulates simple market order execution."""

    def __init__(self, capital: float):
        if capital <= 0:
            raise ValueError("Initial capital must be positive")
        self.initial_capital = capital
        self.cash = capital
        self.position = 0.0
        self.trades: List[Trade] = []

    def _execute_trade(self, timestamp: dt.datetime, side: str, price: float, quantity: float) -> None:
        cash_before = self.cash
        if side == "buy":
            cost = price * quantity
            if cost > self.cash + 1e-9:
                raise ValueError("Insufficient cash for trade")
            self.cash -= cost
            self.position += quantity
        elif side == "sell":
            if quantity > self.position + 1e-9:
                raise ValueError("Insufficient position to sell")
            proceeds = price * quantity
            self.cash += proceeds
            self.position -= quantity
        else:
            raise ValueError(f"Unknown trade side: {side}")
        self.trades.append(
            Trade(
                timestamp=timestamp,
                side=side,
                price=price,
                quantity=quantity,
                cash_before=cash_before,
                cash_after=self.cash,
            )
        )

    def rebalance(self, timestamp: dt.datetime, target_position: float, price: float) -> None:
        """Adjusts holdings to match ``target_position`` SOL."""

        if target_position > self.position:
            quantity = target_position - self.position
            if quantity * price > self.cash and price > 0:
                quantity = self.cash / price
            if quantity > 0:
                self._execute_trade(timestamp, "buy", price, quantity)
        elif target_position < self.position:
            quantity = self.position - target_position
            if quantity > 0:
                self._execute_trade(timestamp, "sell", price, quantity)

    def portfolio_value(self, price: float) -> float:
        return self.cash + self.position * price


@dataclasses.dataclass
class BacktestRow:
    timestamp: dt.datetime
    price: float
    signal: int
    portfolio_value: float
    returns: float


@dataclasses.dataclass
class BacktestResult:
    rows: List[BacktestRow]

    @property
    def total_return(self) -> float:
        if not self.rows:
            return 0.0
        start_value = self.rows[0].portfolio_value
        end_value = self.rows[-1].portfolio_value
        return (end_value / start_value) - 1 if start_value else 0.0

    @property
    def sharpe(self) -> float:
        returns = [row.returns for row in self.rows[1:]]
        if not returns:
            return float("nan")
        mean = statistics.fmean(returns)
        stdev = statistics.pstdev(returns)
        if stdev == 0:
            return float("nan")
        return (mean / stdev) * math.sqrt(365)

    @property
    def max_drawdown(self) -> float:
        max_value = -float("inf")
        max_drawdown = 0.0
        for row in self.rows:
            max_value = max(max_value, row.portfolio_value)
            if max_value > 0:
                drawdown = (max_value - row.portfolio_value) / max_value
                max_drawdown = max(max_drawdown, drawdown)
        return max_drawdown


def _moving_average(values: Sequence[float], window: int) -> List[float]:
    if window <= 0:
        raise ValueError("window must be positive")
    averages: List[float] = []
    running_sum = 0.0
    q: Deque[float] = deque()
    for value in values:
        running_sum += value
        q.append(value)
        if len(q) > window:
            running_sum -= q.popleft()
        averages.append(running_sum / len(q))
    return averages


def run_backtest(
    candles: Sequence[Candle],
    strategy: MovingAverageStrategy,
    capital: float,
    risk_fraction: float,
) -> BacktestResult:
    """Runs a back-test and returns a performance object."""

    prices = [c.price for c in candles]
    signals = strategy.generate_signals(prices)
    broker = PaperBroker(capital=capital)
    rows: List[BacktestRow] = []
    previous_value = capital
    for candle, signal in zip(candles, signals):
        target_value = broker.portfolio_value(candle.price) * risk_fraction if signal else 0.0
        target_position = target_value / candle.price if candle.price else 0.0
        broker.rebalance(candle.timestamp, target_position, candle.price)
        value = broker.portfolio_value(candle.price)
        returns = (value / previous_value - 1) if previous_value else 0.0
        rows.append(
            BacktestRow(
                timestamp=candle.timestamp,
                price=candle.price,
                signal=signal,
                portfolio_value=value,
                returns=returns,
            )
        )
        previous_value = value
    return BacktestResult(rows=rows)


def parse_date(value: str) -> dt.datetime:
    return dt.datetime.strptime(value, "%Y-%m-%d")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Solana paper trading bot")
    subparsers = parser.add_subparsers(dest="command", required=True)

    backtest_parser = subparsers.add_parser("backtest", help="Run a back-test over a historical period")
    backtest_parser.add_argument("--start", type=parse_date, required=True, help="Start date (YYYY-MM-DD)")
    backtest_parser.add_argument("--end", type=parse_date, required=True, help="End date (YYYY-MM-DD)")
    backtest_parser.add_argument("--fast-window", type=int, default=5, help="Fast moving average window")
    backtest_parser.add_argument("--slow-window", type=int, default=20, help="Slow moving average window")
    backtest_parser.add_argument("--capital", type=float, default=1_000.0, help="Initial capital in USD")
    backtest_parser.add_argument("--risk-fraction", type=float, default=0.8, help="Fraction of capital to allocate when long")

    signal_parser = subparsers.add_parser("signal", help="Print the latest trading signal")
    signal_parser.add_argument("--days", type=int, default=60, help="Number of days of history to download")
    signal_parser.add_argument("--fast-window", type=int, default=5, help="Fast moving average window")
    signal_parser.add_argument("--slow-window", type=int, default=20, help="Slow moving average window")

    return parser.parse_args()


def download_history(client: CoinGeckoClient, *, start: dt.datetime, end: dt.datetime) -> List[Candle]:
    return client.fetch_market_chart(start=start, end=end)


def command_backtest(args: argparse.Namespace) -> None:
    client = CoinGeckoClient()
    candles = download_history(client, start=args.start, end=args.end)
    strategy = MovingAverageStrategy(args.fast_window, args.slow_window)
    result = run_backtest(candles, strategy, capital=args.capital, risk_fraction=args.risk_fraction)
    print("Back-test summary:")
    print(f"  Total return:  {result.total_return * 100:.2f}%")
    sharpe = result.sharpe
    sharpe_str = f"{sharpe:.2f}" if not math.isnan(sharpe) else "n/a"
    print(f"  Sharpe ratio: {sharpe_str}")
    print(f"  Max drawdown: {result.max_drawdown * 100:.2f}%")
    print("\nFinal portfolio value:", f"${result.rows[-1].portfolio_value:.2f}" if result.rows else "n/a")


def command_signal(args: argparse.Namespace) -> None:
    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(days=args.days)
    client = CoinGeckoClient()
    candles = download_history(client, start=start, end=end)
    strategy = MovingAverageStrategy(args.fast_window, args.slow_window)
    signals = strategy.generate_signals([c.price for c in candles])
    if not candles:
        print("No market data available.")
        return
    latest_signal = signals[-1]
    latest_price = candles[-1].price
    direction = "LONG" if latest_signal == 1 else "FLAT"
    print(f"Latest price: ${latest_price:.2f} USD")
    print(f"Strategy signal: {direction}")


def main() -> None:
    args = parse_args()
    if args.command == "backtest":
        command_backtest(args)
    elif args.command == "signal":
        command_signal(args)
    else:
        raise ValueError(f"Unknown command {args.command}")


if __name__ == "__main__":
    main()
