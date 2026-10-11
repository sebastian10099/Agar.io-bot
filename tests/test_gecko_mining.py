"""Tests fuer den Gecko-Mining-Bot.  Ausfuehren: ``python -m unittest discover -s tests``"""

import io
import json
import os
import tempfile
import unittest
import urllib.error

from gecko_mining.bot import GeckoMiningBot
from gecko_mining.config import BotConfig
from gecko_mining.data import Candle, CoinGeckoClient, CoinGeckoError, SimulatedFeed, TickStore, build_candles
from gecko_mining.positions import PositionManager
from gecko_mining.strategy import LONG, SHORT, Signal, analyze, generate_signal, measure_window

T0 = 1_700_000_000 - (1_700_000_000 % 60)  # volle Minute


def candles_from_closes(closes, start=T0):
    """Kerzen, bei denen jede Kerze am vorherigen Schluss eroeffnet."""
    out, prev = [], closes[0]
    for i, c in enumerate(closes):
        out.append(Candle(start + 60 * i, prev, max(prev, c), min(prev, c), c))
        prev = c
    return out


def cfg(**kw):
    base = dict(coins=("kaspa",), windows_minutes=(6, 8, 20, 60), move_threshold_pct=(1.5, 2.0, 3.0, 5.0))
    base.update(kw)
    c = BotConfig(**base)
    c.validate()
    return c


class FakeClock:
    def __init__(self, t=T0):
        self.t = t

    def __call__(self):
        return self.t


class BuildCandlesTest(unittest.TestCase):
    def test_ohlc_aggregation(self):
        ticks = [(T0 + 0, 10), (T0 + 20, 12), (T0 + 40, 9), (T0 + 59, 11), (T0 + 60, 11.5)]
        c = build_candles(ticks, 60)
        self.assertEqual(len(c), 2)
        self.assertEqual((c[0].open, c[0].high, c[0].low, c[0].close), (10, 12, 9, 11))
        self.assertTrue(c[0].is_green)
        # Zweite Kerze eroeffnet am vorherigen Schluss
        self.assertEqual(c[1].open, 11)
        self.assertEqual(c[1].close, 11.5)

    def test_red_candle(self):
        c = build_candles([(T0, 10), (T0 + 30, 8)], 60)[0]
        self.assertFalse(c.is_green)

    def test_gaps_filled_with_flat_candles(self):
        c = build_candles([(T0, 10), (T0 + 180, 12)], 60)
        self.assertEqual([x.ts for x in c], [T0, T0 + 60, T0 + 120, T0 + 180])
        self.assertEqual((c[1].open, c[1].close), (10, 10))

    def test_ignores_bad_prices_and_sorts(self):
        c = build_candles([(T0 + 30, 11), (T0, 10), (T0 + 10, 0), (T0 + 20, float("nan"))], 60)
        self.assertEqual(len(c), 1)
        self.assertEqual((c[0].open, c[0].close), (10, 11))

    def test_empty(self):
        self.assertEqual(build_candles([], 60), [])


class TickStoreTest(unittest.TestCase):
    def test_trims_old_ticks(self):
        s = TickStore(keep_seconds=120)
        for i in range(10):
            s.add("x", T0 + 60 * i, 1.0 + i)
        self.assertEqual(len(s.ticks("x")), 3)
        self.assertEqual(s.last_price("x"), 10.0)
        self.assertIsNone(s.last_price("y"))


class MoveDetectionTest(unittest.TestCase):
    def test_rise_from_bottom_to_top_in_6_minutes(self):
        closes = [100] * 30 + [100, 100.5, 101, 101.5, 102, 102.5]
        move = measure_window(candles_from_closes(closes), 6, 6, 1.5)
        self.assertEqual(move.direction, "up")
        self.assertAlmostEqual(move.move_pct, 2.5, places=6)
        self.assertTrue(move.triggered)
        self.assertAlmostEqual(move.retrace_pct, 0.0)

    def test_fall_from_top_to_bottom(self):
        closes = [100] * 10 + [99, 98, 97, 96]
        move = measure_window(candles_from_closes(closes), 6, 6, 1.5)
        self.assertEqual(move.direction, "down")
        self.assertAlmostEqual(move.move_pct, 4.0)

    def test_all_windows_measured(self):
        closes = [100 + 0.1 * i for i in range(90)]
        moves = analyze(candles_from_closes(closes), cfg())
        self.assertEqual([m.window_minutes for m in moves], [6, 8, 20, 60])
        self.assertTrue(all(m.direction == "up" for m in moves))

    def test_slow_60_min_rise_only_triggers_long_window(self):
        # 6 % in 60 Minuten: nur das 60-min-Fenster (Schwelle 5 %) loest aus.
        closes = [100 * (1.06 ** (i / 60)) for i in range(61)]
        moves = {m.window_minutes: m for m in analyze(candles_from_closes(closes), cfg())}
        self.assertTrue(moves[60].triggered)
        self.assertFalse(moves[6].triggered)
        self.assertFalse(moves[20].triggered)

    def test_retrace_measured(self):
        closes = [100] * 5 + [101, 102, 103, 104, 103]
        move = measure_window(candles_from_closes(closes), 6, 6, 1.5)
        self.assertEqual(move.direction, "up")
        self.assertAlmostEqual(move.retrace_pct, 25.0)


