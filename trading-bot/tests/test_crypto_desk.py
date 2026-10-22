"""Krypto-Desk: Spielgeld gegen (hier: erfundene) Binance-Kerzen, ohne Netz."""
import filecmp
import json
import tempfile
import unittest
from pathlib import Path

from bot import crypto
from bot.crypto import CryptoDesk
from bot.store import Store

ROOT = Path(__file__).parent.parent
DAY = 86400
T0 = 1790035200            # 2026-09-22 00:00 UTC


def kl(t, o, h, l, c, step):
    return [t * 1000, str(o), str(h), str(l), str(c), "1", (t + step) * 1000 - 1, "1000000", 1, "0", "0", "0"]


class FakeFeed:
    """Answers like scan.Feed from lists of klines; minute bars are made on demand."""

    def __init__(self):
        self.ticker = []
        self.daily = {}            # symbol -> klines 1d
        self.minute = {}           # symbol -> function(t) -> (o, h, l, c)
        self.fail = set()
        self.offline = None

    def tickers(self):
        return self.ticker

    def exchange_info(self):
        return {"symbols": [{"symbol": t["symbol"], "baseAsset": t["symbol"][:-4], "status": "TRADING",
                             "permissionSets": [["SPOT"]]} for t in self.ticker]}

    def klines(self, symbol, interval, start_ms=None, end_ms=None, limit=1000):
        if symbol in self.fail:
            raise RuntimeError("Binance nicht erreichbar")
        if interval == "1d":
            return self.daily[symbol][-limit:]
        if interval == "1m":
            fn = self.minute[symbol]
            end = (end_ms or self.now * 1000) // 1000
            start = start_ms // 1000 if start_ms is not None else end - limit * 60
            start -= start % 60
            return [kl(t, *fn(t), 60) for t in range(start, end + 1, 60)]
        raise AssertionError(interval)


def breakout_daily(n=80, t0=T0 - 80 * DAY):
    closes = [100 + (k % 3) for k in range(n - 1)] + [112]
    return [kl(t0 + k * DAY, closes[k - 1] if k else c, c * 1.01, c * 0.99, c, DAY) for k, c in enumerate(closes)]


def flat(price):
    return lambda t: (price, price * 1.001, price * 0.999, price)


def no_funding(since_ms):
    return []


def desk_with(feed, cfg=None, now=T0 + 600, funding=no_funding):
    store = Store(Path(tempfile.mkdtemp()) / "bot.sqlite")
    clock = {"now": now}
    feed.now = now
    conf = {"crypto": {"timemachine": False, "backtest": False, **(cfg or {})}}
    desk = CryptoDesk(store, conf, feed=feed, clock=lambda: clock["now"], funding=funding)
    return desk, store, clock


def market():
    feed = FakeFeed()
    feed.ticker = [{"symbol": "AAAUSDT", "lastPrice": "112", "quoteVolume": "9e7", "highPrice": "115",
                    "lowPrice": "100", "priceChangePercent": "12"},
                   {"symbol": "BTCUSDT", "lastPrice": "80000", "quoteVolume": "2e9", "highPrice": "81000",
                    "lowPrice": "79000", "priceChangePercent": "1"}]
    feed.daily = {"AAAUSDT": breakout_daily(), "BTCUSDT": [kl(T0 - (80 - k) * DAY, 80000, 80100, 79900, 80000, DAY)
                                                          for k in range(80)]}
    feed.minute = {"AAAUSDT": flat(112.0), "BTCUSDT": flat(80000.0)}
    return feed


