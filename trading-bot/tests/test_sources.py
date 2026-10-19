import copy
import json
import os
import threading
import tempfile
import time
import unittest
from pathlib import Path

from bot import settings
from bot.demo import FakeDex, FakeRug, demo_feeds
from bot.discovery import DexScreenerFeed, Discovery
from bot.engine import Engine
from bot.sources.geckoterminal import GeckoTerminal, normalize_pool
from bot.store import Store

ROOT = Path(__file__).parent.parent
CFG = json.loads((ROOT / "bot" / "config.json").read_text())

NOW = 1_800_000_000.0


def gecko_payload(pools):
    """Shape of GET /networks/{net}/new_pools?include=base_token."""
    data, included = [], []
    for mint, pool, symbol, created_min_ago in pools:
        data.append({"id": f"solana_{pool}", "type": "pool", "attributes": {
            "address": pool, "name": f"{symbol} / SOL", "base_token_price_usd": "0.0025",
            "pool_created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - created_min_ago * 60)),
            "reserve_in_usd": "42000.5", "fdv_usd": "250000", "market_cap_usd": None,
            "volume_usd": {"m5": "9000", "h1": "60000"},
            "transactions": {"m5": {"buys": 40, "sells": 12}, "h1": {"buys": 300, "sells": 120}},
            "price_change_percentage": {"m5": "12.5", "h1": "80"}},
            "relationships": {"base_token": {"data": {"id": f"solana_{mint}", "type": "token"}},
                              "dex": {"data": {"id": "raydium", "type": "dex"}}}})
        included.append({"id": f"solana_{mint}", "type": "token", "attributes": {"address": mint, "name": symbol + " Coin", "symbol": symbol}})
    return {"data": data, "included": included}


class GeckoTerminalTests(unittest.TestCase):
    def test_pool_is_normalised_like_dexscreener(self):
        payload = gecko_payload([("MintAAA", "PoolAAA", "AAA", 7)])
        tokens = {t["id"]: t["attributes"] for t in payload["included"]}
        n = normalize_pool(payload["data"][0], "solana", tokens, NOW)
        self.assertEqual((n["token"], n["pair"], n["symbol"], n["name"], n["dex"]), ("MintAAA", "PoolAAA", "AAA", "AAA Coin", "raydium"))
        self.assertAlmostEqual(n["age_min"], 7, places=3)
        self.assertEqual((n["liquidity_usd"], n["volume_m5"], n["buys_m5"], n["sells_m5"], n["change_m5"]), (42000.5, 9000, 40, 12, 12.5))
        self.assertEqual(n["fdv"], 250000); self.assertEqual(n["market_cap"], 0)
        self.assertIn("geckoterminal.com/solana/pools/PoolAAA", n["url"])
        # the strategy's field list is the same as DexScreener's
        from bot.sources.dexscreener import normalize_pair
        self.assertEqual(set(n), set(normalize_pair({"baseToken": {}}, NOW)))

    def test_symbol_falls_back_to_pool_name_and_bad_pools_are_dropped(self):
        pool = gecko_payload([("MintB", "PoolB", "BBB", 3)])["data"][0]
        self.assertEqual(normalize_pool(pool, "solana", {}, NOW)["symbol"], "BBB")
        self.assertIsNone(normalize_pool({"attributes": {"address": "x"}}, "solana", {}, NOW))

    def test_rate_limit_cache_and_network_mapping(self):
        calls = []
        def fetch(url, **kw):
            calls.append(url)
            return gecko_payload([("MintC", "PoolC", "CCC", 2)])
        t = [NOW]
        g = GeckoTerminal(fetch=fetch, min_interval=15, clock=lambda: t[0])
        a = g.discover(["solana", "base", "polygon"])
        self.assertEqual([x["token"] for x in a["solana"]], ["MintC"])
        self.assertEqual(a["polygon"], [])                         # unknown network: nothing, no call
        self.assertEqual(len(calls), 2)
        self.assertIn("/networks/solana/new_pools", calls[0]); self.assertIn("/networks/base/new_pools", calls[1])
        g.discover(["solana"]); self.assertEqual(len(calls), 2)     # replayed inside the interval
        t[0] += 16
        g.discover(["solana"]); self.assertEqual(len(calls), 3)

    def test_one_failing_chain_does_not_hide_the_other(self):
        def fetch(url, **kw):
            if "/base/" in url:
                raise OSError("boom")
            return gecko_payload([("MintD", "PoolD", "DDD", 2)])
        g = GeckoTerminal(fetch=fetch, min_interval=0)
        out = g.discover(["solana", "base"])
        self.assertEqual(len(out["solana"]), 1); self.assertEqual(out["base"], [])
        with self.assertRaises(RuntimeError):
            GeckoTerminal(fetch=lambda u, **k: (_ for _ in ()).throw(OSError("down")), min_interval=0).discover(["solana"])


class StubFeed:
    def __init__(self, items, fail=False):
        self.items, self.fail, self.calls = items, fail, 0
    def discover(self, chains):
        self.calls += 1
        if self.fail:
            raise OSError("feed down")
        return {c: list(self.items.get(c, [])) for c in chains}