class SignalTest(unittest.TestCase):
    def pump_then_red(self):
        return [100] * 30 + [100, 101, 102, 103, 104, 103.6]  # Pump + erste rote Kerze

    def test_reversal_shorts_pump_after_red_candle(self):
        sig = generate_signal("kaspa", candles_from_closes(self.pump_then_red()), cfg())
        self.assertIsNotNone(sig)
        self.assertEqual(sig.side, SHORT)
        self.assertEqual(sig.move.direction, "up")
        self.assertIn("Anstieg", sig.reason)

    def test_no_short_into_running_pump(self):
        closes = [100] * 30 + [100, 101, 102, 103, 104, 105]  # letzte Kerze noch gruen
        self.assertIsNone(generate_signal("kaspa", candles_from_closes(closes), cfg()))

    def test_without_confirmation_shorts_immediately(self):
        closes = [100] * 30 + [100, 101, 102, 103, 104, 105]
        sig = generate_signal("kaspa", candles_from_closes(closes), cfg(require_confirmation=False))
        self.assertEqual(sig.side, SHORT)

    def test_reversal_longs_dump_after_green_candle(self):
        closes = [100] * 30 + [100, 99, 98, 97, 96, 96.4]
        sig = generate_signal("kaspa", candles_from_closes(closes), cfg())
        self.assertEqual(sig.side, LONG)

    def test_momentum_mode_follows_direction(self):
        up = [100] * 30 + [100, 101, 102, 103, 104, 105]
        down = [100] * 30 + [100, 99, 98, 97, 96, 95]
        self.assertEqual(generate_signal("k", candles_from_closes(up), cfg(mode="momentum")).side, LONG)
        self.assertEqual(generate_signal("k", candles_from_closes(down), cfg(mode="momentum")).side, SHORT)

    def test_short_can_be_disabled(self):
        sig = generate_signal("kaspa", candles_from_closes(self.pump_then_red()), cfg(allow_short=False))
        self.assertIsNone(sig)

    def test_late_entry_rejected_when_mostly_retraced(self):
        closes = [100] * 30 + [100, 101, 102, 103, 104, 101]  # 75 % schon zurueck
        self.assertIsNone(generate_signal("kaspa", candles_from_closes(closes), cfg()))

    def test_flat_market_no_signal(self):
        self.assertIsNone(generate_signal("kaspa", candles_from_closes([100] * 90), cfg()))

    def test_picks_strongest_window(self):
        sig = generate_signal("kaspa", candles_from_closes(self.pump_then_red()), cfg())
        moves = [m for m in analyze(candles_from_closes(self.pump_then_red()), cfg()) if m.triggered]
        self.assertEqual(sig.move.strength, max(m.strength for m in moves))


def make_signal(coin="kaspa", side=SHORT, price=100.0, ts=T0):
    from gecko_mining.strategy import Move
    move = Move(6, "up" if side == SHORT else "down", 3.0, 1.5, 10.0, 97.0, 100.0)
    return Signal(coin, side, price, ts, move)


