"""Offline-Tests für crypto-scanner und crypto-timemachine (keine Netzverbindung)."""
import contextlib
import importlib.util
import io
import json
import math
import os
import random
import shutil
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


scan = _load("crypto_scan_test", "crypto-scanner/scan.py")
tm = _load("crypto_tm_test", "crypto-timemachine/timemachine.py")

DAY = 86400
T0 = 1790000000 - 1790000000 % DAY  # ein UTC-Mitternacht


def kline(t, o, h, l, c, step, qv=1e6):
    return [t * 1000, str(o), str(h), str(l), str(c), "1", (t + step) * 1000 - 1, str(qv), 1, "0", "0", "0"]


def walk_series(n, step, start=100.0, seed=1, drift=0.0, vol=0.01, t0=T0):
    rng = random.Random(seed)
    rows, p = [], start
    for k in range(n):
        o = p
        c = o * math.exp(drift + rng.gauss(0, vol))
        h = max(o, c) * (1 + abs(rng.gauss(0, vol / 2)))
        l = min(o, c) * (1 - abs(rng.gauss(0, vol / 2)))
        rows.append(kline(t0 + k * step, o, h, l, c, step))
        p = c
    return rows


def ticker(sym, price, qv, hi=None, lo=None, chg=0.0):
    return {"symbol": sym, "lastPrice": str(price), "quoteVolume": str(qv),
            "highPrice": str(hi if hi is not None else price * 1.05),
            "lowPrice": str(lo if lo is not None else price * 0.95), "priceChangePercent": str(chg)}