class DeskTests(unittest.TestCase):
    def test_vendored_plugin_code_is_identical(self):
        skills = ROOT.parent / "crypto-skills"
        if not skills.is_dir():
            self.skipTest("crypto-skills liegt nicht daneben (installierte App)")
        self.assertTrue(filecmp.cmp(ROOT / "bot" / "crypto_scan.py", skills / "crypto-scanner" / "scan.py", shallow=False),
                        "bot/crypto_scan.py weicht vom Plugin ab: cp crypto-skills/crypto-scanner/scan.py trading-bot/bot/crypto_scan.py")
        self.assertTrue(filecmp.cmp(ROOT / "bot" / "crypto_tm.py", skills / "crypto-timemachine" / "timemachine.py", shallow=False),
                        "bot/crypto_tm.py weicht vom Plugin ab")

    def test_buys_the_setup_after_the_daily_close_with_risk_sizing(self):
        feed = market()
        desk, store, clock = desk_with(feed, {"max_position_pct": 100})
        desk.step()
        v = desk.view()
        self.assertEqual(len(v["positions"]), 1, v["last_scan"])
        p = desk.book["positions"][0]
        self.assertEqual((p["symbol"], p["setup"]), ("AAAUSDT", "breakout20"))
        # 1 % of 1,000 $ is lost at the stop, after slippage and fees
        stop_value = p["qty"] * p["stop"] * (1 - 0.0005) * (1 - 0.001)
        self.assertAlmostEqual(p["cost"] - stop_value, 10.0, places=6)
        self.assertAlmostEqual(desk.book["cash"], 1000 - p["cost"])
        self.assertLess(v["equity"], 1000)                      # fees and slippage are already gone
        self.assertEqual(desk.book["scan_day"], "2026-09-22")
        store.close()

    def test_position_cap_shrinks_the_risk(self):
        feed = market()
        desk, store, clock = desk_with(feed, {"max_position_pct": 10})
        desk.step()
        p = desk.book["positions"][0]
        self.assertAlmostEqual(p["size"], 100.0)
        self.assertLess(p["risk_usd"], 10.0)
        store.close()

    def test_stop_loses_exactly_the_risk(self):
        feed = market()
        desk, store, clock = desk_with(feed)
        desk.step()
        p = desk.book["positions"][0]
        stop = p["stop"]
        feed.minute["AAAUSDT"] = lambda t: (112.0, 112.0, stop - 1, stop - 0.5) if t >= T0 + 3600 else (112.0, 112.1, 111.9, 112.0)
        clock["now"] = feed.now = T0 + 7200
        desk.step()
        self.assertEqual(desk.book["positions"], [])
        t = desk.book["closed"][0]
        self.assertEqual(t["reason"], "Stop")
        self.assertAlmostEqual(t["r"], -1.0, places=6)
        self.assertAlmostEqual(t["pnl"], -p["risk_usd"], places=6)
        self.assertAlmostEqual(desk.book["cash"], 1000.0 - p["risk_usd"], places=6)
        self.assertEqual(desk.view()["by_setup"][0]["n"], 1)
        store.close()

    def test_gap_below_stop_fills_at_the_open(self):
        feed = market()
        desk, store, clock = desk_with(feed)
        desk.step()
        stop = desk.book["positions"][0]["stop"]
        feed.minute["AAAUSDT"] = lambda t: (stop * 0.9, stop * 0.92, stop * 0.88, stop * 0.9) if t >= T0 + 3600 else (112.0, 112.1, 111.9, 112.0)
        clock["now"] = feed.now = T0 + 7200
        desk.step()
        t = desk.book["closed"][0]
        self.assertEqual(t["reason"], "Stop (Kurslücke)")
        self.assertLess(t["r"], -1.0)
        store.close()

    def test_target_and_missed_minutes_are_caught_up(self):
        feed = market()
        desk, store, clock = desk_with(feed)
        desk.step()
        target = desk.book["positions"][0]["target"]
        hit = T0 + 3 * DAY + 1234 // 60 * 60
        feed.minute["AAAUSDT"] = lambda t: (113.0, target + 1, 112.5, 113.0) if t == hit else (112.0, 112.1, 111.9, 112.0)
        clock["now"] = feed.now = T0 + 4 * DAY                 # the bot was off for days: the order still filled
        desk.step()
        t = desk.book["closed"][0]
        self.assertEqual((t["reason"], t["closed_at"]), ("Ziel", hit))
        self.assertGreater(t["r"], 1.8)
        self.assertLess(t["r"], 2.0)                            # fees make a 2R target a little less
        store.close()

    def test_time_exit_after_the_holding_period(self):
        feed = market()
        desk, store, clock = desk_with(feed, {"hold_days": 2})
        desk.step()
        clock["now"] = feed.now = T0 + 600 + 2 * DAY + 300
        desk.step()
        self.assertEqual(desk.book["closed"][0]["reason"], "Haltedauer um")
        store.close()

    def test_no_entry_outside_the_window_but_by_hand(self):
        feed = market()
        desk, store, clock = desk_with(feed, now=T0 + 10 * 3600)
        desk.step()
        self.assertEqual(desk.book["positions"], [])
        self.assertIn("nächster Scan morgen", desk.view()["status"])
        desk.scan_now()
        desk.step()
        self.assertEqual(len(desk.book["positions"]), 1)
        self.assertTrue(desk.book["positions"][0]["late"])
        store.close()

    def test_a_slow_scan_still_prices_every_hit(self):
        feed = market()
        feed.ticker.append({"symbol": "CCCUSDT", "lastPrice": "112", "quoteVolume": "8e7", "highPrice": "115",
                            "lowPrice": "100", "priceChangePercent": "12"})
        feed.daily["CCCUSDT"] = breakout_daily()
        feed.minute["CCCUSDT"] = flat(112.0)
        clock = {"now": T0 + 600}

        def slow_tm(args, feed_, now, plan=None):
            clock["now"] += 300                                  # each replay takes minutes on a slow machine
            feed.now = clock["now"]
            return {"mc": {"avg_r": 0.0, "target_first": 0.3, "stop_first": 0.4}, "history": {},
                    "verdict": ["Urteil: Kein klarer Vorsprung: etwa Null nach Gebühren (Ø R +0.000)."]}
        store = Store(Path(tempfile.mkdtemp()) / "bot.sqlite")
        feed.now = clock["now"]
        desk = CryptoDesk(store, {"crypto": {"backtest": False}}, feed=feed, clock=lambda: clock["now"], tm_run=slow_tm,
                          funding=no_funding)
        desk.step()
        self.assertEqual(sorted(p["symbol"] for p in desk.book["positions"]), ["AAAUSDT", "CCCUSDT"])
        self.assertEqual(desk.book["positions"][1]["opened_at"], T0 + 600 + 300)   # priced after the first replay
        store.close()

    def test_one_scan_per_day_and_no_double_position(self):
        feed = market()
        desk, store, clock = desk_with(feed)
        desk.step()
        clock["now"] = feed.now = T0 + 1200
        desk.step()
        desk.scan_now()
        desk.step()
        self.assertEqual(len(desk.book["positions"]), 1)
        self.assertEqual(desk.book["last_scan"]["passed"][0]["why"], "schon im Depot")
        store.close()

    def test_state_survives_a_restart(self):
        feed = market()
        desk, store, clock = desk_with(feed)
        desk.step()
        again = CryptoDesk(store, {"crypto": {"timemachine": False, "backtest": False}}, feed=feed, clock=lambda: clock["now"],
                           funding=no_funding)
        self.assertEqual(len(again.book["positions"]), 1)
        self.assertEqual(again.book["scan_day"], "2026-09-22")
        store.close()

    def test_equity_curve_and_benchmark(self):
        feed = market()
        desk, store, clock = desk_with(feed)
        desk.step()
        feed.minute["BTCUSDT"] = flat(88000.0)
        clock["now"] = feed.now = T0 + 600 + crypto.EQUITY_EVERY_S
        desk.step()
        v = desk.view()
        self.assertEqual(len(v["curve"]), 2)
        self.assertAlmostEqual(v["bench_value"], 1100.0)
        self.assertAlmostEqual(v["bench_pct"], 10.0)
        json.dumps(v)                                            # the dashboard gets it as JSON
        store.close()

    def test_price_outage_keeps_the_position_and_logs_once(self):
        feed = market()
        desk, store, clock = desk_with(feed)
        desk.step()
        feed.fail.add("AAAUSDT")
        for k in range(3):
            clock["now"] = feed.now = T0 + 1200 + 60 * k
            desk.step()
        self.assertEqual(len(desk.book["positions"]), 1)
        errors = [e for e in store.events(50) if e["level"] == "error"]
        self.assertEqual(len(errors), 1)
        store.close()

    def test_switched_off_does_nothing(self):
        feed = market()
        desk, store, clock = desk_with(feed, {"enabled": False})
        desk.step()
        self.assertEqual(desk.book["positions"], [])
        self.assertIn("aus", desk.view()["status"])
        store.close()

    def test_require_hint_uses_the_time_machine(self):
        feed = market()
        calls = []

        def fake_tm(args, feed_, now, plan=None):
            calls.append(plan)
            return {"mc": {"avg_r": -0.1, "target_first": 0.2, "stop_first": 0.5}, "history": {"same": {"n": 40, "avg_r": -0.1, "t": -1}},
                    "verdict": ["Urteil: Kein Vorsprung: im Mittel -0.100 R nach Gebühren."]}
        store = Store(Path(tempfile.mkdtemp()) / "bot.sqlite")
        feed.now = T0 + 600
        desk = CryptoDesk(store, {"crypto": {"backtest": False, "require_hint": True}}, feed=feed,
                          clock=lambda: T0 + 600, tm_run=fake_tm, funding=no_funding)
        desk.step()
        self.assertEqual(desk.book["positions"], [])
        self.assertEqual(calls[0]["rule"], "daily:breakout20")
        self.assertEqual(desk.book["last_scan"]["passed"][0]["why"], "Zeitmaschine sieht keinen Vorsprung")
        self.assertEqual(crypto.verdict_key("Urteil: Schwacher Hinweis, keine Gewissheit"), "schwacher Hinweis")
        store.close()

    def test_carry_collects_funding_once_per_payment(self):
        paid = [(T0 * 1000 + 8 * 3600_000, 0.0001), (T0 * 1000 + 16 * 3600_000, -0.00002)]
        calls = []

        def funding(since_ms):
            calls.append(since_ms)
            return [p for p in paid if p[0] > since_ms]
        feed = market()
        desk, store, clock = desk_with(feed, funding=funding, now=T0 - 3600)
        desk.book["carry"]["since_ms"] = T0 * 1000           # started at midnight
        desk.step()
        c = desk.book["carry"]
        self.assertEqual((c["payments"], c["negative"]), (2, 1))
        self.assertAlmostEqual(c["funding"], 500 * (0.0001 - 0.00002))
        clock["now"] = feed.now = T0 - 3600 + crypto.CARRY_EVERY_S
        desk.step()                                          # asks again, gets nothing new
        self.assertEqual(c["payments"], 2)
        self.assertEqual(calls[-1], T0 * 1000 + 16 * 3600_000)
        v = desk.view()["carry"]
        self.assertAlmostEqual(v["value"], 1000 - 500 * 2 * crypto.CARRY_LEG_COST + 500 * 0.00008)
        self.assertLess(v["pnl"], 0)                          # the fees come first, the funding pays them back over time
        store.close()

    def test_carry_outage_retries_and_logs_once(self):
        def down(since_ms):
            raise RuntimeError("OKX nicht erreichbar")
        feed = market()
        desk, store, clock = desk_with(feed, funding=down, now=T0 - 3600)
        desk.step()
        clock["now"] = feed.now = T0 - 3600 + 600
        desk.step()
        errors = [e for e in store.events(50) if e["level"] == "error"]
        self.assertEqual(len(errors), 1)
        self.assertIn("Cash-and-Carry", desk.view()["status"])
        store.close()

    def test_old_book_gets_a_carry_account(self):
        feed = market()
        desk, store, clock = desk_with(feed)
        book = desk.book
        del book["carry"]
        store.set(crypto.KEY, book)
        again = CryptoDesk(store, {"crypto": {"backtest": False, "timemachine": False}}, feed=feed,
                           clock=lambda: clock["now"], funding=no_funding)
        self.assertEqual(again.book["carry"]["notional"], 500.0)
        store.close()

    def test_reset_starts_a_new_book(self):
        feed = market()
        desk, store, clock = desk_with(feed)
        desk.step()
        self.assertTrue(desk.reset(500)["ok"])
        self.assertEqual((desk.book["cash"], desk.book["positions"]), (500.0, []))
        self.assertFalse(desk.reset(1)["ok"])
        store.close()