class DiscoveryTests(unittest.TestCase):
    def test_first_feed_owns_a_token_and_status_counts(self):
        cfg = {"discovery": {"sources": ["a", "b", "missing"]}}
        a = StubFeed({"solana": [{"token": "X", "snapshot": None}, {"token": "Y", "snapshot": None}]})
        b = StubFeed({"solana": [{"token": "Y", "snapshot": {"pair": "PY"}}, {"token": "Z", "snapshot": {"pair": "PZ"}}]})
        logs = []
        d = Discovery(cfg, {"a": a, "b": b}, log=lambda lvl, m: logs.append((lvl, m)))
        found = d.recent(["solana", "base"])
        self.assertEqual(found["solana"]["X"]["source"], "a")
        self.assertEqual(found["solana"]["Y"]["source"], "a")                  # first feed wins
        self.assertEqual(found["solana"]["Y"]["snapshot"], {"pair": "PY"})      # ...but borrows the numbers it lacks
        self.assertEqual(found["solana"]["Z"], {"source": "b", "snapshot": {"pair": "PZ"}})
        self.assertEqual(found["base"], {})
        st = {r["name"]: r for r in d.status()}
        self.assertEqual((st["a"]["found"], st["a"]["unique"], st["a"]["ok"]), (2, 1, True))   # Y is in both
        self.assertEqual((st["b"]["found"], st["b"]["unique"], st["b"]["ok"]), (2, 1, True))
        self.assertEqual((st["missing"]["available"], st["missing"]["ok"]), (False, False))
        self.assertTrue(st["dexscreener"]["enabled"] is False and st["dexscreener"]["available"] is False)
        self.assertEqual(len([m for m in logs if "missing" in m[1]]), 1)      # logged once, not every poll
        d.recent(["solana"])
        self.assertEqual(len([m for m in logs if "missing" in m[1]]), 1)

    def test_failing_feed_is_logged_on_change_only(self):
        cfg = {"discovery": {"sources": ["a"]}}
        a = StubFeed({"solana": [{"token": "X", "snapshot": None}]}, fail=True)
        logs = []
        d = Discovery(cfg, {"a": a}, log=lambda lvl, m: logs.append(m))
        d.recent(["solana"]); d.recent(["solana"])
        self.assertEqual(len(logs), 1); self.assertIn("feed down", logs[0])
        a.fail = False
        self.assertEqual(list(d.recent(["solana"])["solana"]), ["X"])
        self.assertEqual(len(logs), 2); self.assertIn("wieder erreichbar", logs[1])

    def test_disabled_feed_is_not_called_and_default_is_dexscreener(self):
        a, b = StubFeed({}), StubFeed({})
        Discovery({"discovery": {"sources": ["b"]}}, {"a": a, "b": b}).recent(["solana"])
        self.assertEqual((a.calls, b.calls), (0, 1))
        self.assertEqual(Discovery({}, {}).enabled(), ["dexscreener"])


class EngineWithFeedsTests(unittest.TestCase):
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

    def test_demo_feeds_tag_candidates_with_their_source(self):
        self.cfg["discovery"]["sources"] = ["geckoterminal", "dexscreener"]
        eng = Engine(self.cfg, self.store, self.dex, FakeRug(), clock=self.dex.now, feeds=demo_feeds(self.dex))
        counts = eng.poll_once()
        self.assertEqual(counts["buy"], 1)
        by = {c["symbol"]: c["snapshot"]["source"] for c in self.store.candidates()}
        self.assertEqual(by["RUN"], "geckoterminal")                      # listed 12 min ago: a "new pool"
        self.assertEqual(by["THIN"], "geckoterminal")                     # 20 min: still inside the window
        self.assertTrue(all(v in ("geckoterminal", "dexscreener") for v in by.values()), by)
        st = {r["name"]: r for r in eng.state()["sources"]}
        self.assertTrue(st["geckoterminal"]["ok"] and st["dexscreener"]["ok"])
        self.assertEqual(st["geckoterminal"]["unique"], 0)                    # DexScreener saw all of them too
        self.assertEqual((st["dexscreener"]["found"], st["dexscreener"]["unique"]), (7, 7 - st["geckoterminal"]["found"]))
        json.dumps(eng.state())

    def test_unindexed_token_is_judged_from_the_feed_snapshot(self):
        run = next(p for p in self.dex.pairs_for_tokens("solana", self.dex.recent_token_addresses(["solana"])["solana"]) if p["symbol"] == "RUN")
        fresh = dict(run, token="NewMint", pair="NewPool", symbol="FRESH")
        feed = StubFeed({"solana": [{"token": "NewMint", "snapshot": fresh}]})
        self.cfg["discovery"]["sources"] = ["gecko"]
        eng = Engine(self.cfg, self.store, self.dex, FakeRug(), clock=self.dex.now, feeds={"gecko": feed})
        counts = eng.poll_once()
        self.assertEqual(counts["seen"], 1)
        c = self.store.candidates()[0]
        self.assertEqual((c["symbol"], c["snapshot"]["source"], c["snapshot"]["via_feed"]), ("FRESH", "gecko", True))
        self.assertIn(c["decision"], ("buy", "watch", "skip"))

    def test_sources_setting_is_validated_and_live(self):
        clean, errors = settings.validate({"discovery.sources": ["geckoterminal"]})
        self.assertEqual((clean, errors), ({"discovery.sources": ["geckoterminal"]}, {}))
        clean, _ = settings.validate({"discovery.sources": "geckoterminal, dexscreener"})
        self.assertEqual(clean["discovery.sources"], ["dexscreener", "geckoterminal"])   # option order = priority
        self.assertIn("discovery.sources", settings.validate({"discovery.sources": []})[1])
        self.assertIn("discovery.sources", settings.validate({"discovery.sources": ["raydium"]})[1])
        eng = Engine(self.cfg, self.store, self.dex, FakeRug(), clock=self.dex.now, feeds=demo_feeds(self.dex))
        self.assertTrue(eng.apply_config({"discovery.sources": ["dexscreener"]})["ok"])
        eng.poll_once()
        st = {r["name"]: r for r in eng.state()["sources"]}
        self.assertFalse(st["geckoterminal"]["enabled"]); self.assertEqual(st["geckoterminal"]["calls"], 0)
        self.assertEqual(st["dexscreener"]["unique"], 7)


if __name__ == "__main__":
    unittest.main()