class OfflineDir:
    def __init__(self):
        self.path = tempfile.mkdtemp(prefix="crypto-test-")

    def put(self, name, data):
        with open(os.path.join(self.path, name), "w", encoding="utf-8") as f:
            json.dump(data, f)

    def close(self):
        shutil.rmtree(self.path, ignore_errors=True)


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def run_quiet(fn, argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = fn(argv)
    return code, buf.getvalue()


class UniverseTests(unittest.TestCase):
    def setUp(self):
        self.off = OfflineDir()
        self.off.put("ticker24hr.json", [
            ticker("BTCUSDT", 84000, 2e9), ticker("ETHUSDT", 3000, 9e8), ticker("USDCUSDT", 1.0, 3e9),
            ticker("NVDABUSDT", 220, 9e7), ticker("TMFBUSDT", 40, 8e7), ticker("BNBUSDT", 750, 7e7),
            ticker("TRBUSDT", 18, 6e6), ticker("ARBUSDT", 0.2, 2e7), ticker("NEWUSDUSDT", 1.0, 5e7, 1.004, 0.997),
            ticker("BTCUPUSDT", 5, 9e6), ticker("TINYUSDT", 1, 1e5), ticker("ETHBTC", 0.03, 9e9),
            ticker("DEADUSDT", 1, 9e7),
        ])
        self.off.put("exchangeInfo.json", {"symbols": [
            {"symbol": s, "baseAsset": s[:-4], "status": "TRADING",
             "permissionSets": [["SPOT", "TRD_GRP_261"]] if s == "NVDABUSDT" else [["SPOT", "TRD_GRP_004"]]}
            for s in ("BTCUSDT", "ETHUSDT", "USDCUSDT", "NVDABUSDT", "TMFBUSDT", "BNBUSDT", "TRBUSDT", "ARBUSDT",
                      "NEWUSDUSDT", "BTCUPUSDT", "TINYUSDT")
        ] + [{"symbol": "DEADUSDT", "baseAsset": "DEAD", "status": "BREAK", "permissionSets": [["SPOT"]]}]})
        self.feed = scan.Feed(self.off.path, pause=0)

    def tearDown(self):
        self.off.close()

    def test_keeps_only_crypto_sorted_by_volume(self):
        rows, skipped = scan.universe(self.feed, top=10, min_volume=5e6)
        self.assertEqual([r["symbol"] for r in rows], ["BTCUSDT", "ETHUSDT", "BNBUSDT", "ARBUSDT", "TRBUSDT"])
        self.assertEqual(skipped.get("Aktien-Token"), 1)               # NVDAB über die Handelsgruppe
        self.assertEqual(skipped.get("Aktien-Token (vermutlich)"), 1)  # TMFB über die Endung B
        self.assertEqual(skipped.get("Stablecoin/Fiat/Gold/Wrapper"), 2)
        self.assertEqual(skipped.get("Hebel-Token"), 1)

    def test_keep_and_exclude(self):
        rows, _ = scan.universe(self.feed, top=10, min_volume=5e6, exclude={"ETH"}, keep={"TMFB"})
        syms = [r["symbol"] for r in rows]
        self.assertNotIn("ETHUSDT", syms)
        self.assertIn("TMFBUSDT", syms)

    def test_universe_cli_writes_file(self):
        out = tempfile.mkdtemp()
        try:
            code, text = run_quiet(scan.main, ["universe", "--offline", self.off.path, "--out", out, "--top", "3"])
            self.assertEqual(code, 0)
            self.assertIn("3 Krypto-Paare", text)
            self.assertEqual(scan.read_universe(os.path.join(out, "universe.txt")), ["BTCUSDT", "ETHUSDT", "BNBUSDT"])
        finally:
            shutil.rmtree(out)


class MathTests(unittest.TestCase):
    def test_stop_is_exactly_minus_one_r(self):
        self.assertAlmostEqual(scan.r_net(100, 95, 95), -1.0)
        self.assertAlmostEqual(scan.r_net(100, 95, 95, 0, 0), -1.0)

    def test_fees_shrink_the_target(self):
        gross = scan.r_net(100, 95, 110, 0, 0)
        net = scan.r_net(100, 95, 110)
        self.assertAlmostEqual(gross, 2.0)
        self.assertLess(net, 1.95)
        self.assertLess(scan.r_net(100, 95, 100), 0)  # zurück zum Einstieg kostet die Gebühren

    def test_bad_stop_raises(self):
        with self.assertRaises(ValueError):
            scan.r_net(100, 101, 105)

    def test_walk_stop_first_on_a_bar_that_touches_both(self):
        B = {"o": [100, 100], "h": [100, 120], "l": [100, 80], "c": [100, 100]}
        self.assertEqual(scan.walk(B, 1, 100, 95, 110, 5)[:2], ("stop", 95))

    def test_walk_gap_below_stop_fills_at_open(self):
        B = {"o": [100, 100, 90], "h": [101, 101, 91], "l": [99, 99, 85], "c": [100, 100, 88]}
        self.assertEqual(scan.walk(B, 1, 100, 95, 110, 5)[:2], ("stop", 90))

    def test_walk_target_never_better_than_target(self):
        B = {"o": [100, 100, 115], "h": [101, 101, 118], "l": [99, 99, 114], "c": [100, 100, 116]}
        self.assertEqual(scan.walk(B, 1, 100, 95, 110, 5)[:2], ("target", 110))

    def test_walk_neither_exits_at_last_close(self):
        B = {"o": [100] * 4, "h": [101] * 4, "l": [99] * 4, "c": [100, 100, 100, 102]}
        self.assertEqual(scan.walk(B, 1, 100, 95, 110, 3), ("neither", 102, 3))

    def test_rsi_and_atr(self):
        up = [float(i) for i in range(1, 40)]
        self.assertEqual(scan.rsi_series(up)[-1], 100.0)
        down = [float(i) for i in range(40, 1, -1)]
        self.assertLess(scan.rsi_series(down)[-1], 1)
        atr = scan.atr_series([11.0] * 30, [9.0] * 30, [10.0] * 30)
        self.assertAlmostEqual(atr[-1], 2.0)

    def test_px_has_no_scientific_notation(self):
        self.assertEqual(scan.px(0.00000456), "0.00000456")
        self.assertEqual(scan.px(84488.0), "84488")
        self.assertEqual(scan.px(25.92), "25.92")


def daily_bars(closes, t0=T0):
    rows = []
    for k, c in enumerate(closes):
        o = closes[k - 1] if k else c
        rows.append(kline(t0 + k * DAY, o, max(o, c) * 1.01, min(o, c) * 0.99, c, DAY))
    return scan.bars(rows)


class SetupTests(unittest.TestCase):
    def fire(self, closes):
        B = daily_bars(closes)
        rsi, ma20, _ = scan.indicators(B)
        return scan.setups_at(B, len(closes) - 1, rsi, ma20)

    def test_breakout20(self):
        closes = [100 + (k % 3) for k in range(40)] + [110]
        self.assertIn("breakout20", self.fire(closes))

    def test_oversold_and_bounce(self):
        closes = [100 * 0.97 ** k for k in range(40)]
        self.assertIn("oversold", self.fire(closes))
        hits = self.fire(closes + [closes[-1] * 1.03])
        self.assertIn("oversold_bounce", hits)

    def test_reclaim_ma20(self):
        closes = [100.0] * 30 + [99 - k for k in range(10)] + [101.0]
        self.assertIn("reclaim_ma20", self.fire(closes))

    def test_bull_flag(self):
        closes = [100.0] * 30 + [100 + 4 * k for k in range(1, 11)] + [139, 138.5, 139.5, 138.8, 139.2]
        self.assertIn("bull_flag", self.fire(closes))

    def test_quiet_market_fires_nothing_but_maybe_ma(self):
        closes = [100 + (k % 2) * 0.5 for k in range(60)]
        self.assertNotIn("breakout20", self.fire(closes))
        self.assertNotIn("oversold", self.fire(closes))


class ScanCliTests(unittest.TestCase):
    def setUp(self):
        self.off = OfflineDir()
        self.out = tempfile.mkdtemp()
        closes = [100 + (k % 3) for k in range(80)] + [112]
        self.off.put("AAAUSDT_1d.json", [kline(T0 + k * DAY, closes[k - 1] if k else c, c * 1.01, c * 0.99, c, DAY)
                                         for k, c in enumerate(closes)])
        self.off.put("BBBUSDT_1d.json", walk_series(400, DAY, seed=4, vol=0.04))
        self.now = T0 + len(closes) * DAY + 3600

    def tearDown(self):
        self.off.close()
        shutil.rmtree(self.out)

    def now_text(self, ts):
        import datetime
        return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M")

    def test_daily_writes_watchlist_with_plan(self):
        code, text = run_quiet(scan.main, ["daily", "--symbols", "AAA", "--offline", self.off.path,
                                           "--out", self.out, "--now", self.now_text(self.now)])
        self.assertEqual(code, 0, text)
        doc = read_json(os.path.join(self.out, "watchlist.json"))
        plan = doc["hits"][0]["plan"]
        self.assertEqual(plan["rule"], "daily:breakout20")
        self.assertLess(plan["stop"], plan["entry"])
        self.assertAlmostEqual(plan["target"] - plan["entry"], 2 * (plan["entry"] - plan["stop"]), delta=0.03)

    def test_daily_ignores_unfinished_candle(self):
        # Um 00:30 ist die Kerze des Tages noch offen: der Scan nimmt die von gestern.
        code, text = run_quiet(scan.main, ["daily", "--symbols", "AAA", "--offline", self.off.path, "--out", self.out,
                                           "--now", self.now_text(T0 + 80 * DAY + 1800), "--no-write", "--json"])
        doc = json.loads(text)
        self.assertNotIn("breakout20", sum((h["setups"] for h in doc["hits"]), []))
        self.assertEqual(doc["hits"][0]["close"], 101.0)

    def test_backtest_runs_and_compares_with_every_day(self):
        code, text = run_quiet(scan.main, ["backtest", "--symbols", "BBB", "--offline", self.off.path,
                                           "--out", self.out, "--now", self.now_text(T0 + 401 * DAY)])
        self.assertEqual(code, 0, text)
        doc = read_json(os.path.join(self.out, "backtest.json"))
        every = [r for r in doc["table"] if r["setup"] == "alle_tage"][0]
        self.assertEqual(every["n"], 400 - 30 - 10)
        self.assertIn("jeder Tag (Vergleich)", text)


class OrbTests(unittest.TestCase):
    def day(self, t0, breakout=True):
        rows, p = [], 100.0
        for k in range(288):
            t = t0 + k * 300
            if k < 12:
                o, c = p, p + (0.2 if k % 2 else -0.2)
            elif breakout and k == 20:
                o, c = p, 101.5
            else:
                o, c = p, p
            rows.append(kline(t, o, max(o, c) + 0.05, min(o, c) - 0.05, c, 300))
            p = c
        return rows

    def test_orb_day_finds_first_close_above_range(self):
        B = scan.bars(self.day(T0))
        res = scan.orb_day(B, T0, 60)
        self.assertEqual(res["trigger"], 20)
        self.assertAlmostEqual(res["high"], max(B["h"][:12]))

    def test_orb_day_respects_clock(self):
        B = scan.bars(self.day(T0))
        self.assertIsNone(scan.orb_day(B, T0, 60, cut_ts=T0 + 20 * 300)["trigger"])

    def test_orb_cli_writes_plan(self):
        off, out = OfflineDir(), tempfile.mkdtemp()
        try:
            off.put("OOOUSDT_5m.json", self.day(T0))
            code, text = run_quiet(scan.main, ["orb", "--symbols", "OOO", "--offline", off.path, "--out", out,
                                               "--now", scan.utc_text(T0 + 6 * 3600)[:16]])
            self.assertEqual(code, 0, text)
            plan = read_json(os.path.join(out, "watchlist.json"))["hits"][0]["plan"]
            self.assertEqual((plan["rule"], plan["entry"], plan["or_minutes"]), ("orb", 101.5, 60))
            self.assertLess(plan["stop"], plan["entry"])
            code, text = run_quiet(scan.main, ["orb", "--symbols", "OOO", "--offline", off.path, "--out", out,
                                               "--now", scan.utc_text(T0 + 1800)[:16]])
            self.assertEqual(code, 1)
            self.assertIn("läuft noch", text)
        finally:
            off.close()
            shutil.rmtree(out)

    def test_no_breakout(self):
        B = scan.bars(self.day(T0, breakout=False))
        self.assertIsNone(scan.orb_day(B, T0, 60)["trigger"])


class TimeMachineTests(unittest.TestCase):
    def setUp(self):
        self.off = OfflineDir()
        self.out = tempfile.mkdtemp()
        self.rows = walk_series(30 * 288, 300, start=100, seed=7, vol=0.002)
        self.off.put("ZZZUSDT_5m.json", self.rows)
        self.now = T0 + 30 * DAY

    def tearDown(self):
        self.off.close()
        shutil.rmtree(self.out)

    def test_pool_neutral_has_no_drift(self):
        rows = walk_series(20 * 288, 300, seed=3, drift=0.001, vol=0.002)
        B = scan.bars(rows)
        pool, drift, n = tm.build_pool(B, 300, T0 + 21 * DAY)
        self.assertAlmostEqual(drift, 0.001, delta=0.0003)
        self.assertEqual(len(pool), 288)
        for b in tm.buckets(pool, 2):
            self.assertAlmostEqual(sum(x[3] for x in b) / len(b), 1.0, places=9)
        kept = tm.buckets(pool, 2, neutral=False)
        self.assertGreater(sum(x[3] for b in kept for x in b) / sum(len(b) for b in kept), 1.0005)

    def test_pool_skips_gaps_and_future(self):
        rows = walk_series(3 * 288, 300, seed=3)
        del rows[100]
        B = scan.bars(rows)
        _, _, n = tm.build_pool(B, 300, T0 + 2 * DAY)
        self.assertEqual(n, 2 * 288 - 3)  # die gelöschte Kerze, die erste und die nach der Lücke fehlen

    def test_simulation_is_repeatable_and_consistent(self):
        B = scan.bars(self.rows)
        pool, _, _ = tm.build_pool(B, 300, self.now)
        bk = tm.buckets(pool, 2)
        a = tm.simulate(bk, 0, 288, 100, 98, 104, 0.1, 0.05, replays=500, seed=19)
        b = tm.simulate(bk, 0, 288, 100, 98, 104, 0.1, 0.05, replays=500, seed=19)
        self.assertEqual(a, b)
        self.assertAlmostEqual(a["target_first"] + a["stop_first"] + a["neither"], 1.0)
        self.assertLessEqual(a["end_p5"], a["end_p50"])
        self.assertLessEqual(a["end_p50"], a["end_p95"])

    def test_driftless_pool_loses_about_the_fees(self):
        B = scan.bars(self.rows)
        pool, _, _ = tm.build_pool(B, 300, self.now)
        mc = tm.simulate(tm.buckets(pool, 2), 0, 288, 100, 98, 104, 0.1, 0.05, replays=3000, seed=5)
        self.assertLess(mc["avg_r"], 0.05)

    def test_cli_manual_plan_offline(self):
        code, text = run_quiet(tm.main, ["run", "--symbol", "ZZZ", "--entry", "100", "--stop-pct", "2", "--target-r", "2",
                                         "--hours", "6", "--replays", "300", "--offline", self.off.path,
                                         "--out", self.out, "--now", scan.utc_text(self.now)[:16], "--write"])
        self.assertEqual(code, 0, text)
        self.assertIn("Seed 19", text)
        self.assertIn("Urteil:", text)
        doc = read_json(os.path.join(self.out, "timemachine.json"))
        self.assertEqual(doc["plan"]["rule"], "manual")
        self.assertEqual(doc["mc"]["bars"], 72)

    def test_verdict_no_edge_when_sim_negative_and_no_history(self):
        mc = {"avg_r": -0.12, "target_first": 0.2, "stop_first": 0.5, "neither": 0.3}
        lines = tm.verdict(mc, 1.6, {"same": {"n": 5, "avg_r": 0.4}})
        self.assertTrue(lines[0].startswith("Urteil: Kein Vorsprung"))

    def test_verdict_weak_hint_needs_enough_history_beating_every_day(self):
        mc = {"avg_r": 0.0, "target_first": 0.3, "stop_first": 0.4, "neither": 0.3}
        good = {"same": {"n": 50, "avg_r": 0.4, "t": 2.3}, "every": {"n": 900, "avg_r": -0.05}}
        self.assertIn("Schwacher Hinweis", tm.verdict(mc, 1.6, good)[0])
        small = {"same": {"n": 50, "avg_r": 0.02, "t": 2.5}, "every": {"n": 900, "avg_r": -0.05}}
        self.assertNotIn("Schwacher Hinweis", tm.verdict(mc, 1.6, small)[0])
        noisy = {"same": {"n": 80, "avg_r": 0.25, "t": 1.6}, "every": {"n": 900, "avg_r": -0.05}}
        self.assertNotIn("Schwacher Hinweis", tm.verdict(mc, 1.6, noisy)[0])

    def test_tally_t_value(self):
        res = tm.tally([("target", 2.0), ("stop", -1.0), ("target", 2.0), ("stop", -1.0)])
        self.assertAlmostEqual(res["avg_r"], 0.5)
        self.assertAlmostEqual(res["t"], 0.5 / (math.sqrt(3) / 2))

    def test_bad_plan_is_refused(self):
        with self.assertRaises(SystemExit):
            tm.check_plan({"entry": 100, "stop": 101, "target": 110})


if __name__ == "__main__":
    unittest.main()
