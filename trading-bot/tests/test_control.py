import copy
import http.client
import json
import tempfile
import threading
import unittest
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

    def test_paused_engine_does_not_open(self):
        self.engine.set_paused(True)
        counts = self.engine.poll_once()
        self.assertEqual(counts["buy"], 0)
        self.assertEqual(self.store.open_positions(), [])
        self.assertTrue(any("not opened: paused" in r for c in self.store.candidates() for r in c["reasons"]))


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
        status, d = self.call("GET", "/api/positions/424242")
        self.assertEqual(status, 404)
        status, r = self.call("POST", "/api/reset", {"what": "positions", "bankroll": 750})
        self.assertEqual(status, 200)
        self.assertEqual(r["initial"], 750.0)
        status, r = self.call("POST", "/api/reset", {"what": "positions", "bankroll": 0})
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()