class PositionManagerTest(unittest.TestCase):
    def test_default_allows_ten_positions(self):
        self.assertEqual(BotConfig().max_open_positions, 10)
        pm = PositionManager(cfg(max_positions_per_coin=1))
        for i in range(10):
            pm.open(make_signal(coin=f"c{i}"))
        self.assertEqual(len(pm.open_positions()), 10)
        self.assertEqual(pm.free_slots(), 0)
        self.assertIn("Maximum von 10", pm.can_open(make_signal(coin="c10")))
        with self.assertRaises(ValueError):
            pm.open(make_signal(coin="c10"))

    def test_configurable_limit(self):
        pm = PositionManager(cfg(max_open_positions=15, max_positions_per_coin=1, starting_capital_usd=5000))
        for i in range(15):
            pm.open(make_signal(coin=f"c{i}"))
        self.assertEqual(len(pm.open_positions()), 15)

    def test_per_coin_limit_and_no_hedge(self):
        pm = PositionManager(cfg(max_positions_per_coin=2))
        pm.open(make_signal())
        self.assertIn("Gegenposition", pm.can_open(make_signal(side=LONG)))
        pm.open(make_signal())
        self.assertIn("fuer kaspa", pm.can_open(make_signal()))

    def test_capital_limit(self):
        pm = PositionManager(cfg(starting_capital_usd=250, position_size_usd=100, max_positions_per_coin=5))
        pm.open(make_signal(coin="a"))
        pm.open(make_signal(coin="b"))
        self.assertEqual(pm.can_open(make_signal(coin="c")), "Nicht genug freies Kapital")

    def test_short_pnl(self):
        pm = PositionManager(cfg(fee_pct=0))
        pos = pm.open(make_signal(side=SHORT, price=100))
        self.assertAlmostEqual(pos.pnl(90), 10.0)  # 1 Stueck, Kurs faellt -> Gewinn
        self.assertAlmostEqual(pos.pnl(110), -10.0)

    def test_long_pnl_with_fees(self):
        pm = PositionManager(cfg(fee_pct=0.1))
        pos = pm.open(make_signal(side=LONG, price=100))
        self.assertAlmostEqual(pos.pnl(110, pm.cfg.fee_pct), 10 - (100 + 110) * 0.001)

    def test_short_stop_loss_and_take_profit(self):
        pm = PositionManager(cfg(fee_pct=0, stop_loss_pct=2, take_profit_pct=4))
        pos = pm.open(make_signal(side=SHORT, price=100))
        self.assertAlmostEqual(pos.stop_loss, 102)
        self.assertAlmostEqual(pos.take_profit, 96)
        self.assertEqual(pm.check_exits("kaspa", 101, 99, 100, T0 + 60), [])
        closed = pm.check_exits("kaspa", 100, 95.5, 96, T0 + 120)
        self.assertEqual(closed[0].exit_reason, "Take-Profit")
        self.assertAlmostEqual(pm.realized_pnl, 4.0)

    def test_stop_loss_wins_when_both_hit(self):
        pm = PositionManager(cfg(fee_pct=0, stop_loss_pct=2, take_profit_pct=4))
        pm.open(make_signal(side=LONG, price=100))
        closed = pm.check_exits("kaspa", 105, 97, 100, T0 + 60)
        self.assertEqual(closed[0].exit_reason, "Stop-Loss")
        self.assertAlmostEqual(pm.realized_pnl, -2.0)

    def test_max_hold_time(self):
        pm = PositionManager(cfg(max_hold_minutes=30))
        pm.open(make_signal(price=100))
        self.assertEqual(pm.check_exits("kaspa", 100, 100, 100, T0 + 29 * 60), [])
        self.assertEqual(pm.check_exits("kaspa", 100, 100, 100, T0 + 30 * 60)[0].exit_reason, "Max. Haltedauer")

    def test_equity(self):
        pm = PositionManager(cfg(fee_pct=0, starting_capital_usd=1000))
        pm.open(make_signal(side=SHORT, price=100))
        self.assertAlmostEqual(pm.equity({"kaspa": 95}), 1005.0)


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


class CoinGeckoClientTest(unittest.TestCase):
    def make(self, payload, plan="demo", key="KEY123"):
        self.requests = []

        def opener(req, timeout):
            self.requests.append(req)
            return FakeResponse(json.dumps(payload).encode())

        return CoinGeckoClient(api_key=key, plan=plan, opener=opener)

    def test_demo_key_header_and_url(self):
        client = self.make({"kaspa": {"usd": 0.12}, "monero": {"usd": 160.5}})
        prices = client.simple_prices(["kaspa", "monero", "unknown"])
        self.assertEqual(prices, {"kaspa": 0.12, "monero": 160.5})
        req = self.requests[0]
        self.assertTrue(req.full_url.startswith("https://api.coingecko.com/api/v3/simple/price?"))
        self.assertIn("ids=kaspa%2Cmonero%2Cunknown", req.full_url)
        self.assertEqual(req.get_header("X-cg-demo-api-key"), "KEY123")

    def test_pro_key_header_and_url(self):
        client = self.make({"kaspa": {"usd": 1}}, plan="pro")
        client.simple_prices(["kaspa"])
        req = self.requests[0]
        self.assertTrue(req.full_url.startswith("https://pro-api.coingecko.com/api/v3/"))
        self.assertEqual(req.get_header("X-cg-pro-api-key"), "KEY123")

    def test_no_key_sends_no_key_header(self):
        client = self.make({}, key="")
        self.assertNotIn("x-cg-demo-api-key", client.headers())

    def test_market_chart_to_ticks(self):
        client = self.make({"prices": [[T0 * 1000, 1.5], [(T0 + 300) * 1000, 1.6]]})
        self.assertEqual(client.recent_ticks("kaspa"), [(T0, 1.5), (T0 + 300, 1.6)])

    def test_http_errors_become_readable(self):
        for code, text in ((429, "Rate-Limit"), (401, "API-Key"), (500, "HTTP 500")):
            def opener(req, timeout, code=code):
                raise urllib.error.HTTPError(req.full_url, code, "x", {}, None)
            client = CoinGeckoClient(opener=opener)
            with self.assertRaises(CoinGeckoError) as ctx:
                client.simple_prices(["kaspa"])
            self.assertIn(text, str(ctx.exception))


