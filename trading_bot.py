import argparse
import yfinance as yf
import numpy as np
import pandas as pd

class MovingAverageStrategy:
    """Simple moving average crossover strategy with parameter optimization."""

    def __init__(self, symbol, start, end, fast_window=5, slow_window=20):
        self.symbol = symbol
        self.start = start
        self.end = end
        self.fast_window = fast_window
        self.slow_window = slow_window
        self.data = None
        self._download_data()

    def _download_data(self):
        self.data = yf.download(self.symbol, start=self.start, end=self.end)
        if self.data.empty:
            raise ValueError("No data fetched for symbol %s" % self.symbol)

    def backtest(self, fast_window=None, slow_window=None):
        fast_window = fast_window or self.fast_window
        slow_window = slow_window or self.slow_window
        if fast_window >= slow_window:
            return -np.inf
        prices = self.data['Close']
        if isinstance(prices, pd.DataFrame):
            # yfinance may return DataFrame with multi-level columns
            prices = prices.iloc[:, 0]
        fast_ma = prices.rolling(window=fast_window).mean()
        slow_ma = prices.rolling(window=slow_window).mean()
        signal = (fast_ma > slow_ma).astype(int)
        returns = prices.pct_change().shift(-1)
        strategy_returns = returns * signal
        result = strategy_returns.fillna(0).cumsum().iloc[-1]
        if hasattr(result, "item"):
            result = result.item()
        return float(result)

    def optimize(self, fast_range, slow_range, iterations=100):
        best_score = -np.inf
        best_params = (self.fast_window, self.slow_window)
        for _ in range(iterations):
            fast = np.random.randint(*fast_range)
            slow = np.random.randint(*slow_range)
            score = self.backtest(fast, slow)
            if score > best_score:
                best_score = score
                best_params = (fast, slow)
        self.fast_window, self.slow_window = best_params
        return best_params, best_score

    def run(self):
        prices = self.data['Close']
        if isinstance(prices, pd.DataFrame):
            prices = prices.iloc[:, 0]
        fast_ma = prices.rolling(window=self.fast_window).mean()
        slow_ma = prices.rolling(window=self.slow_window).mean()
        latest_price = prices.iloc[-1]
        latest_fast = fast_ma.iloc[-1]
        latest_slow = slow_ma.iloc[-1]
        if float(latest_fast) > float(latest_slow):
            return f"BUY {self.symbol} at {latest_price}"
        else:
            return f"SELL {self.symbol} at {latest_price}"


def main():
    parser = argparse.ArgumentParser(description="Autonomous Moving Average Trading Bot")
    parser.add_argument("symbol", help="Ticker symbol to trade")
    parser.add_argument("--start", default="2020-01-01", help="Start date for historical data")
    parser.add_argument("--end", default="2021-01-01", help="End date for historical data")
    parser.add_argument("--opt", action="store_true", help="Run parameter optimization")
    args = parser.parse_args()

    bot = MovingAverageStrategy(args.symbol, args.start, args.end)

    if args.opt:
        params, score = bot.optimize((3, 20), (20, 60), iterations=200)
        print(f"Optimized parameters: fast={params[0]}, slow={params[1]}, score={score:.2f}")

    decision = bot.run()
    print(decision)

if __name__ == "__main__":
    main()