class LivePageTests(unittest.TestCase):
    def test_live_page_shows_the_desk_and_its_chart(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("paper_live", ROOT / "tools" / "paper_live.py")
        pl = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(pl)
        feed = market()
        desk, store, clock = desk_with(feed)
        desk.step()
        clock["now"] = feed.now = T0 + 600 + crypto.EQUITY_EVERY_S
        desk.step()
        view = json.loads(json.dumps(desk.view()))
        view["positions"][0]["setup_name"] = "<b>x</b>"
        state = {"candidates": [], "open_positions": [], "closed": [], "stats": {}, "crypto": view}
        with tempfile.TemporaryDirectory() as d:
            pl.write(state, Path(d))
            page = (Path(d) / "index.html").read_text()
            report = (Path(d) / "REPORT.md").read_text()
        self.assertIn("Krypto-Desk", page)
        self.assertIn('<path class=cv-line d="M', page)
        self.assertIn('<path class=cv-carry d="M', page)
        self.assertIn("Cash-and-Carry", page)
        self.assertIn("<title>", page)
        self.assertNotIn("<b>x</b>", page)
        self.assertIn("## Krypto-Desk", report)
        self.assertIn("AAA", report)
        state["crypto"] = None
        with tempfile.TemporaryDirectory() as d:
            pl.write(state, Path(d))
            self.assertNotIn("Krypto-Desk", (Path(d) / "index.html").read_text())
        store.close()


class SnapshotDbTests(unittest.TestCase):
    """tools/snapshot_db.py: the copy that travels between Paper-Live runs stays small, the source untouched."""

    def test_compact_copy_keeps_what_the_runs_need(self):
        import gzip
        import importlib.util
        import sqlite3
        spec = importlib.util.spec_from_file_location("snapshot_db", ROOT / "tools" / "snapshot_db.py")
        sd = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sd)
        now = T0 + 10 * DAY
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "bot.sqlite")
            ids = {}
            for name, seen, decision in (("old_skip", now - 3 * DAY, "skip"), ("old_buy", now - 3 * DAY, "buy"),
                                         ("old_watch", now - 3 * DAY, "watch"), ("old_path", now - 3 * DAY, "skip"),
                                         ("new_skip", now - 3600, "skip")):
                ids[name] = store.add_candidate({"seen_at": seen, "chain": "solana", "token": name, "pair": name,
                                                 "symbol": name, "price_usd": 1.0, "score": 0, "decision": decision,
                                                 "reasons": [], "snapshot": {}})
                store.schedule_outcomes(ids[name], seen, [5])
            # an old skip that lands on the kept sample, and fillers so the plain old skip is not on it
            while ids["old_skip"] % sd.SAMPLE == 0:
                ids["old_skip"] = store.add_candidate({"seen_at": now - 3 * DAY, "chain": "solana", "token": "old_skip",
                                                       "pair": "old_skip", "symbol": "x", "price_usd": 1.0, "score": 0,
                                                       "decision": "skip", "reasons": [], "snapshot": {}})
                store.schedule_outcomes(ids["old_skip"], now - 3 * DAY, [5])
            store.add_path_points([(ids["old_path"], now - 3 * DAY, 1.0), (ids["old_path"], now - 3 * DAY + 60, 1.1)])
            store.set("crypto_desk", {"v": 1, "cash": 123.0})
            store.close()
            src = Path(d) / "bot.sqlite"
            before = src.stat().st_size, src.stat().st_mtime
            counts = sd.snapshot(str(src), str(Path(d) / "out.gz"), now=now)
            self.assertEqual((src.stat().st_size, src.stat().st_mtime), before)       # the live database is never touched
            with gzip.open(Path(d) / "out.gz") as g, open(Path(d) / "copy.sqlite", "wb") as f:
                f.write(g.read())
            db = sqlite3.connect(Path(d) / "copy.sqlite")
            kept = {r[0] for r in db.execute("SELECT id FROM candidates")}
            outcome_ids = {r[0] for r in db.execute("SELECT candidate_id FROM outcomes")}
            kv = db.execute("SELECT value FROM kv WHERE key='crypto_desk'").fetchone()[0]
            db.close()
            self.assertNotIn(ids["old_skip"], kept)
            for name in ("old_buy", "old_watch", "old_path", "new_skip"):
                self.assertIn(ids[name], kept, name)
            self.assertTrue(outcome_ids <= kept)
            self.assertEqual(json.loads(kv)["cash"], 123.0)
            self.assertLess(counts["after"], counts["before"])


if __name__ == "__main__":
    unittest.main()
