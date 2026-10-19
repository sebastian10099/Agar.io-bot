import copy
import http.client
import json
import tempfile
import threading
import unittest
from unittest import mock
from pathlib import Path

from bot import settings
from bot.demo import FakeDex, FakeRug
from bot.engine import Engine
from bot.server import make_server
from bot.store import Store

ROOT = Path(__file__).parent.parent
CFG = json.loads((ROOT / "bot" / "config.json").read_text())


class SettingsTests(unittest.TestCase):
    def test_schema_paths_exist_in_config(self):
        for f in settings.SCHEMA:
            self.assertIsNotNone(settings.get_path(CFG, f["path"]), f["path"])

    def test_coercion_and_ranges(self):
        clean, errors = settings.validate({
            "poll_seconds": "30", "risk_per_trade_pct": "1,5", "filters.min_buys_m5": 12.0,
            "filters.require_rugcheck": "off", "chains": "solana, base",
            "exits.take_profit_ladder": "100: 0.25, 50: 0.5",
        })
        self.assertEqual(errors, {})
        self.assertEqual(clean["poll_seconds"], 30)
        self.assertEqual(clean["risk_per_trade_pct"], 1.5)
        self.assertEqual(clean["filters.min_buys_m5"], 12)
        self.assertIs(clean["filters.require_rugcheck"], False)
        self.assertEqual(clean["chains"], ["solana", "base"])
        self.assertEqual(clean["exits.take_profit_ladder"], [[50.0, 0.5], [100.0, 0.25]])

    def test_rejections(self):
        clean, errors = settings.validate({
            "poll_seconds": 1, "filters.min_buys_m5": 2.5, "exits.stop_loss_pct": 5,
            "chains": "solana, dogechain", "exits.take_profit_ladder": "50: 0.7, 100: 0.6",
            "nope": 1, "risk_per_trade_pct": "abc",
        })
        self.assertEqual(clean, {})
        for key in ("poll_seconds", "filters.min_buys_m5", "exits.stop_loss_pct", "chains",
                    "exits.take_profit_ladder", "nope", "risk_per_trade_pct"):
            self.assertIn(key, errors)

    def test_cross_check_blocks_and_leaves_config_untouched(self):
        cfg = copy.deepcopy(CFG)
        errors = settings.apply(cfg, {"filters.min_age_minutes": 500.0})
        self.assertIn("filters.max_age_minutes", errors)
        self.assertEqual(cfg["filters"]["min_age_minutes"], CFG["filters"]["min_age_minutes"])

    def test_apply_in_place(self):
        cfg = copy.deepcopy(CFG)
        self.assertIsNone(settings.apply(cfg, {"exits.stop_loss_pct": -20.0, "paper.fee_pct": 0.5}))
        self.assertEqual(cfg["exits"]["stop_loss_pct"], -20.0)
        self.assertEqual(cfg["paper"]["fee_pct"], 0.5)
        self.assertEqual(settings.flat(cfg)["paper.fee_pct"], 0.5)


class EngineControlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite")
        self.dex = FakeDex(accel=1.0)
        self.t = [self.dex.started]
        self.dex.now = lambda: self.t[0]
        self.cfg = copy.deepcopy(CFG)
        self.engine = Engine(self.cfg, self.store, self.dex, FakeRug(), clock=self.dex.now)
        self.saved = []
        self.engine.persist = self.saved.append

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_config_change_is_live_and_persisted(self):
        r = self.engine.apply_config({"paper.fee_pct": 3, "max_open_positions": 2})
        self.assertTrue(r["ok"], r)
        self.assertEqual(self.engine.paper.fee_pct, 3.0)           # property reads the live dict
        self.assertEqual(self.cfg["max_open_positions"], 2)
        self.assertEqual(self.saved, [{"paper.fee_pct": 3.0, "max_open_positions": 2}])

    def test_bad_config_changes_nothing(self):
        r = self.engine.apply_config({"paper.fee_pct": 3, "poll_seconds": 0})
        self.assertFalse(r["ok"])
        self.assertIn("poll_seconds", r["errors"])
        self.assertEqual(self.engine.paper.fee_pct, 1.0)
        self.assertEqual(self.saved, [])

    def test_manual_close_and_reset(self):
        self.engine.poll_once()
        pos = self.store.open_positions()[0]
        self.assertFalse(self.engine.close_position(999)["ok"])
        r = self.engine.close_position(pos["id"])
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["position"]["exit_reason"], "manual")
        self.assertEqual(self.store.open_positions(), [])
        self.assertEqual(self.engine.close_position(pos["id"])["ok"], False)  # already closed

        self.assertTrue(self.store.candidates())
        self.engine.reset("positions")
        self.assertEqual(self.store.closed_positions(), [])
        self.assertTrue(self.store.candidates())                   # edge data survives
        self.engine.reset("all")
        self.assertEqual(self.store.candidates(), [])
        self.assertFalse(self.engine.reset("everything")["ok"])

    def test_manual_entry_from_candidate(self):
        self.engine.poll_once()
        watch = next(c for c in self.store.candidates() if c["decision"] == "watch")
        r = self.engine.open_from_candidate(watch["id"])
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["position"]["symbol"], watch["symbol"])
        self.assertEqual(self.engine.open_from_candidate(watch["id"])["error"], "Nicht eröffnet: already holding")
        self.assertFalse(self.engine.open_from_candidate(99999)["ok"])
        detail = self.engine.position_detail(r["position"]["id"])
        self.assertTrue(detail["ok"])
        self.assertEqual([t["side"] for t in detail["trades"]], ["buy"])
        self.assertTrue(any("MANUAL BUY" in e["message"] for e in self.store.events()))

    def test_reset_with_bankroll(self):
        self.engine.poll_once()
        r = self.engine.reset("positions", "2500")
        self.assertTrue(r["ok"], r)
        self.assertEqual(self.engine.paper.initial, 2500.0)
        self.assertEqual(self.cfg["bankroll_usd"], 2500.0)
        self.assertIn({"bankroll_usd": 2500.0}, self.saved)
        self.assertEqual(self.store.open_positions(), [])
        self.assertFalse(self.engine.reset("positions", 1)["ok"])
        self.assertFalse(self.engine.reset("positions", "abc")["ok"])
        self.assertEqual(self.engine.paper.initial, 2500.0)

    def test_partial_sell(self):
        self.engine.poll_once()
        pos = self.store.open_positions()[0]
        self.assertFalse(self.engine.sell_position(pos["id"], 0)["ok"])
        self.assertFalse(self.engine.sell_position(pos["id"], "x")["ok"])
        r = self.engine.sell_position(pos["id"], "0,5")
        self.assertTrue(r["ok"], r)
        self.assertAlmostEqual(r["position"]["remaining_frac"], 0.5)
        self.assertEqual(r["position"]["status"], "open")
        self.assertFalse(self.engine.sell_position(pos["id"], 0.75)["ok"])   # more than is left
        r = self.engine.sell_position(pos["id"], 0.5)                          # the rest -> closed
        self.assertEqual(r["position"]["status"], "closed")
        self.assertEqual(r["position"]["exit_reason"], "manual")
        self.assertEqual([t["reason"] for t in self.store.trades_for(pos["id"])], ["entry", "manual_partial", "manual"])

    def test_profiles_roundtrip(self):
        self.assertTrue(self.engine.apply_config({"scoring.min_score": 70})["ok"])
        r = self.engine.save_profile("Streng")
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["profiles"]["Streng"]["scoring.min_score"], 70)
        self.engine.apply_config({"scoring.min_score": 40})
        self.assertEqual(self.cfg["scoring"]["min_score"], 40)
        self.assertTrue(self.engine.apply_profile("Streng")["ok"])
        self.assertEqual(self.cfg["scoring"]["min_score"], 70)
        self.assertFalse(self.engine.apply_profile("gibt es nicht")["ok"])
        self.assertFalse(self.engine.save_profile("")["ok"])
        self.assertFalse(self.engine.save_profile("Kaputt", {"poll_seconds": 0})["ok"])
        self.assertTrue(self.engine.delete_profile("Streng")["ok"])
        self.assertTrue(all(n.startswith("★") for n in self.engine.profiles()))   # only the built-in presets remain
        self.assertFalse(self.engine.delete_profile("Streng")["ok"])

    def test_paused_engine_does_not_open(self):
        self.engine.set_paused(True)
        counts = self.engine.poll_once()
        self.assertEqual(counts["buy"], 0)
        self.assertEqual(self.store.open_positions(), [])
        self.assertTrue(any("not opened: paused" in r for c in self.store.candidates() for r in c["reasons"]))


