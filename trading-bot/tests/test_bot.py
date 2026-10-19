import copy
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
        cfg = copy.deepcopy(CFG); cfg["filters"]["min_age_minutes"] = 1.5
        v = evaluate(fixture("NEW", age_min=1.47), None, cfg)
        self.assertEqual(v["reasons"][0], "too new (1.4 min < 1.5)")     # never "1.5" against a 1.5 minimum

    def test_a_coin_on_its_bonding_curve_is_watched_until_it_trades_in_a_pool(self):
        p = dict(fixture("RUN"), dex="pumpfun", curve=True, liquidity_kind="curve")
        v = evaluate(p, RUG.summary(p["token"]), CFG)
        self.assertEqual(v["decision"], "watch"); self.assertTrue(v["watch_only"])
        self.assertTrue(v["reasons"][0].startswith("still on its bonding curve"), v["reasons"])
        graduated = dict(fixture("RUN"), dex="pumpswap")                       # the same coin after the move
        self.assertEqual(evaluate(graduated, RUG.summary(p["token"]), CFG)["decision"], "buy")
        cfg = copy.deepcopy(CFG); cfg["filters"]["allow_curve_buys"] = True
        self.assertEqual(evaluate(p, RUG.summary(p["token"]), cfg)["decision"], "buy")

    def test_a_pool_far_smaller_than_its_valuation_is_skipped(self):
        """Live: 31-40 % of pools valued over 3x their liquidity crashed by 80 % within the
        hour, 13 % of the rest."""
        p = fixture("RUN")
        thin = dict(p, fdv=p["liquidity_usd"] * 6)
        v = evaluate(thin, RUG.summary(p["token"]), CFG)
        self.assertEqual(v["decision"], "skip")
        self.assertIn("thin pool: valuation 6.0x its liquidity > 3x", v["reasons"])
        self.assertEqual(evaluate(dict(p, fdv=p["liquidity_usd"] * 3), RUG.summary(p["token"]), CFG)["decision"], "buy")
        off = copy.deepcopy(CFG); off["filters"]["max_fdv_liquidity_ratio"] = 0
        self.assertEqual(evaluate(thin, RUG.summary(p["token"]), off)["decision"], "buy")
        curve = dict(thin, dex="pumpfun", curve=True, liquidity_kind="curve")       # a curve is judged on its own terms
        self.assertFalse(any("thin pool" in r for r in evaluate(curve, RUG.summary(p["token"]), CFG)["reasons"]))
        from bot.store import Store
        label = next(lab for needle, lab, _ in Store.REASON_RULES if needle in "thin pool: valuation 6.0x its liquidity > 3x")
        self.assertEqual(label, "Bewertung zu hoch für den Pool")                   # not "FDV zu hoch"

    def test_unlocked_lp_is_a_warning_on_pumpswap_only(self):
        lp = {"score": 52.0, "danger": ["Large Amount of LP Unlocked"], "warn": ["Low amount of LP Providers"], "source": "rugcheck"}
        v = evaluate(dict(fixture("RUN"), dex="pumpswap"), lp, CFG)
        self.assertNotEqual(v["decision"], "skip", v["reasons"])
        self.assertIn("rugcheck", " ".join(v["reasons"]))
        for dex in ("meteora", "raydium"):                                       # live: 3 of 5 such Meteora buys were pulled
            v = evaluate(dict(fixture("RUN"), dex=dex), lp, CFG)
            self.assertEqual(v["decision"], "skip", dex); self.assertIn("LP Unlocked", v["reasons"][0])
        holders = dict(lp, danger=["Large Amount of LP Unlocked", "Top 10 holders high ownership"])
        v = evaluate(dict(fixture("RUN"), dex="pumpswap"), holders, CFG)           # who holds the supply always counts
        self.assertEqual(v["decision"], "skip"); self.assertIn("Top 10 holders", v["reasons"][0])

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
        self.assertNotIn("rugcheck unavailable", " ".join(v["reasons"]))
        self.assertTrue(v["watch_only"])                       # tolerated - but nobody knows the holders
        self.assertTrue(v["reasons"][0].startswith("holder check missing"), v["reasons"])
        cfg["filters"]["require_holder_check"] = False
        v = evaluate(p, None, cfg)
        self.assertFalse(v["watch_only"])                      # both switched off: the score alone decides
        cfg["filters"]["require_holder_check"] = True; cfg["filters"]["require_rugcheck"] = False
        self.assertTrue(evaluate(p, None, cfg)["watch_only"])  # the holder rule stands on its own



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
        self.paper.update(pos, pos["entry_price"] * 1.05, self.t0 + (CFG["exits"]["time_stop_minutes"] + 1) * 60)
        self.assertEqual(self.store.closed_positions()[0]["exit_reason"], "time_stop")

    def test_daily_loss_limit_blocks_entries(self):
        limit = CFG["bankroll_usd"] * CFG["daily_loss_limit_pct"] / 100
        now, n = time.time(), 0
        while -self.paper.daily_pnl() < limit:                  # total losses today, through real sells
            self.assertIsNone(self.paper.can_open("solana", f"T{n}"))
            pid = self.paper.open(dict(self.p, token=f"T{n}"), now)
            self.paper._sell(self.store.position(pid), 1.0, self.p["price_usd"] * 0.01, "stop_loss", now)
            n += 1
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
            for minute in (5, 15, 60):                       # each horizon measured when it is due
                self.assertEqual(tracker.fill_due(now=100.0 + minute * 60 + 5), 1)
            report = store.edge_report()
            self.assertEqual({r["horizon_min"] for r in report}, {5, 15, 60})
            self.assertTrue(all(abs(r["avg_change_pct"] - 100.0) < 1e-6 for r in report))
            # the bot was off for six hours: a price now says nothing about 5, 15 or 60 minutes
            late = tracker.record({"seen_at": 1000.0, "chain": "solana", "token": "t", "pair": "p", "symbol": "T",
                                   "price_usd": 1.0, "score": 70, "decision": "buy", "reasons": [], "snapshot": {}})
            self.assertEqual(tracker.fill_due(now=1000.0 + 6 * 3600), 3)
            self.assertTrue(all(o["change_pct"] is None for o in store.outcomes_for(late)))
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
