import http.client
import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path

from bot.demo import FakeDex, FakeRug
from bot.engine import Engine
from bot.paper import Paper
from bot.server import make_server
from bot.sources.dexscreener import normalize_pair
from bot.store import Store
from bot.strategy import evaluate
from bot.tracker import Tracker

ROOT = Path(__file__).parent.parent
CFG = json.loads((ROOT / "bot" / "config.json").read_text())
FIX = json.loads((ROOT / "tests" / "fixtures" / "pairs.json").read_text())
RUG = FakeRug()


def fixture(symbol, age_min=10.0):
    raw = next(p for p in FIX if p["baseToken"]["symbol"] == symbol)
    raw = {k: v for k, v in raw.items() if k != "_demo"}
    now = time.time()
    raw["pairCreatedAt"] = int((now - age_min * 60) * 1000)
    return normalize_pair(raw, now)


class StrategyTests(unittest.TestCase):
    def test_good_token_is_bought(self):
        p = fixture("RUN")
        v = evaluate(p, RUG.summary(p["token"]), CFG)
        self.assertEqual(v["decision"], "buy", v)
        self.assertGreaterEqual(v["score"], CFG["scoring"]["min_score"])

    def test_too_new_is_skipped(self):
        p = fixture("NEW", age_min=1.0)
        v = evaluate(p, RUG.summary(p["token"]), CFG)
        self.assertEqual(v["decision"], "skip")
        self.assertTrue(any("too new" in r for r in v["reasons"]))

    def test_rug_danger_is_skipped(self):
        p = fixture("HONEY")
        v = evaluate(p, RUG.summary(p["token"]), CFG)
        self.assertEqual(v["decision"], "skip")
        self.assertTrue(any("rugcheck danger" in r for r in v["reasons"]))

    def test_thin_liquidity_and_parabolic_are_skipped(self):
        for sym, needle in (("THIN", "liquidity"), ("LATE", "parabolic")):
            p = fixture(sym)
            v = evaluate(p, RUG.summary(p["token"]), CFG)
            self.assertEqual(v["decision"], "skip", sym)
            self.assertTrue(any(needle in r for r in v["reasons"]), v["reasons"])

    def test_mediocre_is_watched(self):
        p = fixture("MEH")
        v = evaluate(p, RUG.summary(p["token"]), CFG)
        self.assertEqual(v["decision"], "watch", v)

    def test_unknown_rugcheck_means_watch_only(self):
        p = fixture("RUN")
        v = evaluate(p, None, CFG)
        self.assertEqual(v["decision"], "watch")
        self.assertTrue(v["watch_only"]); self.assertGreater(v["score"], 0)
        self.assertTrue(any("rugcheck unavailable" in r for r in v["reasons"]))
        cfg = json.loads(json.dumps(CFG)); cfg["filters"]["allow_rugcheck_unknown"] = True
        v = evaluate(p, None, cfg)
        self.assertFalse(v["watch_only"])                      # tolerated: the score alone decides (rugcheck part is neutral)
        self.assertNotIn("rugcheck unavailable", " ".join(v["reasons"]))



class PaperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite")
        self.paper = Paper(self.store, CFG)
        self.p = fixture("RUN")
        self.t0 = 1_000_000.0

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def _open(self):
        pid = self.paper.open(self.p, self.t0)
        return self.store.open_positions()[0], pid

    def test_bankroll_reflects_entry_fee_immediately(self):
        self._open()
        self.assertLess(self.paper.bankroll(), CFG["bankroll_usd"])

    def test_sizing_from_risk_and_stop(self):
        expected = CFG["bankroll_usd"] * CFG["risk_per_trade_pct"] / 100 / 0.30
        self.assertAlmostEqual(self.paper.position_size(), expected, places=6)

    def test_stop_loss_closes_with_costs(self):
        pos, pid = self._open()
        self.paper.update(pos, pos["entry_price"] * 0.65, self.t0 + 60)
        closed = self.store.closed_positions()[0]
        self.assertEqual(closed["exit_reason"], "stop_loss")
        self.assertLess(closed["realized_usd"], -0.30 * pos["size_usd"])  # worse than -30%: fees+slippage

    def test_ladder_then_trailing(self):
        pos, pid = self._open()
        e = pos["entry_price"]
        self.paper.update(pos, e * 1.55, self.t0 + 60)          # +55% -> first rung sells 50%
        self.assertAlmostEqual(pos["remaining_frac"], 0.5)
        self.paper.update(pos, e * 2.10, self.t0 + 120)         # +110% -> second rung sells 25%
        self.assertAlmostEqual(pos["remaining_frac"], 0.25)
        self.paper.update(pos, e * 1.50, self.t0 + 180)         # -28.6% from peak 2.10 -> trailing
        self.assertEqual(pos["status"], "closed")
        self.assertEqual(self.store.closed_positions()[0]["exit_reason"], "trailing_stop")
        self.assertGreater(self.store.closed_positions()[0]["realized_usd"], 0)

    def test_time_stop(self):
        pos, pid = self._open()
        self.paper.update(pos, pos["entry_price"] * 1.05, self.t0 + 46 * 60)
        self.assertEqual(self.store.closed_positions()[0]["exit_reason"], "time_stop")

    def test_daily_loss_limit_blocks_entries(self):
        pos, pid = self._open()
        self.store.update_position(pid, realized_usd=-CFG["bankroll_usd"] * 0.06,
                                   status="closed", closed_at=time.time())
        self.assertEqual(self.paper.can_open("solana", "x"), "daily loss limit hit")