class FakeAdvisor:
    def __init__(self, verdicts):
        self.verdicts, self.asked = verdicts, []
    def judge(self, pair, rug, rules):
        self.asked.append(pair["symbol"])
        v = self.verdicts.get(pair["symbol"])
        return dict(v, model="fake") if v else None
    def status(self):
        return {"mode": "advise", "available": True, "reason": "", "calls_last_hour": len(self.asked), "calls_total": len(self.asked), "cost_total_usd": 0, "model": "fake", "key_source": "test"}


class AiModeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite")
        self.dex = FakeDex(accel=1.0)
        self.t = [self.dex.started]
        self.dex.now = lambda: self.t[0]
        self.cfg = copy.deepcopy(CFG)

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def engine_with(self, mode, verdicts):
        self.cfg["ai"]["mode"] = mode
        adv = FakeAdvisor(verdicts)
        return Engine(self.cfg, self.store, self.dex, FakeRug(), clock=self.dex.now, advisor=adv), adv

    def test_advise_records_but_rules_decide(self):
        eng, adv = self.engine_with("advise", {"RUN": {"decision": "skip", "confidence": 0.9, "reasons": ["zu heiß"], "risk_flags": ["x"]}})
        counts = eng.poll_once()
        self.assertEqual(counts["buy"], 1)                     # rules still bought RUN
        run = next(c for c in self.store.candidates() if c["symbol"] == "RUN")
        self.assertEqual(run["snapshot"]["ai_decision"], "skip")
        self.assertEqual(run["snapshot"]["rule_decision"], "buy")
        self.assertTrue(any(r.startswith("KI skip") for r in run["reasons"]))
        self.assertNotIn("HONEY", adv.asked)                   # hard-filter skips never reach the model
        self.assertIn("DUMP", adv.asked)                        # watch candidates do

    def test_decide_mode_lets_ai_buy_and_veto(self):
        eng, adv = self.engine_with("decide", {"RUN": {"decision": "watch", "confidence": 0.9, "reasons": [], "risk_flags": []},
                                               "DUMP": {"decision": "buy", "confidence": 0.8, "reasons": ["Kaufdruck"], "risk_flags": []},
                                               "MEH": {"decision": "buy", "confidence": 0.3, "reasons": [], "risk_flags": []}})
        counts = eng.poll_once()
        by = {c["symbol"]: c for c in self.store.candidates()}
        self.assertEqual(by["RUN"]["decision"], "watch")        # AI vetoed the rules' buy
        self.assertEqual(by["DUMP"]["decision"], "buy")         # AI bought what the rules only watched
        self.assertEqual(by["MEH"]["decision"], "watch")        # below min_confidence
        self.assertTrue(any("unter Schwelle" in r for r in by["MEH"]["reasons"]))
        self.assertEqual(counts["buy"], 1)

    def test_unavailable_advisor_changes_nothing(self):
        eng, adv = self.engine_with("decide", {})
        counts = eng.poll_once()
        self.assertEqual(counts["buy"], 1)
        run = next(c for c in self.store.candidates() if c["symbol"] == "RUN")
        self.assertNotIn("ai_decision", run["snapshot"])

    def test_edge_report_by_ai_and_rules(self):
        eng, adv = self.engine_with("advise", {"RUN": {"decision": "skip", "confidence": 0.9, "reasons": [], "risk_flags": []},
                                               "DUMP": {"decision": "buy", "confidence": 0.9, "reasons": [], "risk_flags": []}})
        eng.poll_once()
        for minute in (5, 15, 60):                         # the tracker measures each horizon when it is due
            self.t[0] = self.dex.started + minute * 60 + 5
            eng.poll_once()
        ai = {(r["decision"], r["horizon_min"]) for r in self.store.edge_report("ai_decision")}
        self.assertIn(("buy", 5), ai)
        self.assertIn(("skip", 5), ai)
        rules = {r["decision"] for r in self.store.edge_report("rule_decision")}
        self.assertEqual(rules, {"buy", "watch", "skip"})
        state = eng.state()
        self.assertIn("edge_ai", state)
        self.assertEqual(state["ai"]["mode"], "advise")

    def test_ai_settings_validate(self):
        from bot import settings
        clean, errors = settings.validate({"ai.mode": "decide", "ai.effort": "high", "ai.model": " claude-opus-5-5 ", "ai.min_confidence": "0,7"})
        self.assertEqual(errors, {})
        self.assertEqual(clean["ai.model"], "claude-opus-5-5")
        clean, errors = settings.validate({"ai.mode": "yolo", "ai.model": "", "ai.max_calls_per_hour": 0})
        self.assertEqual(set(errors), {"ai.mode", "ai.model", "ai.max_calls_per_hour"})