class BotTest(unittest.TestCase):
    def test_bot_shorts_pump_and_takes_profit(self):
        clock = FakeClock()
        bot = GeckoMiningBot(cfg(fee_pct=0, take_profit_pct=2, stop_loss_pct=1.5), clock=clock)
        path = [100] * 30 + [100, 101, 102, 103, 104, 103.6]
        events = []
        for p in path:
            events += bot.step({"kaspa": p})
            clock.t += 60
        opens = [e for e in events if e["type"] == "open"]
        self.assertEqual(len(opens), 1)
        self.assertEqual(opens[0]["position"]["side"], SHORT)
        # Kurs faellt -> Take-Profit (2 % unter 103.6)
        closes = []
        for p in (103, 102, 101):
            closes += [e for e in bot.step({"kaspa": p}) if e["type"] == "close"]
            clock.t += 60
        self.assertEqual(closes[0]["position"]["exit_reason"], "Take-Profit")
        self.assertGreater(bot.positions.realized_pnl, 0)

    def test_one_signal_per_candle(self):
        clock = FakeClock()
        bot = GeckoMiningBot(cfg(max_positions_per_coin=5, require_confirmation=False), clock=clock)
        for p in [100] * 30 + [100, 101, 102, 103, 104]:
            bot.step({"kaspa": p})
            clock.t += 60
        clock.t -= 60
        before = len(bot.positions.open_positions())
        for _ in range(3):  # mehrere Polls in derselben Kerze
            clock.t += 5
            bot.step({"kaspa": 104.2})
        self.assertEqual(len(bot.positions.open_positions()), before)

    def test_api_error_does_not_crash(self):
        class Broken:
            def simple_prices(self, *a):
                raise CoinGeckoError("Rate-Limit erreicht (429)")
        bot = GeckoMiningBot(cfg(), client=Broken(), clock=FakeClock())
        self.assertEqual(bot.step(), [])
        self.assertIn("429", bot.last_error)

    def test_simulated_run_respects_position_limit(self):
        coins = tuple(f"coin{i}" for i in range(20))
        c = cfg(coins=coins, max_open_positions=10, max_positions_per_coin=1,
                starting_capital_usd=5000, history_minutes=90)
        bot = GeckoMiningBot(c, feed=SimulatedFeed(coins, seed=3))
        bot.seed_history()
        max_seen = 0
        for _ in range(600):
            bot.step()
            max_seen = max(max_seen, len(bot.positions.open_positions()))
        self.assertLessEqual(max_seen, 10)
        self.assertGreater(len(bot.positions.positions), 0, "Simulation sollte Trades erzeugen")

    def test_snapshot_and_state_file(self):
        bot = GeckoMiningBot(cfg(history_minutes=30), feed=SimulatedFeed(("kaspa",), seed=1))
        bot.seed_history()
        bot.step()
        snap = bot.snapshot()
        self.assertEqual(snap["max_open_positions"], 10)
        self.assertGreaterEqual(len(snap["coins"]["kaspa"]["candles"]), 30)
        self.assertEqual([m["window_minutes"] for m in snap["coins"]["kaspa"]["moves"]], [6, 8, 20, 60])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "state.json")
            bot.write_state(path)
            with open(path) as fh:
                self.assertEqual(json.load(fh)["mode"], "reversal")


class ConfigTest(unittest.TestCase):
    def test_env_overrides(self):
        env = {"GECKO_API_KEY": "abc", "GECKO_API_PLAN": "pro", "GECKO_COINS": "kaspa, monero", "GECKO_MAX_POSITIONS": "12"}
        old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            c = BotConfig.from_env()
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.assertEqual((c.api_key, c.api_plan, c.coins, c.max_open_positions), ("abc", "pro", ("kaspa", "monero"), 12))

    def test_invalid(self):
        for bad in (dict(mode="x"), dict(windows_minutes=(6,)), dict(max_open_positions=0), dict(api_plan="free")):
            with self.assertRaises(ValueError):
                BotConfig(**bad).validate()


if __name__ == "__main__":
    unittest.main()