class TickAndExitTests(unittest.TestCase):
    """Price ticks for the detail chart and the exit breakdown on the Analyse tab."""

    def setUp(self):
        import bot.demo as demo
        self.cycle = demo.CYCLE_MIN
        demo.CYCLE_MIN = 1e9
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite")
        self.dex = FakeDex(accel=1.0)
        self.t = [self.dex.started]
        self.dex.now = lambda: self.t[0]
        self.cfg = copy.deepcopy(CFG)
        self.eng = Engine(self.cfg, self.store, self.dex, FakeRug(), clock=self.dex.now, feeds=demo_feeds(self.dex))

    def tearDown(self):
        import bot.demo as demo
        demo.CYCLE_MIN = self.cycle
        self.store.close()
        self.tmp.cleanup()

    def run_minutes(self, upto, step=2):
        for m in range(1, upto, step):
            self.t[0] = self.dex.started + m * 60
            self.eng.poll_once()

    def test_ticks_follow_the_position_and_detail_includes_them(self):
        self.eng.poll_once()
        pid = self.store.open_positions()[0]["id"]
        self.assertEqual(len(self.store.ticks_for(pid)), 1)              # entry tick
        self.run_minutes(10)
        d = self.eng.position_detail(pid)
        self.assertGreaterEqual(len(d["ticks"]), 5)
        self.assertEqual([k["at"] for k in d["ticks"]], sorted(k["at"] for k in d["ticks"]))
        self.assertEqual(d["exits"]["stop_loss_pct"], self.cfg["exits"]["stop_loss_pct"])
        json.dumps(d)

    def test_exit_breakdown_groups_closed_positions(self):
        self.eng.poll_once()
        self.run_minutes(80)
        self.assertEqual(self.store.open_positions(), [])
        rows = self.store.exit_breakdown()
        self.assertTrue(rows)
        total = sum(r["n"] for r in rows)
        self.assertEqual(total, len(self.store.closed_positions()))
        for r in rows:
            self.assertIn(r["reason"], {"take_profit_50", "take_profit_100", "trailing_stop", "time_stop", "stop_loss", "manual"})
            self.assertTrue(0 <= r["win_rate"] <= 1)
            self.assertGreater(r["avg_minutes"], 0)
        self.assertEqual(self.eng.state()["exits_by_reason"], rows)

    def test_prune_keeps_open_and_recent_and_reset_clears(self):
        self.eng.poll_once()
        self.run_minutes(80)
        closed = min(self.store.closed_positions(), key=lambda c: c["closed_at"])
        self.assertTrue(self.store.ticks_for(closed["id"]))
        self.assertEqual(self.store.prune_ticks(closed["closed_at"] - 1), 0)      # closed after the cutoff: kept
        self.assertGreater(self.store.prune_ticks(closed["closed_at"] + 1), 0)    # older than cutoff: gone
        self.assertEqual(self.store.ticks_for(closed["id"]), [])
        self.eng.poll_once()
        self.store.reset("positions")
        self.assertEqual(self.store._one("SELECT COUNT(*) AS n FROM ticks")["n"], 0)


class CandidateDetailTests(unittest.TestCase):
    """Forward returns on the candidate rows, the candidate detail and poll timing."""

    def setUp(self):
        import bot.demo as demo
        self.cycle = demo.CYCLE_MIN
        demo.CYCLE_MIN = 1e9
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite")
        self.dex = FakeDex(accel=1.0)
        self.t = [self.dex.started]
        self.dex.now = lambda: self.t[0]
        self.cfg = copy.deepcopy(CFG)
        self.eng = Engine(self.cfg, self.store, self.dex, FakeRug(), clock=self.dex.now, feeds=demo_feeds(self.dex))

    def tearDown(self):
        import bot.demo as demo
        demo.CYCLE_MIN = self.cycle
        self.store.close()
        self.tmp.cleanup()

    def test_outcomes_appear_on_candidates_as_they_fill(self):
        self.eng.poll_once()
        self.assertTrue(all(c["outcomes"] == {} for c in self.store.candidates()))
        for m in (6, 16, 61):
            self.t[0] = self.dex.started + m * 60
            self.eng.poll_once()
        run = next(c for c in self.store.candidates() if c["symbol"] == "RUN" and c["seen_at"] == self.dex.started)
        self.assertEqual(set(run["outcomes"]), {"5", "15", "60"})
        self.assertGreater(run["outcomes"]["5"], 0)                     # a runner is up after 5 minutes
        d = self.eng.candidate_detail(run["id"])
        self.assertTrue(d["ok"])
        self.assertEqual([o["horizon_min"] for o in d["outcomes"]], [5, 15, 60])
        self.assertTrue(all(o["filled_at"] for o in d["outcomes"]))
        self.assertEqual(d["candidate"]["snapshot"]["source"], "dexscreener")
        self.assertIn("held", d)
        json.dumps(d)
        self.assertFalse(self.eng.candidate_detail(999999)["ok"])

    def test_poll_timing_in_state_and_candidate_route(self):
        self.eng.poll_once()
        s = self.eng.state()
        self.assertIsInstance(s["poll_ms_last"], int)
        self.assertGreaterEqual(s["poll_ms_avg"], 0)
        from bot.server import make_server
        import http.client, threading
        server = make_server(self.eng, "127.0.0.1", 0)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            c = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=5)
            cid = self.store.candidates()[0]["id"]
            c.request("GET", f"/api/candidates/{cid}"); r = c.getresponse(); body = json.loads(r.read())
            self.assertEqual((r.status, body["candidate"]["id"]), (200, cid))
            c.request("GET", "/api/candidates/424242"); r = c.getresponse(); r.read()
            self.assertEqual(r.status, 404)
            c.request("GET", "/api/candidates/x"); r = c.getresponse(); r.read()
            self.assertEqual(r.status, 404)
        finally:
            c.close(); server.shutdown(); server.server_close()


class DoctorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite")
        self.dex = FakeDex(accel=1.0)
        self.cfg = copy.deepcopy(CFG)
        self.eng = Engine(self.cfg, self.store, self.dex, FakeRug(), clock=self.dex.now, feeds=demo_feeds(self.dex))
        self.eng.home = Path(self.tmp.name) / "home"

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_all_green_against_the_fakes(self):
        r = self.eng.doctor()
        names = [c["name"] for c in r["checks"]]
        self.assertTrue(r["ok"], r)
        for needle in ("Python", "Datenverzeichnis", "DexScreener – Profile", "Paare & Parser", "GeckoTerminal", "RugCheck", "Claude"):
            self.assertTrue(any(needle in n for n in names), needle)
        self.assertTrue(all(isinstance(c["ms"], int) for c in r["checks"]))
        self.assertIn("Selbsttest ohne Befund", self.store.events(5)[0]["message"])
        json.dumps(r)

    def test_failures_are_findings_not_crashes(self):
        from bot.doctor import run_checks
        class DeadDex:
            def recent_token_addresses(self, chains): raise OSError("blocked by proxy")
            def pairs_for_tokens(self, chain, addrs): return []
        class DeadGecko:
            def discover(self, chains): return {chains[0]: []}
        class DeadRug:
            def summary(self, mint): return None
        self.cfg["ai"]["mode"] = "advise"
        checks = run_checks(self.cfg, DeadDex(), {"geckoterminal": DeadGecko()}, DeadRug(), None)
        by = {c["name"]: c for c in checks}
        self.assertFalse(by["DexScreener – Profile & Boosts"]["ok"]); self.assertIn("blocked by proxy", by["DexScreener – Profile & Boosts"]["detail"])
        self.assertFalse(by["DexScreener – Paare & Parser"]["ok"]); self.assertIn("übersprungen", by["DexScreener – Paare & Parser"]["detail"])
        self.assertFalse(by["GeckoTerminal – neue Pools & Parser"]["ok"]); self.assertIn("leer", by["GeckoTerminal – neue Pools & Parser"]["detail"])
        self.assertFalse(by["RugCheck"]["ok"])
        self.assertNotIn("Datenverzeichnis", by)
        import os
        if not (os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN")):
            self.assertFalse(by["Claude-Zugang"]["ok"]); self.assertIn("kein Zugang", by["Claude-Zugang"]["detail"])

    def test_parser_check_catches_missing_fields(self):
        from bot.doctor import _parsed
        with self.assertRaises(RuntimeError) as cm:
            _parsed([{"token": "x", "pair": "y"}])
        self.assertIn("Felder fehlen", str(cm.exception))
        self.assertIn("1 Paare", _parsed([dict.fromkeys(("token", "pair", "symbol", "price_usd", "liquidity_usd", "volume_m5", "buys_m5", "sells_m5", "change_m5", "age_min"), 1)]))

    def test_doctor_route(self):
        from bot.server import make_server
        import http.client, threading
        server = make_server(self.eng, "127.0.0.1", 0)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            c = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=10)
            c.request("POST", "/api/doctor", body="{}", headers={"Content-Type": "application/json"})
            r = c.getresponse(); body = json.loads(r.read())
            self.assertEqual(r.status, 200); self.assertTrue(body["ok"]); self.assertGreaterEqual(len(body["checks"]), 7)
        finally:
            c.close(); server.shutdown(); server.server_close()


class EdgeBySourceTests(unittest.TestCase):
    def test_edge_report_groups_by_source(self):
        import bot.demo as demo
        cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.addCleanup(setattr, demo, "CYCLE_MIN", cycle)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["geckoterminal", "dexscreener"]
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            eng.poll_once()
            for m in (6, 16):
                t[0] = dex.started + m * 60; eng.poll_once()
            rows = store.edge_report("source")
            self.assertTrue(rows)
            self.assertEqual({r["decision"] for r in rows} <= {"geckoterminal", "dexscreener"}, True)
            self.assertIn("edge_source", eng.state())
            self.assertEqual(eng.state()["edge_source"], rows)
            self.assertEqual(eng.state()["version"], "0.9")
            store.close()


class AppBundleTests(unittest.TestCase):
    def test_bundle_files_and_icon(self):
        import struct
        app = ROOT / "New Token Bot.app" / "Contents"
        self.assertTrue((app / "MacOS" / "New Token Bot").is_file())
        self.assertTrue(os.access(app / "MacOS" / "New Token Bot", os.X_OK))
        plist = (app / "Info.plist").read_text()
        for needle in ("<string>New Token Bot</string>", "<string>AppIcon</string>", "LSUIElement"):
            self.assertIn(needle, plist)
        d = (app / "Resources" / "AppIcon.icns").read_bytes()
        self.assertEqual(d[:4], b"icns"); self.assertEqual(struct.unpack(">I", d[4:8])[0], len(d))
        sizes = []
        i = 8
        while i < len(d):
            tag, ln = d[i:i + 4], struct.unpack(">I", d[i + 4:i + 8])[0]
            body = d[i + 8:i + ln]
            self.assertEqual(body[:8], b"\x89PNG\r\n\x1a\n", tag)
            sizes.append(struct.unpack(">I", body[16:20])[0]); i += ln
        self.assertEqual(set(sizes), {16, 32, 64, 128, 256, 512, 1024})
        self.assertTrue((ROOT / "install-app.sh").is_file())

    def test_quit_route_stops_the_engine(self):
        from bot.server import make_server
        import http.client, threading, time as _t
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex()
            eng = Engine(CFG, store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            server = make_server(eng, "127.0.0.1", 0)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                c = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=5)
                c.request("POST", "/api/quit", body="{}", headers={"Content-Type": "application/json"})
                r = c.getresponse(); self.assertEqual((r.status, json.loads(r.read())["ok"]), (200, True))
                for _ in range(30):
                    if eng._stop.is_set(): break
                    _t.sleep(0.05)
                self.assertTrue(eng._stop.is_set())
                self.assertIn("beendet", store.events(3)[0]["message"])
            finally:
                c.close(); server.shutdown(); server.server_close(); store.close()