class EquityCurveTests(unittest.TestCase):
    def test_cumulative_realized_in_time_order(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            paper = Paper(store, CFG)
            p = fixture("RUN")
            for i, (mult, t) in enumerate(((1.6, 100.0), (0.6, 200.0), (1.2, 300.0))):
                pid = paper.open(p, t)
                pos = store.position(pid)
                paper.close_manually(pos, pos["entry_price"] * mult, t + 10)
            curve = store.equity_curve()
            self.assertEqual([r["at"] for r in curve], [110.0, 210.0, 310.0])
            self.assertGreater(curve[0]["cum_realized"], 0)
            self.assertLess(curve[1]["cum_realized"], curve[0]["cum_realized"])
            self.assertAlmostEqual(curve[-1]["cum_realized"], store.realized_all(), places=3)
            store.close()


class TrackerTests(unittest.TestCase):
    def test_fill_due_computes_forward_change(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            tracker = Tracker(store, CFG, lambda chain, pair: 2.0)
            cid = tracker.record({"seen_at": 100.0, "chain": "solana", "token": "t", "pair": "p",
                                  "symbol": "T", "price_usd": 1.0, "score": 70, "decision": "buy",
                                  "reasons": [], "snapshot": {}})
            self.assertEqual(tracker.fill_due(now=100.0 + 4 * 60), 0)
            self.assertEqual(tracker.fill_due(now=100.0 + 61 * 60), 3)
            report = store.edge_report()
            self.assertEqual({r["horizon_min"] for r in report}, {5, 15, 60})
            self.assertTrue(all(abs(r["avg_change_pct"] - 100.0) < 1e-6 for r in report))
            store.close()


class EngineDemoTests(unittest.TestCase):
    def test_full_cycle_opens_and_closes_positions(self):
        import bot.demo as demo
        cycle = demo.CYCLE_MIN
        demo.CYCLE_MIN = 1e9          # one generation only, so the book is empty at the end
        self.addCleanup(setattr, demo, "CYCLE_MIN", cycle)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            dex = FakeDex(accel=1.0)
            engine = Engine(CFG, store, dex, FakeRug(), clock=dex.now)
            # drive the simulated clock by hand instead of waiting
            t = [dex.started]
            dex.now = lambda: t[0]
            engine.clock = dex.now
            first = engine.poll_once()
            self.assertEqual(first["buy"], 1, first)          # RUN is bought, DUMP is only watched
            self.assertGreaterEqual(first["skip"], 3)
            self.assertEqual(len(store.open_positions()), 1)
            for minutes in range(1, 80, 2):
                t[0] = dex.started + minutes * 60
                engine.poll_once()
            self.assertEqual(len(store.open_positions()), 0)
            closed = store.closed_positions()
            self.assertTrue(closed)
            self.assertIn(closed[0]["exit_reason"],
                          {"take_profit_50", "take_profit_100", "trailing_stop", "time_stop", "stop_loss"})
            self.assertTrue(store.edge_report())
            json.dumps(engine.state())  # dashboard payload must be serialisable
            store.close()


class DemoRelistingTests(unittest.TestCase):
    def test_tokens_are_relisted_every_cycle(self):
        from bot.demo import CYCLE_MIN
        dex = FakeDex(accel=1.0)
        t = [dex.started + 5 * 60]                                # every fixture listed by now
        dex.now = lambda: t[0]
        first = dex.recent_token_addresses(["solana"])["solana"]
        t[0] = dex.started + (CYCLE_MIN + 15) * 60
        later = dex.recent_token_addresses(["solana"])["solana"]
        self.assertEqual(len(first), len(later))
        self.assertTrue(all(a.endswith("-g1") for a in later), later)
        run = next(p for p in dex.pairs_for_tokens("solana", later) if p["symbol"] == "RUN")
        self.assertLess(run["age_min"], 60)                      # fresh again
        self.assertIsNotNone(dex.price("solana", run["pair"]))    # new generation priced
        self.assertIsNotNone(dex.price("solana", run["pair"].split("-g")[0]))  # old one still priced
        self.assertIsNotNone(FakeRug().summary(run["token"]))     # rug data found despite suffix


class ServerTests(unittest.TestCase):
    def test_state_and_control(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            dex = FakeDex()
            engine = Engine(CFG, store, dex, FakeRug(), clock=dex.now)
            server = make_server(engine, "127.0.0.1", 0)
            port = server.server_address[1]
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                c.request("GET", "/")
                self.assertIn(b"New-Token Bot", c.getresponse().read())
                c.request("GET", "/api/state")
                state = json.loads(c.getresponse().read())
                self.assertEqual(state["mode"], "paper")
                c.request("POST", "/api/control", body=json.dumps({"action": "pause"}),
                          headers={"Content-Type": "application/json"})
                self.assertTrue(json.loads(c.getresponse().read())["paused"])
                self.assertTrue(engine.paused)
            finally:
                c.close()
                server.shutdown()
                server.server_close()
                store.close()


if __name__ == "__main__":
    unittest.main()