class SweepTests(unittest.TestCase):
    def test_sweep_finds_stricter_liquidity_when_thin_tokens_lose(self):
        from bot import sweep
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            dex = FakeDex(accel=1.0)
            t = [dex.started]
            dex.now = lambda: t[0]
            eng = Engine(copy.deepcopy(CFG), store, dex, FakeRug(), clock=dex.now)
            # twelve polls, 31 min apart: every re-listed generation is caught young once,
            # so the rule-eligible tokens appear often enough to clear MIN_N
            for i in range(12):
                eng.poll_once()
                t[0] += 31 * 60      # past the re-see window: same tokens, fresh candidates
            self.assertGreaterEqual(len(store.candidates()), 12)
            # thin-liquidity tokens lose, rich ones win - the sweep should prefer a higher floor
            for c in store.candidates():
                liq = c["snapshot"]["liquidity_usd"]
                store.fill_outcome(c["id"], 15, 1.0, 25.0 if liq >= 60000 else -20.0)
            result = eng.sweep(15)
            self.assertEqual(result["horizon_min"], 15)
            self.assertGreater(result["n_candidates"], 0)
            liq = next(p for p in result["params"] if p["path"] == "filters.min_liquidity_usd")
            self.assertIsNotNone(liq["best"])
            # 40k and 60k admit the same (winning) tokens; the tie breaks toward the smaller change
            self.assertEqual(liq["best"], 40000)
            self.assertGreater(liq["best_avg_ret"], liq["current_avg_ret"])
            self.assertTrue(any(r["current"] for r in liq["values"]))
            self.assertIn("filters.max_price_change_m5_pct", [p["path"] for p in result["params"]])
            # unknown horizon falls back to a tracked one
            self.assertIn(eng.sweep(999)["horizon_min"], result["horizons"])
            store.close()

    def test_sweep_empty(self):
        from bot import sweep
        r = sweep.run([], copy.deepcopy(CFG))
        self.assertEqual(r["n_candidates"], 0)
        self.assertEqual(r["params"], [])


class ControlApiTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite")
        dex = FakeDex()
        self.engine = Engine(copy.deepcopy(CFG), self.store, dex, FakeRug(), clock=dex.now)
        self.server = make_server(self.engine, "127.0.0.1", 0)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.c = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=5)

    def tearDown(self):
        self.c.close()
        self.server.shutdown()
        self.server.server_close()
        self.store.close()
        self.tmp.cleanup()

    def call(self, method, path, body=None):
        self.c.request(method, path, body=json.dumps(body) if body is not None else None,
                       headers={"Content-Type": "application/json"})
        r = self.c.getresponse()
        return r.status, json.loads(r.read())

    def test_the_paper_live_page_is_shown_sandboxed(self):
        """/live shows the GitHub test's page inside the app - with a way back, without scripts
        and in its own origin, so a page from elsewhere can never steer the bot."""
        from bot import livepage
        livepage._cache.update(at=0.0, body=b"")
        self.addCleanup(livepage._cache.update, at=0.0, body=b"")
        sample = b"<html><body><main><h1>Paper-Live</h1></main></body></html>"
        with mock.patch.object(livepage, "_fetch", lambda url: sample):
            self.c.request("GET", "/live")
            r = self.c.getresponse(); body = r.read()
        self.assertEqual(r.status, 200)
        self.assertIn(b"zur\xc3\xbcck zur Steuerung", body); self.assertIn(b"<h1>Paper-Live</h1>", body)
        csp = r.getheader("Content-Security-Policy") or ""
        self.assertTrue(csp.startswith("sandbox"), csp); self.assertNotIn("allow-scripts", csp)
        self.assertNotIn("allow-same-origin", csp)
        livepage._cache.update(at=0.0)                                         # GitHub gone: the last good page
        def down(url): raise OSError("offline")
        self.assertIn(b"<h1>Paper-Live</h1>", livepage.page(fetch=down))
        livepage._cache.update(at=0.0, body=b"")                               # never fetched: says why
        self.assertIn("nicht erreichbar", livepage.page(fetch=down).decode("utf-8"))
        self.assertIn("nicht erreichbar", livepage.page(fetch=lambda url: b"404: Not Found").decode("utf-8"))

    def test_schema_config_defaults(self):
        status, schema = self.call("GET", "/api/schema")
        self.assertEqual(status, 200)
        self.assertEqual(set(schema["groups"]), set(settings.GROUPS))
        status, cfg = self.call("GET", "/api/config")
        self.assertEqual(cfg["config"]["poll_seconds"], CFG["poll_seconds"])
        status, d = self.call("GET", "/api/defaults")
        self.assertEqual(d["config"], settings.flat(CFG))

    def test_config_roundtrip_and_validation(self):
        status, r = self.call("POST", "/api/config", {"patch": {"scoring.min_score": 70}})
        self.assertEqual(status, 200)
        self.assertEqual(r["config"]["scoring.min_score"], 70)
        status, r = self.call("POST", "/api/config", {"patch": {"scoring.min_score": 500}})
        self.assertEqual(status, 422)
        self.assertIn("scoring.min_score", r["errors"])
        self.assertEqual(self.engine.cfg["scoring"]["min_score"], 70)

    def test_control_close_reset(self):
        status, r = self.call("POST", "/api/control", {"action": "poll"})
        self.assertTrue(r["ok"])
        status, r = self.call("POST", "/api/control", {"action": "dance"})
        self.assertEqual(status, 400)
        self.engine.poll_once()
        pid = self.store.open_positions()[0]["id"]
        status, r = self.call("POST", "/api/positions/close", {"id": pid})
        self.assertEqual(status, 200, r)
        status, r = self.call("POST", "/api/positions/close", {"id": pid})
        self.assertEqual(status, 409)
        status, r = self.call("POST", "/api/reset", {"what": "all"})
        self.assertEqual(status, 200)
        self.assertEqual(self.store.candidates(), [])
        status, state = self.call("GET", "/api/state")
        self.assertIn("paper.fee_pct", state["config"])
        self.assertIn("started_at", state)

    def test_sweep_route(self):
        status, r = self.call("GET", "/api/sweep?horizon=15")
        self.assertEqual(status, 200)
        self.assertEqual(r["horizon_min"], 15)
        self.assertIn("params", r)

    def test_profiles_and_export_routes(self):
        status, r = self.call("POST", "/api/profiles", {"name": "Test"})
        self.assertEqual(status, 200, r)
        status, r = self.call("GET", "/api/profiles")
        self.assertIn("Test", r["profiles"])
        status, r = self.call("POST", "/api/profiles/apply", {"name": "Test"})
        self.assertEqual(status, 200)
        status, r = self.call("POST", "/api/profiles/apply", {"name": "nope"})
        self.assertEqual(status, 404)
        status, r = self.call("POST", "/api/profiles/delete", {"name": "Test"})
        self.assertEqual(status, 200)
        self.engine.poll_once()
        for path, needle in (("/api/export/trades.csv", "position_id"), ("/api/export/positions.csv", "entry_price"),
                             ("/api/export/candidates.csv", "decision")):
            self.c.request("GET", path)
            resp = self.c.getresponse()
            text = resp.read().decode("utf-8-sig")
            self.assertEqual(resp.status, 200)
            self.assertTrue(resp.getheader("Content-Type").startswith("text/csv"))
            self.assertIn(needle, text.splitlines()[0])
            self.assertGreater(len(text.splitlines()), 1, path)

    def test_manual_open_detail_and_bankroll_routes(self):
        self.engine.poll_once()
        watch = next(c for c in self.store.candidates() if c["decision"] == "watch")
        status, r = self.call("POST", "/api/positions/open", {"candidate_id": watch["id"]})
        self.assertEqual(status, 200, r)
        pid = r["position"]["id"]
        status, r = self.call("POST", "/api/positions/open", {"candidate_id": watch["id"]})
        self.assertEqual(status, 409)
        status, d = self.call("GET", f"/api/positions/{pid}")
        self.assertEqual(status, 200)
        self.assertEqual(len(d["trades"]), 1)
        status, r = self.call("POST", "/api/positions/sell", {"id": pid, "frac": 0.25})
        self.assertEqual(status, 200, r)
        self.assertAlmostEqual(r["position"]["remaining_frac"], 0.75)
        status, r = self.call("POST", "/api/positions/sell", {"id": pid, "frac": 2})
        self.assertEqual(status, 409)
        status, d = self.call("GET", "/api/positions/424242")
        self.assertEqual(status, 404)
        status, r = self.call("POST", "/api/reset", {"what": "positions", "bankroll": 750})
        self.assertEqual(status, 200)
        self.assertEqual(r["initial"], 750.0)
        status, r = self.call("POST", "/api/reset", {"what": "positions", "bankroll": 0})
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()


class WatchOnlyTests(unittest.TestCase):
    def test_ai_decide_cannot_buy_without_rugcheck(self):
        class NoRug:
            def summary(self, mint): return None
            def health(self): return {"calls": 1, "fails": 1, "last_error": "down", "ok": False}
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0)
            cfg = copy.deepcopy(CFG); cfg["ai"]["mode"] = "decide"
            adv = FakeAdvisor({"RUN": {"decision": "buy", "confidence": 0.95, "reasons": ["top"], "risk_flags": []}})
            eng = Engine(cfg, store, dex, NoRug(), clock=dex.now, advisor=adv)
            counts = eng.poll_once()
            self.assertEqual(counts["buy"], 0)
            run = next(c for c in store.candidates() if c["symbol"] == "RUN")
            self.assertEqual(run["decision"], "watch"); self.assertEqual(run["snapshot"]["ai_decision"], "buy")
            self.assertTrue(any("rugcheck unavailable" in r for r in run["reasons"]))
            self.assertEqual(store.open_positions(), [])
            store.close()