class PortTests(unittest.TestCase):
    def test_state_carries_the_app_marker(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex()
            eng = Engine(CFG, store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            self.assertEqual(eng.state()["app"], "new-token-bot")
            store.close()

    def test_bind_server_skips_occupied_ports(self):
        from bot.main import bind_server
        import socket
        taken = socket.socket(); taken.bind(("127.0.0.1", 0)); taken.listen(1)
        port = taken.getsockname()[1]
        made = []
        def factory(engine, host, p):
            s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
            s.bind((host, p)); made.append(s); return s      # raises OSError on the taken port
        try:
            server, chosen = bind_server(None, "127.0.0.1", port, tries=3, factory=factory)
            self.assertIsNotNone(server); self.assertIn(chosen, (port + 1, port + 2))
            server2, _ = bind_server(None, "127.0.0.1", port, tries=1, factory=factory)
            self.assertIsNone(server2)
        finally:
            taken.close()
            for s in made: s.close()


class UpdaterTests(unittest.TestCase):
    def test_update_requires_get_sh_and_macos(self):
        from bot import updater
        from unittest import mock
        with tempfile.TemporaryDirectory() as d:
            proj = Path(d)
            r = updater.start_update(proj, 8765, runner=lambda cmd, env: None)
            self.assertFalse(r["ok"]); self.assertIn("get.sh", r["error"])
            (proj / "get.sh").write_text("#!/bin/bash\n")
            with mock.patch.dict(os.environ, {"NEW_TOKEN_BOT_ALLOW_UPDATE": "0"}), mock.patch.object(updater.sys, "platform", "linux"):
                self.assertFalse(updater.available(proj))
                self.assertFalse(updater.start_update(proj, 8765, runner=lambda c, e: None)["ok"])
            calls = []
            with mock.patch.dict(os.environ, {"NEW_TOKEN_BOT_ALLOW_UPDATE": "1"}):
                self.assertTrue(updater.available(proj))
                r = updater.start_update(proj, 8770, runner=lambda cmd, env: calls.append((cmd, env)))
                self.assertTrue(r["ok"], r)
                cmd, env = calls[0]
                self.assertEqual(cmd[:2], ["/bin/bash", "-c"]); self.assertIn("get.sh", cmd[2]); self.assertIn("New Token Bot.app", cmd[2])
                self.assertEqual((env["PROJECT"], env["PORT"]), (str(proj), "8770"))

    def test_update_route_without_get_sh_is_400_and_state_flag(self):
        from bot.server import make_server
        import http.client, threading
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex()
            eng = Engine(CFG, store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            self.assertIn("can_update", eng.state())
            server = make_server(eng, "127.0.0.1", 0)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                c = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=5)
                c.request("POST", "/api/update", body="{}", headers={"Content-Type": "application/json"})
                r = c.getresponse(); body = json.loads(r.read())
                # the test tree has get.sh, but this is not macOS: refused, engine keeps running
                self.assertEqual(r.status, 400); self.assertFalse(body["ok"]); self.assertFalse(eng._stop.is_set())
            finally:
                c.close(); server.shutdown(); server.server_close(); store.close()


class WhyTests(unittest.TestCase):
    def test_skip_reasons_and_rugcheck_health(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            rug = FakeRug()
            eng = Engine(CFG, store, dex, rug, clock=dex.now, feeds=demo_feeds(dex))
            eng.poll_once()
            w = store.skip_reasons()
            self.assertEqual(w["n"], 7); self.assertEqual(w["decisions"]["buy"], 1)
            labels = {r["label"]: r for r in w["reasons"]}
            self.assertIn("zu neu (Mindestalter)", labels)
            self.assertIn("RugCheck: Gefahr", labels)
            self.assertIn("Score unter Schwelle (watch)", labels)
            self.assertEqual(labels["zu neu (Mindestalter)"]["path"], "filters.min_age_minutes")
            self.assertTrue(all(0 < r["share"] <= 1 for r in w["reasons"]))
            s = eng.state()
            self.assertEqual(s["skip_reasons"], w)
            self.assertEqual(s["rugcheck"]["ok"], True); self.assertGreater(s["rugcheck"]["calls"], 0)
            store.close()

    def test_real_rugcheck_client_counts_failures(self):
        from bot.sources.rugcheck import RugCheck
        rc = RugCheck(fetch=lambda url, **kw: (_ for _ in ()).throw(OSError("429 Too Many Requests")))
        self.assertIsNone(rc.summary("Mint1")); self.assertIsNone(rc.summary("Mint2"))
        h = rc.health(); self.assertEqual((h["calls"], h["fails"], h["ok"]), (2, 2, False)); self.assertIn("429", h["last_error"])
        rc2 = RugCheck(fetch=lambda url, **kw: {"score_normalised": 10, "risks": []})
        self.assertEqual(rc2.summary("Mint1")["score"], 10); self.assertEqual(rc2.health()["ok"], True)
        rc2.summary("Mint1"); self.assertEqual(rc2.health()["calls"], 1)      # cached, not counted


class ReseeTests(unittest.TestCase):
    def test_too_new_and_watch_are_rechecked_sooner_than_hard_skips(self):
        import bot.demo as demo
        cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.addCleanup(setattr, demo, "CYCLE_MIN", cycle)
        from bot.engine import resee_after, RESEE_TOO_NEW, RESEE_WATCH, RESEE_SECONDS
        self.assertEqual(resee_after(None), 0)
        self.assertEqual(resee_after({"decision": "skip", "reasons": ["too new (0.7 min)"]}), RESEE_TOO_NEW)
        self.assertEqual(resee_after({"decision": "watch", "reasons": ["score 50 < 60"]}), RESEE_WATCH)
        self.assertEqual(resee_after({"decision": "skip", "reasons": ["rugcheck danger: x"]}), RESEE_SECONDS)
        self.assertEqual(resee_after({"decision": "buy", "reasons": []}), RESEE_SECONDS)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            eng = Engine(CFG, store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            eng.poll_once()                                   # NEW is "too new", HONEY is rug danger, DUMP is watch
            def seen(sym): return [c for c in store.candidates() if c["symbol"] == sym]
            self.assertEqual((len(seen("NEW")), len(seen("HONEY")), len(seen("DUMP"))), (1, 1, 1))
            t[0] = dex.started + 60; eng.poll_once()          # one minute: nothing yet
            self.assertEqual((len(seen("NEW")), len(seen("HONEY")), len(seen("DUMP"))), (1, 1, 1))
            t[0] = dex.started + 150; eng.poll_once()         # 2.5 min: NEW again, DUMP not yet, HONEY not
            self.assertEqual((len(seen("NEW")), len(seen("HONEY")), len(seen("DUMP"))), (2, 1, 1))
            t[0] = dex.started + 330; eng.poll_once()         # 5.5 min: DUMP (watch) again, HONEY still not
            self.assertEqual((len(seen("HONEY")), len(seen("DUMP"))), (1, 2))
            store.close()


class PresetTests(unittest.TestCase):
    def test_presets_are_listed_valid_and_read_only(self):
        from bot import settings
        from bot.engine import presets
        self.assertEqual(set(presets()), {"★ Locker – mehr Kandidaten (Paper)", "★ Standard", "★ Streng – nur die besten"})
        for name, flat in presets().items():
            clean, errors = settings.validate(flat)
            self.assertEqual(errors, {}, name)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex()
            cfg = copy.deepcopy(CFG)
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            self.assertIn("★ Standard", eng.profiles())
            r = eng.apply_profile("★ Locker – mehr Kandidaten (Paper)")
            self.assertTrue(r["ok"], r); self.assertEqual(cfg["filters"]["min_liquidity_usd"], 8000); self.assertTrue(cfg["filters"]["allow_rugcheck_unknown"])
            self.assertFalse(eng.delete_profile("★ Standard")["ok"])
            self.assertFalse(eng.save_profile("★ Standard")["ok"])
            self.assertTrue(eng.save_profile("Meins")["ok"]); self.assertIn("Meins", eng.profiles()); self.assertIn("★ Standard", eng.profiles())
            self.assertTrue(eng.delete_profile("Meins")["ok"]); self.assertNotIn("Meins", eng.profiles())
            store.close()

    def test_age_falls_back_to_the_feed(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            orig = dex.pairs_for_tokens
            def ageless(chain, addrs):
                out = orig(chain, addrs)
                for p in out: p["age_min"] = None          # DexScreener without pairCreatedAt
                return out
            dex.pairs_for_tokens = ageless
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["dexscreener", "geckoterminal"]
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            eng.poll_once()
            run = next(c for c in store.candidates() if c["symbol"] == "RUN")
            self.assertIsNotNone(run["snapshot"]["age_min"]); self.assertTrue(run["snapshot"].get("age_from_feed"))
            self.assertEqual(run["decision"], "buy")      # instead of "age unknown"
            store.close()


class HousekeepingTests(unittest.TestCase):
    def test_reports_are_cached_between_polls_and_refreshed_after(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            eng = Engine(CFG, store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            eng.poll_once()
            calls = []
            orig = store.exit_breakdown
            store.exit_breakdown = lambda: (calls.append(1), orig())[1]
            eng.state(); eng.state(); eng.state()
            self.assertEqual(len(calls), 1)                       # three page refreshes, one computation
            t[0] += 60; eng.poll_once(); eng.state()
            self.assertEqual(len(calls), 2)                       # a new poll invalidates
            eng.invalidate_reports(); eng.state()
            self.assertEqual(len(calls), 3)
            store.close()

    def test_prune_history_drops_old_candidates_and_outcomes(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            eng = Engine(CFG, store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            eng.poll_once()
            n_before = len(store.candidates())
            self.assertEqual(store.prune_history(dex.started - 1)["candidates"], 0)
            dropped = store.prune_history(dex.started + 1)
            self.assertEqual(dropped["candidates"], n_before); self.assertGreater(dropped["outcomes"], 0)
            self.assertEqual(store.candidates(), [])
            self.assertEqual(store._one("SELECT COUNT(*) AS n FROM outcomes")["n"], 0)
            store.close()


class PumpFunTests(unittest.TestCase):
    PAYLOAD = [
        {"mint": "MintPump1", "name": "Pump One", "symbol": "PMP1", "created_timestamp": int((NOW - 90) * 1000),
         "usd_market_cap": 6500.0, "complete": False, "twitter": "https://x.com/x", "bonding_curve": "CurveAddr1"},
        {"mint": "MintPump2", "name": "Pump Two", "symbol": "PMP2", "created_timestamp": int((NOW - 600) * 1000),
         "usd_market_cap": 80000.0, "complete": True, "raydium_pool": "PoolAddr2"},
        {"name": "broken"},
    ]

    def test_coins_become_minimal_snapshots(self):
        from bot.sources.pumpfun import PumpFun
        t = [NOW]
        f = PumpFun(fetch=lambda url, **kw: list(self.PAYLOAD), min_interval=10, clock=lambda: t[0])
        out = f.discover(["solana", "base"])
        self.assertEqual(out["base"], []); self.assertEqual([i["token"] for i in out["solana"]], ["MintPump1", "MintPump2"])
        s1 = out["solana"][0]["snapshot"]
        self.assertAlmostEqual(s1["age_min"], 1.5, places=2); self.assertEqual((s1["symbol"], s1["dex"], s1["pair"], s1["price_usd"]), ("PMP1", "pumpfun", "CurveAddr1", 0.0))
        self.assertTrue(s1["has_socials"]); self.assertFalse(s1["graduated"])
        self.assertTrue(out["solana"][1]["snapshot"]["graduated"]); self.assertEqual(out["solana"][1]["snapshot"]["pair"], "PoolAddr2")
        f.discover(["solana"]); self.assertEqual(f.calls, 1)                 # replayed inside the interval
        t[0] += 11; f.discover(["solana"]); self.assertEqual(f.calls, 2)
        self.assertEqual(PumpFun(fetch=lambda u, **k: {"coins": list(self.PAYLOAD)}).discover(["solana"])["solana"][0]["token"], "MintPump1")

    def test_format_changes_are_reported(self):
        from bot.sources.pumpfun import PumpFun
        with self.assertRaises(RuntimeError):
            PumpFun(fetch=lambda u, **k: [{"foo": 1}]).latest()
        with self.assertRaises(RuntimeError):
            PumpFun(fetch=lambda u, **k: {"html": "<cloudflare>"}).latest()
        self.assertEqual(PumpFun(fetch=lambda u, **k: []).latest(), [])

    def test_engine_uses_pump_age_but_never_judges_a_priceless_snapshot(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["pumpfun"]       # pump.fun only: tokens DexScreener knows get judged
            feeds = demo_feeds(dex)
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds=feeds)
            eng.poll_once()
            cands = store.candidates()
            self.assertTrue(cands)
            self.assertTrue(all(c["snapshot"]["source"] == "pumpfun" and c["snapshot"]["price_usd"] > 0 for c in cands))
            self.assertFalse(any(c["snapshot"].get("via_feed") for c in cands))      # no price -> not judged from the feed alone
            # a mint DexScreener does not know yet is simply not judged (no numbers), no crash
            feeds["pumpfun"].discover = lambda chains: {"solana": [{"token": "UnknownMint", "snapshot": {"pair": "x", "token": "UnknownMint", "price_usd": 0.0, "age_min": 0.5}}]}
            t[0] += 600
            counts = eng.poll_once()
            self.assertEqual(counts["seen"], 0)
            store.close()


class SdkRowTests(unittest.TestCase):
    def test_missing_sdk_is_only_an_error_when_claude_mode_is_on(self):
        from unittest import mock
        from bot import doctor, preflight
        with mock.patch.object(preflight, "sdk_version", return_value=None):
            for mode, provider, ok in (("off", "anthropic", True), ("advise", "openrouter", True), ("advise", "anthropic", False), ("decide", "anthropic", False)):
                cfg = copy.deepcopy(CFG); cfg["ai"]["mode"] = mode; cfg["ai"]["provider"] = provider
                dex = FakeDex()
                row = next(c for c in doctor.run_checks(cfg, dex, demo_feeds(dex), FakeRug(), None) if c["name"] == "Anthropic-SDK")
                self.assertEqual(row["ok"], ok, (mode, provider, row))
        with mock.patch.object(preflight, "sdk_version", return_value="9.9"):
            dex = FakeDex()
            row = next(c for c in doctor.run_checks(CFG, dex, demo_feeds(dex), FakeRug(), None) if c["name"] == "Anthropic-SDK")
            self.assertTrue(row["ok"]); self.assertIn("9.9", row["detail"])


class ConcurrencyTests(unittest.TestCase):
    """The dashboard thread (Schließen, ½, Kaufen) runs while the engine polls.
    Each test injects the user's click at the moment the poll is waiting for
    the network, which is where the real race window is."""

    def setUp(self):
        import bot.demo as demo
        self.cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite")
        self.dex = FakeDex(accel=1.0); self.t = [self.dex.started]; self.dex.now = lambda: self.t[0]
        self.cfg = copy.deepcopy(CFG)
        self.eng = Engine(self.cfg, self.store, self.dex, FakeRug(), clock=self.dex.now, feeds=demo_feeds(self.dex))

    def tearDown(self):
        import bot.demo as demo
        demo.CYCLE_MIN = self.cycle
        self.store.close(); self.tmp.cleanup()

    def sells(self, pid):
        return [t for t in self.store.trades_for(pid) if t["side"] == "sell"]

    def test_manual_close_during_the_exit_check_is_not_sold_twice(self):
        self.eng.poll_once()
        pid = self.store.open_positions()[0]["id"]
        real_price = self.dex.price
        clicked = []
        def price(chain, pair):
            p = real_price(chain, pair)
            if not clicked:                       # the user clicks "Schließen" while the poll waits for this price
                clicked.append(1)
                self.dex.price = real_price
                self.assertTrue(self.eng.close_position(pid)["ok"])
                self.dex.price = price
            return p * 0.5                         # and the price the poll then sees would hit the stop loss
        self.dex.price = price
        self.t[0] += 120
        self.eng.poll_once()
        self.dex.price = real_price
        pos = self.store.position(pid)
        self.assertEqual(len(self.sells(pid)), 1, self.sells(pid))
        self.assertEqual(pos["exit_reason"], "manual")
        self.assertEqual(pos["remaining_frac"], 0.0)
        self.assertAlmostEqual(pos["realized_usd"], sum(t["usd"] for t in self.sells(pid)) - pos["size_usd"]
                               - pos["size_usd"] * self.cfg["paper"]["fee_pct"] / 100, places=6)

    def test_partial_sell_during_the_exit_check_is_not_overwritten(self):
        self.eng.poll_once()
        pid = self.store.open_positions()[0]["id"]
        real_price = self.dex.price
        clicked = []
        def price(chain, pair):
            p = real_price(chain, pair)
            if not clicked:
                clicked.append(1)
                self.dex.price = real_price
                self.assertTrue(self.eng.sell_position(pid, 0.5)["ok"])
                self.dex.price = price
            return p * 0.5                         # stop loss: the poll must sell only what is still left
        self.dex.price = price
        self.t[0] += 120
        self.eng.poll_once()
        self.dex.price = real_price
        fracs = [t["frac"] for t in self.sells(pid)]
        self.assertAlmostEqual(sum(fracs), 1.0, places=9, msg=fracs)    # never more than the whole position
        self.assertEqual(self.store.position(pid)["status"], "closed")

    def test_manual_buy_during_a_poll_does_not_open_the_same_token_twice(self):
        self.eng.poll_once()                      # RUN bought, DUMP watched
        dump = next(c for c in self.store.candidates() if c["symbol"] == "DUMP")
        self.store.reset("positions")
        orig_can_open = self.eng.paper.can_open
        clicked = []
        def can_open(chain, token):
            blocked = orig_can_open(chain, token)
            if not clicked and token == dump["token"] and blocked is None:
                clicked.append(1)                 # the user buys DUMP by hand right after the bot checked it
                threading.Thread(target=lambda: self.eng.open_from_candidate(dump["id"])).start()
                import time as _t; _t.sleep(0.2)
            return blocked
        self.eng.paper.can_open = can_open
        self.cfg["scoring"]["min_score"] = 0      # make the bot want DUMP too
        self.t[0] += 600
        self.eng.poll_once()
        held = [p for p in self.store.open_positions() if p["token"] == dump["token"]]
        self.assertLessEqual(len(held), 1, held)


class CrossSiteTests(unittest.TestCase):
    """Any web page open in the same browser can send requests to 127.0.0.1.
    Only the control page itself may change anything."""

    def setUp(self):
        from bot.server import make_server
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite"); dex = FakeDex()
        self.eng = Engine(copy.deepcopy(CFG), self.store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
        self.server = make_server(self.eng, "127.0.0.1", 0)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.store.close(); self.tmp.cleanup()

    def req(self, method, path, body=None, headers=None):
        import http.client
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            c.request(method, path, body=body, headers=headers or {})
            r = c.getresponse(); data = r.read()
            return r.status, data
        finally:
            c.close()

    def test_a_form_post_from_another_site_changes_nothing(self):
        # an invisible <form enctype="text/plain"> on any web page sends exactly this
        status, _ = self.req("POST", "/api/control", body='{"action": "pause"}',
                             headers={"Content-Type": "text/plain", "Origin": "https://evil.example"})
        self.assertIn(status, (403, 415)); self.assertFalse(self.eng.paused)
        status, _ = self.req("POST", "/api/reset", body='{"what": "all"}', headers={"Content-Type": "text/plain"})
        self.assertEqual(status, 415)

    def test_json_from_a_foreign_origin_is_refused(self):
        status, _ = self.req("POST", "/api/control", body='{"action": "pause"}',
                             headers={"Content-Type": "application/json", "Origin": "https://evil.example"})
        self.assertEqual(status, 403); self.assertFalse(self.eng.paused)

    def test_dns_rebinding_host_is_refused(self):
        status, _ = self.req("GET", "/api/state", headers={"Host": f"evil.example:{self.port}"})
        self.assertEqual(status, 403)
        status, _ = self.req("POST", "/api/control", body='{"action": "pause"}',
                             headers={"Host": f"evil.example:{self.port}", "Content-Type": "application/json"})
        self.assertEqual(status, 403); self.assertFalse(self.eng.paused)

    def test_the_control_page_itself_still_works(self):
        for host in (f"127.0.0.1:{self.port}", f"localhost:{self.port}"):
            status, _ = self.req("GET", "/api/state", headers={"Host": host})
            self.assertEqual(status, 200, host)
            status, data = self.req("POST", "/api/control", body='{"action": "pause"}',
                                    headers={"Host": host, "Content-Type": "application/json", "Origin": f"http://{host}"})
            self.assertEqual(status, 200, data); self.assertTrue(self.eng.paused)
            self.eng.set_paused(False)
        # same-origin fetch without an Origin header (some browsers omit it) is fine too
        status, _ = self.req("POST", "/api/control", body='{"action": "pause"}', headers={"Content-Type": "application/json; charset=utf-8"})
        self.assertEqual(status, 200)

    def test_bad_numbers_get_an_answer_not_a_dropped_connection(self):
        status, data = self.req("POST", "/api/positions/close", body='{"id": "abc"}', headers={"Content-Type": "application/json"})
        self.assertEqual(status, 400, data)
        status, data = self.req("POST", "/api/positions/sell", body='{"id": {"x": 1}, "frac": 0.5}', headers={"Content-Type": "application/json"})
        self.assertEqual(status, 400, data)
        status, data = self.req("POST", "/api/control", body='[1, 2]', headers={"Content-Type": "application/json"})
        self.assertEqual(status, 400, data)


class UrlSafetyTests(unittest.TestCase):
    def test_only_http_links_survive_normalisation(self):
        from bot.sources.dexscreener import normalize_pair, safe_url
        for bad in ("javascript:alert(1)", " JavaScript:alert(1)", "data:text/html,<b>x</b>", "vbscript:x", "", None, 42, "//evil.example", "https://" + "a" * 600):
            self.assertIsNone(safe_url(bad), bad)
        self.assertEqual(safe_url(" https://dexscreener.com/solana/abc "), "https://dexscreener.com/solana/abc")
        self.assertIsNone(normalize_pair({"baseToken": {}, "url": "javascript:alert(document.cookie)"}, NOW)["url"])
        self.assertEqual(normalize_pair({"baseToken": {}, "url": "https://dexscreener.com/x"}, NOW)["url"], "https://dexscreener.com/x")


class ResilienceTests(unittest.TestCase):
    """One broken record from a feed must not stop the stop-loss checks of the open positions."""

    def test_a_broken_token_does_not_suspend_exits(self):
        import bot.demo as demo
        cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.addCleanup(setattr, demo, "CYCLE_MIN", cycle)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            feeds = demo_feeds(dex)
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["dexscreener", "broken"]
            broken = StubFeed({"solana": [{"token": "BadMint", "snapshot": {"pair": "BadPair", "token": "BadMint", "price_usd": 1.0, "symbol": "BAD"}}]})
            feeds["broken"] = broken
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds=feeds)
            eng.poll_once()
            pid = store.open_positions()[0]["id"]
            real = dex.price
            dex.price = lambda chain, pair: (real(chain, pair) or 0) * 0.4      # crash: stop loss must fire
            t[0] += 120
            eng.poll_once()                                                     # must not raise
            self.assertEqual(store.position(pid)["exit_reason"], "stop_loss")
            self.assertTrue(any("BAD" in e["message"] or "BadMint" in e["message"] for e in store.events(20)),
                            [e["message"] for e in store.events(10)])
            store.close()

    def test_a_failing_feed_object_does_not_suspend_exits(self):
        import bot.demo as demo
        cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.addCleanup(setattr, demo, "CYCLE_MIN", cycle)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            eng = Engine(CFG, store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            eng.poll_once()
            pid = store.open_positions()[0]["id"]
            real_pairs, real_price = dex.pairs_for_tokens, dex.price
            def boom(chain, addrs): raise RuntimeError("DexScreener 502")
            dex.pairs_for_tokens = boom                                         # the numbers source is down
            dex.price = lambda chain, pair: (real_price(chain, pair) or 0) * 0.4
            t[0] += 120
            eng.poll_once()
            self.assertEqual(store.position(pid)["exit_reason"], "stop_loss")
            store.close()


class QuietErrorTests(unittest.TestCase):
    def test_outages_and_bad_tokens_are_logged_once(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            feeds = demo_feeds(dex)
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["broken"]
            feeds["broken"] = StubFeed({"solana": [{"token": "BadMint", "snapshot": {"pair": "BadPair", "token": "BadMint", "price_usd": 1.0, "symbol": "BAD"}}]})
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds=feeds)
            for _ in range(5):
                t[0] += 20; eng.poll_once()
            bad = [e for e in store.events(50) if "BAD" in e["message"]]
            self.assertEqual(len(bad), 1, [e["message"] for e in bad])           # once, then parked
            t[0] += 31 * 60; eng.poll_once()
            self.assertEqual(len([e for e in store.events(80) if "BAD" in e["message"]]), 2)   # retried after 30 min
            def boom(chain, addrs): raise RuntimeError("DexScreener 502")
            cfg["discovery"]["sources"] = ["dexscreener"]
            dex.pairs_for_tokens = boom
            for _ in range(5):
                t[0] += 20; eng.poll_once()
            down = [e for e in store.events(80) if "abgebrochen" in e["message"]]
            self.assertEqual(len(down), 1, [e["message"] for e in down])
            del dex.pairs_for_tokens                                              # back to the class method
            t[0] += 20; eng.poll_once()
            self.assertIn("läuft wieder", store.events(5)[0]["message"] + " ".join(e["message"] for e in store.events(5)))
            store.close()
