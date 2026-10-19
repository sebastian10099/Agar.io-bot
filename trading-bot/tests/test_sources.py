import copy
import json
import os
import threading
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

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


class GeckoRateLimitTests(unittest.TestCase):
    def test_a_429_pauses_the_feed_instead_of_hammering_it(self):
        from bot.doctor import _check
        from bot.sources.http import HttpError
        t = [NOW]; calls = []
        def fetch(url, **kw):
            calls.append(kw.get("retries"))
            raise HttpError(429, '{"status":{"error_code":429}}')
        g = GeckoTerminal(fetch=fetch, min_interval=0, clock=lambda: t[0])
        with self.assertRaises(RuntimeError) as first:
            g.discover(["solana"])
        self.assertIn("HTTP 429", str(first.exception))
        self.assertEqual(calls, [0])                                   # no immediate retries
        t[0] += 30
        with self.assertRaises(RuntimeError) as paused:
            g.discover(["solana"])
        self.assertIn("Pause", str(paused.exception)); self.assertEqual(len(calls), 1)
        self.assertTrue(_check("GeckoTerminal", lambda: g.discover(["solana"]))["warn"])   # self-test: a note
        t[0] += 31
        with self.assertRaises(RuntimeError):
            g.discover(["solana"])
        self.assertEqual(len(calls), 2)                                # asked again after the pause
        cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["geckoterminal"]
        d = Discovery(cfg, {"geckoterminal": g})
        d.recent(["solana"])
        row = next(r for r in d.status() if r["name"] == "geckoterminal")
        self.assertEqual((row["ok"], row["throttled"]), (False, True))   # shown as a pause, not as broken


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

    def test_the_chain_price_row_says_whether_the_node_answers(self):
        from bot.doctor import run_checks
        class Dex:
            quote_usd = {}
            def recent_token_addresses(self, chains): return {"solana": ["M1"]}
            def pairs_for_tokens(self, chain, addrs):
                return [{"chain": "solana", "dex": "pumpswap", "pair": "P1", "token": "M1", "symbol": "M", "price_usd": 1e-5,
                         "liquidity_usd": 20000, "volume_m5": 1, "buys_m5": 1, "sells_m5": 1, "change_m5": 0, "age_min": 5}]
        class Chain:
            price = None
            def pool_prices(self, pairs, quote_usd): return {"P1": self.price} if self.price else {}
        chain = Chain()
        row = lambda: next(c for c in run_checks(self.cfg, Dex(), {}, FakeRug(), None, chain) if c["name"].startswith("Kurse von der Chain"))
        self.assertIn("kein Pool von der Chain gelesen", row()["detail"])
        chain.price = 1.02e-5
        self.assertTrue(row()["ok"]); self.assertIn("1 von 1 PumpSwap-Pools", row()["detail"]); self.assertIn("2.0 %", row()["detail"])

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

    def test_a_cloudflare_blocked_pump_feed_is_a_note(self):
        from bot.doctor import run_checks
        from bot.sources.http import HttpError
        from bot.sources.pumpfun import PumpFun
        def blocked(url, **kw): raise HttpError(403, "<!DOCTYPE html><title>Just a moment...</title>")
        def broken(url, **kw): raise HttpError(500, '{"error":"db down"}')
        for fetch, ok, warn, text in ((blocked, True, True, "Cloudflare"), (broken, False, None, "db down")):
            checks = run_checks(self.cfg, self.dex, {"pumpfun": PumpFun(fetch=fetch)}, FakeRug(), None)
            row = next(c for c in checks if c["name"] == "pump.fun – neue Coins")
            self.assertEqual((row["ok"], row.get("warn")), (ok, warn), row); self.assertIn(text, row["detail"])

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

    def test_saving_a_profile_never_freezes_the_presets(self):
        from bot.engine import presets
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex()
            eng = Engine(copy.deepcopy(CFG), store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            self.assertTrue(eng.save_profile("Meins")["ok"])
            self.assertEqual(set(store.get("profiles")), {"Meins"})                  # only the user's own is stored
            self.assertFalse(eng.save_profile("★ Eigen")["ok"])                      # ★ is for the presets
            stale = {"filters.min_liquidity_usd": 1.0}                                 # an older version froze a preset
            store.set("profiles", {"★ Standard": stale, "Meins": store.get("profiles")["Meins"],
                                   "Kaputt": {"exits.take_profit_ladder": [[float("nan"), 0.5]]}})
            got = eng.profiles()
            self.assertEqual(got["★ Standard"], presets()["★ Standard"])               # the shipped one wins
            self.assertIn("Meins", got); self.assertNotIn("Kaputt", got)
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
            eng.poll_once()                                    # (launches judged too new in the first poll come back)
            self.assertFalse([c for c in store.candidates() if c["token"] == "UnknownMint"])
            self.assertEqual(eng.errors, 0)
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

    def test_the_page_through_an_ssh_tunnel_works_and_other_local_pages_do_not(self):
        tunnel = "127.0.0.1:18765"                      # ssh -L 18765:127.0.0.1:<port> vps
        status, data = self.req("POST", "/api/control", body='{"action": "pause"}',
                                headers={"Host": tunnel, "Content-Type": "application/json", "Origin": f"http://{tunnel}"})
        self.assertEqual(status, 200, data); self.assertTrue(self.eng.paused)
        self.eng.set_paused(False)
        status, _ = self.req("POST", "/api/control", body='{"action": "pause"}',          # another local page
                             headers={"Host": tunnel, "Content-Type": "application/json", "Origin": "http://127.0.0.1:9999"})
        self.assertEqual(status, 403); self.assertFalse(self.eng.paused)
        status, _ = self.req("POST", "/api/control", body='{"action": "pause"}',          # a rebinding name never counts
                             headers={"Host": "evil.example:18765", "Content-Type": "application/json", "Origin": "http://evil.example:18765"})
        self.assertEqual(status, 403); self.assertFalse(self.eng.paused)

    def test_bad_numbers_get_an_answer_not_a_dropped_connection(self):
        status, data = self.req("POST", "/api/positions/close", body='{"id": "abc"}', headers={"Content-Type": "application/json"})
        self.assertEqual(status, 400, data)
        status, data = self.req("POST", "/api/positions/sell", body='{"id": {"x": 1}, "frac": 0.5}', headers={"Content-Type": "application/json"})
        self.assertEqual(status, 400, data)
        status, data = self.req("POST", "/api/control", body='[1, 2]', headers={"Content-Type": "application/json"})
        self.assertEqual(status, 400, data)

    def test_poisoned_numbers_are_refused_and_the_page_keeps_working(self):
        """A NaN or infinite profit rung was accepted, written into /api/state as bare NaN
        (which the browser cannot parse - the page went offline), kept in config.json and
        stopped every exit."""
        j = {"Content-Type": "application/json"}
        for patch in ('{"patch": {"exits.take_profit_ladder": [[NaN, 0.5]]}}',
                      '{"patch": {"exits.take_profit_ladder": "1e999: 0.5"}}',
                      '{"patch": {"exits.stop_loss_pct": ' + "9" * 400 + '}}',
                      '{"patch": {"ai.model": null}}'):
            status, data = self.req("POST", "/api/config", body=patch, headers=j)
            self.assertIn(status, (400, 422), (patch[:60], data))                     # refused with a reason
        status, data = self.req("GET", "/api/state")
        json.loads(data, parse_constant=lambda c: self.fail(f"{c} in /api/state"))   # strict JSON for the browser
        for body in ('{"id": 1e30}', '{"id": Infinity}', '{"id": 99999999999999999999999}'):
            status, data = self.req("POST", "/api/positions/close", body=body, headers=j)
            self.assertIn(status, (400, 409), (body, data))                          # an answer, not a 500
        status, data = self.req("POST", "/api/control", body='{"action": "pause"}',
                                headers={"Content-Type": "application/json", "Content-Length": "abc"})
        self.assertEqual(status, 400, data)

    def test_a_client_that_gives_up_is_not_an_error(self):
        # curl -m 2 or a reloaded page: the answer has nowhere to go – no traceback, no red log line
        import contextlib, io, socket, struct
        slow = self.eng.state
        def state():
            time.sleep(0.3)
            return dict(slow(), padding="x" * 2_000_000)
        self.eng.state = state
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            for _ in range(3):
                s = socket.create_connection(("127.0.0.1", self.port))
                s.sendall(b"GET /api/state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                s.close()                                    # reset: the client is gone
            time.sleep(1.0)
        self.assertEqual(err.getvalue(), "")
        self.assertEqual([e["message"] for e in self.store.events(50) if e["level"] == "error"], [])
        self.eng.state = slow
        status, _ = self.req("GET", "/api/state")
        self.assertEqual(status, 200)


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


class FeedOnlyBuyTests(unittest.TestCase):
    def test_a_token_dexscreener_does_not_know_is_never_bought(self):
        """Exits are priced by DexScreener; a position it cannot price could never be stopped out."""
        import bot.demo as demo
        cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.addCleanup(setattr, demo, "CYCLE_MIN", cycle)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            run = next(p for p in dex.pairs_for_tokens("solana", dex.recent_token_addresses(["solana"])["solana"]) if p["symbol"] == "RUN")
            fresh = dict(run, token="GeckoOnlyMint", pair="GeckoOnlyPool", symbol="GONLY")      # rules would buy these numbers
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["gecko"]
            cfg["filters"]["allow_rugcheck_unknown"] = True; cfg["scoring"]["min_score"] = 50     # the rules say buy
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds={"gecko": StubFeed({"solana": [{"token": "GeckoOnlyMint", "snapshot": fresh}]})})
            eng.poll_once()
            c = next(c for c in store.candidates() if c["symbol"] == "GONLY")
            self.assertTrue(c["snapshot"]["via_feed"])
            self.assertEqual(c["decision"], "watch", c["reasons"])
            self.assertTrue(any("DexScreener" in r for r in c["reasons"]), c["reasons"])
            self.assertEqual(store.open_positions(), [])
            store.close()

    def test_a_skipped_feed_token_gets_its_real_reason_first(self):
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            run = next(p for p in dex.pairs_for_tokens("solana", dex.recent_token_addresses(["solana"])["solana"]) if p["symbol"] == "RUN")
            young = dict(run, token="GeckoYoung", pair="GeckoYoungPool", symbol="YOUNG", age_min=0.5)
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["gecko"]
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds={"gecko": StubFeed({"solana": [{"token": "GeckoYoung", "snapshot": young}]})})
            eng.poll_once()
            c = next(c for c in store.candidates() if c["symbol"] == "YOUNG")
            self.assertEqual(c["decision"], "skip")
            self.assertTrue(c["reasons"][0].startswith("too new"), c["reasons"])
            self.assertFalse(any("nur beobachten" in r for r in c["reasons"]), c["reasons"])
            store.close()


class FollowTests(unittest.TestCase):
    """GeckoTerminal and pump.fun list only the last few dozen launches: a token
    judged too new, or watched, is gone from them by the time it is due again."""

    def setUp(self):
        import bot.demo as demo
        cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.addCleanup(setattr, demo, "CYCLE_MIN", cycle)

    def test_a_launch_is_judged_again_after_its_feed_moved_on(self):
        from bot.engine import RESEE_TOO_NEW
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            feed = StubFeed({"solana": [{"token": "mintTooNew111111111111111111111111111111", "snapshot": None}]})
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["gecko"]
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds={"gecko": feed})
            def seen(): return [c for c in store.candidates() if c["symbol"] == "NEW"]
            eng.poll_once()
            self.assertTrue(seen()[0]["reasons"][0].startswith("too new"), seen()[0]["reasons"])
            feed.items = {}                                   # the launch list has moved on
            t[0] = dex.started + RESEE_TOO_NEW - 30; eng.poll_once()
            self.assertEqual(len(seen()), 1)                  # not old enough yet: not asked for
            t[0] = dex.started + RESEE_TOO_NEW + 30; eng.poll_once()
            self.assertEqual(len(seen()), 2)
            again = seen()[0]
            self.assertFalse(any("too new" in r for r in again["reasons"]), again["reasons"])
            self.assertEqual(again["snapshot"]["source"], "gecko")    # still credited to the feed that found it
            self.assertEqual(eng._followed, {})                  # judged at its real age: no longer followed
            store.close()

    def test_a_watched_launch_is_looked_at_again_every_five_minutes(self):
        from bot.engine import RESEE_WATCH
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            feed = StubFeed({"solana": [{"token": "mintDump11111111111111111111111111111111", "snapshot": None}]})
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["gecko"]
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds={"gecko": feed})
            def seen(): return [c for c in store.candidates() if c["symbol"] == "DUMP"]
            eng.poll_once(); feed.items = {}
            self.assertEqual(seen()[0]["decision"], "watch", seen()[0]["reasons"])
            t[0] = dex.started + RESEE_WATCH - 30; eng.poll_once()
            self.assertEqual(len(seen()), 1)
            t[0] = dex.started + RESEE_WATCH + 30; eng.poll_once()
            self.assertEqual(len(seen()), 2)                  # gone from the feed, judged again all the same
            store.close()

    def test_a_restart_keeps_the_follow_ups(self):
        from bot.engine import RESEE_TOO_NEW
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            feed = StubFeed({"solana": [{"token": "mintTooNew111111111111111111111111111111", "snapshot": None},
                                        {"token": "mintDump11111111111111111111111111111111", "snapshot": None}]})
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["gecko"]
            Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds={"gecko": feed}).poll_once()
            feed.items = {}
            t[0] = dex.started + 60
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds={"gecko": feed})      # restarted
            self.assertEqual(set(k[1][:8] for k in eng._followed), {"mintTooN", "mintDump"})
            self.assertAlmostEqual(eng._followed[("solana", "mintTooNew111111111111111111111111111111")]["ready_at"],
                                   dex.started + RESEE_TOO_NEW)
            self.assertEqual(eng._followed[("solana", "mintTooNew111111111111111111111111111111")]["source"], "gecko")
            t[0] = dex.started + RESEE_TOO_NEW + 30; eng.poll_once()
            self.assertEqual(len([c for c in store.candidates() if c["symbol"] == "NEW"]), 2)
            store.close()

    def test_waits_until_the_minimum_age_and_gives_up_on_a_token_never_listed(self):
        from bot.engine import FOLLOW_GRACE_S
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            run = next(p for p in dex.pairs_for_tokens("solana", dex.recent_token_addresses(["solana"])["solana"]) if p["symbol"] == "RUN")
            ghost = dict(run, token="GhostMint", pair="GhostPool", symbol="GHOST", age_min=0.5)
            feed = StubFeed({"solana": [{"token": "GhostMint", "snapshot": ghost}]})
            cfg = copy.deepcopy(CFG); cfg["discovery"]["sources"] = ["gecko"]; cfg["filters"]["min_age_minutes"] = 6
            eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, feeds={"gecko": feed})
            eng.poll_once(); feed.items = {}
            info = eng._followed[("solana", "GhostMint")]
            self.assertAlmostEqual(info["ready_at"] - dex.started, 5.5 * 60)      # at 6 min of age, not every 2 min
            asked = []
            orig = dex.pairs_for_tokens
            dex.pairs_for_tokens = lambda chain, addrs: asked.extend(addrs) or orig(chain, addrs)
            t[0] = dex.started + 4 * 60; eng.poll_once()
            self.assertNotIn("GhostMint", asked)
            t[0] = dex.started + 6 * 60; eng.poll_once()
            self.assertIn("GhostMint", asked)                 # asked for, but DexScreener does not know it
            self.assertEqual(len([c for c in store.candidates() if c["symbol"] == "GHOST"]), 1)
            t[0] = dex.started + 5.5 * 60 + FOLLOW_GRACE_S + 1; eng.poll_once()
            self.assertNotIn(("solana", "GhostMint"), eng._followed)
            store.close()


class DailyPnlTests(unittest.TestCase):
    def test_partial_exits_and_fees_count_on_the_day_they_happen(self):
        from bot.paper import Paper
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            cfg = copy.deepcopy(CFG); cfg["paper"]["fee_pct"] = 1.0; cfg["paper"]["slippage_pct"] = 0.0
            paper = Paper(store, cfg)
            midnight = 1_000_000.0
            pair = {"chain": "solana", "pair": "P", "symbol": "A", "price_usd": 1.0}
            old = paper.open(dict(pair, token="A"), now=midnight - 3600)              # yesterday: fee yesterday
            paper._sell(store.position(old), 0.5, 1.5, "take_profit_50", midnight - 60)  # yesterday's profit
            paper._sell(store.position(old), 0.25, 2.0, "take_profit_100", midnight + 60)
            new = paper.open(dict(pair, token="B"), now=midnight + 120)                  # today: still open
            size_a, size_b = store.position(old)["size_usd"], store.position(new)["size_usd"]
            today = size_a * 0.25 * 2.0 * 0.99 - size_a * 0.25 - size_b * 0.01
            self.assertAlmostEqual(store.realized_since(midnight), today, places=6)
            self.assertAlmostEqual(store.realized_since(0), store.realized_all(), places=6)
            paper._sell(store.position(new), 1.0, 0.5, "stop_loss", midnight + 300)
            today += size_b * 0.5 * 0.99 - size_b
            self.assertAlmostEqual(store.realized_since(midnight), today, places=6)
            store.close()


class AuditTests(unittest.TestCase):
    """tools/audit.py holds a paper account against the bot's own rules."""

    def cfg(self):
        cfg = copy.deepcopy(CFG); cfg["exits"]["time_stop_minutes"] = 30      # positions close within the demo hour
        return cfg

    def load(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("audit", ROOT / "tools" / "audit.py")
        mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
        return mod

    def test_an_hour_of_demo_trading_passes_and_a_tampered_account_does_not(self):
        import sqlite3
        audit = self.load()
        with tempfile.TemporaryDirectory() as d:
            db = Path(d) / "bot.sqlite"
            store = Store(db); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            eng = Engine(self.cfg(), store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            for _ in range(360):                                  # one simulated hour, a poll every 10 s
                eng.poll_once(); t[0] += 10
            state = eng.state()
            store.close()
            checks = audit.audit(db, self.cfg(), state)
            self.assertTrue(all(c["ok"] for c in checks), audit.render(checks))
            self.assertGreater(next(c for c in checks if c["name"].startswith("Ausstiege"))["n"], 0)
            self.assertGreater(next(c for c in checks if c["name"].startswith("automatische"))["n"], 0)
            con = sqlite3.connect(db)
            pid = con.execute("SELECT id FROM positions WHERE status='closed' LIMIT 1").fetchone()[0]
            con.execute("UPDATE positions SET realized_usd = realized_usd + 5 WHERE id=?", (pid,))   # money from nowhere
            con.execute("UPDATE trades SET reason='stop_loss' WHERE side='sell' AND reason LIKE 'take_profit%'")
            con.commit(); con.close()
            bad = {c["name"].split(" ")[0] for c in audit.audit(db, self.cfg()) if not c["ok"]}
            self.assertEqual(bad, {"Buchhaltung", "Ausstiege"})
            strict = self.cfg(); strict["filters"]["min_liquidity_usd"] = 10_000_000       # other rules
            self.assertFalse(next(c for c in audit.audit(db, strict) if c["name"].startswith("automatische"))["ok"])

    def test_a_fantasy_price_fails_the_audit(self):
        import sqlite3
        audit = self.load()
        with tempfile.TemporaryDirectory() as d:
            db = Path(d) / "bot.sqlite"
            store = Store(db)
            from bot.paper import Paper
            paper = Paper(store, self.cfg())
            pid = paper.open({"chain": "solana", "token": "Merc", "pair": "MercPool", "symbol": "MRCY", "price_usd": 3e-5}, 0.0)
            pos = store.position(pid)
            store.tick(pid, 0.0, 3e-5); store.tick(pid, 10.0, 3.6e-5)
            store.tick(pid, 20.0, 1.017); paper.update(pos, 1.017, 20.0)              # what the live run booked
            store.close()
            jumps = lambda cs: next(c for c in cs if c["name"].startswith("Kurse plausibel"))
            checks = audit.audit(db, self.cfg())
            self.assertFalse(jumps(checks)["ok"])
            self.assertIn("#1 MRCY", jumps(checks)["problems"][0])
            con = sqlite3.connect(db)
            con.execute("DELETE FROM trades WHERE side='sell'"); con.execute("DELETE FROM ticks WHERE price > 1")
            con.commit(); con.close()
            self.assertTrue(jumps(audit.audit(db, self.cfg()))["ok"])                  # +20 % a poll is a market

    def test_state_cross_check_ai_lift_and_claudes_words(self):
        import sqlite3
        audit = self.load()
        with tempfile.TemporaryDirectory() as d:
            db = Path(d) / "bot.sqlite"
            store = Store(db); dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
            eng = Engine(self.cfg(), store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex))
            for _ in range(360):
                eng.poll_once(); t[0] += 10
            state = json.loads(json.dumps(eng.state()))
            store.close()
            cash = lambda cs: next(c for c in cs if c["name"].startswith("Bargeld"))
            auto = lambda cs: next(c for c in cs if c["name"].startswith("automatische"))
            self.assertTrue(cash(audit.audit(db, self.cfg(), state))["ok"])
            wrong = dict(state, bankroll=state["bankroll"] + 10)
            self.assertFalse(cash(audit.audit(db, self.cfg(), wrong))["ok"])            # page and books disagree
            # Claude in "decide" mode lifted a score "watch" to a buy: allowed - but only in that mode
            higher = self.cfg(); higher["scoring"]["min_score"] = 99
            self.assertFalse(auto(audit.audit(db, higher))["ok"])
            con = sqlite3.connect(db)
            for cid, snap, reasons in con.execute("SELECT id, snapshot, reasons FROM candidates WHERE decision='buy'").fetchall():
                sn = json.loads(snap); sn["ai_decision"] = "buy"
                con.execute("UPDATE candidates SET snapshot=?, reasons=? WHERE id=?",
                            (json.dumps(sn), json.dumps(json.loads(reasons) + ["KI buy (80%): not opened before, watch only later"]), cid))
            con.commit(); con.close()
            higher["ai"]["mode"] = "decide"
            checks = audit.audit(db, higher)
            self.assertTrue(auto(checks)["ok"], audit.render(checks))
            self.assertTrue(next(c for c in checks if c["name"].startswith("kein Kauf"))["ok"])  # Claude's words are no rule reason


class EngineSafetyTests(unittest.TestCase):
    """Faults found by a review, each with the case that proved it."""

    def setUp(self):
        import bot.demo as demo
        cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.addCleanup(setattr, demo, "CYCLE_MIN", cycle)

    def engine(self, dex, t, feeds=None, cfg=None, store=None, d=None):
        store = store or Store(Path(d) / "t.sqlite")
        return Engine(cfg or copy.deepcopy(CFG), store, dex, FakeRug(), clock=lambda: t[0], feeds=feeds or demo_feeds(dex)), store

    def test_a_dexscreener_outage_never_writes_a_position_off(self):
        with tempfile.TemporaryDirectory() as d:
            dex = FakeDex(accel=1.0); t = [dex.started]
            run = next(p for p in dex.pairs_for_tokens("solana", dex.recent_token_addresses(["solana"])["solana"]) if p["symbol"] == "RUN")
            eng, store = self.engine(dex, t, d=d)
            pid = eng.paper.open(run, t[0])
            dex.prices = lambda chain, pairs, follow=None: {}                       # DexScreener is down ...
            dex.pairs_for_tokens = lambda chain, addrs: []
            feed = StubFeed({"solana": [{"token": "GeckoMint", "snapshot": dict(run, token="GeckoMint", pair="GeckoPool", age_min=0.5)}]})
            eng.discovery.feeds = {"gecko": feed}; eng.cfg["discovery"]["sources"] = ["gecko"]   # ... while a feed answers
            for _ in range(8):
                t[0] += 10 * 60; eng.poll_once()
            self.assertEqual(store.position(pid)["status"], "open")
            store.close()

    def test_a_restart_does_not_write_off_a_position_it_was_not_watching(self):
        with tempfile.TemporaryDirectory() as d:
            dex = FakeDex(accel=1.0); t = [dex.started]
            pairs = {p["symbol"]: p for p in dex.pairs_for_tokens("solana", dex.recent_token_addresses(["solana"])["solana"])}
            eng, store = self.engine(dex, t, d=d)
            eng.paper.open(pairs["RUN"], t[0])
            b = eng.paper.open(pairs["DUMP"], t[0])
            t[0] += 100 * 60                                                        # the bot was off for 100 minutes
            orig = dex.prices
            dex.prices = lambda chain, ps, follow=None: {p: v for p, v in orig(chain, ps, follow).items() if p != pairs["DUMP"]["pair"]}
            eng2 = Engine(copy.deepcopy(CFG), store, dex, FakeRug(), clock=lambda: t[0], feeds=demo_feeds(dex))
            eng2.poll_once()                                                        # DUMP misses one answer, RUN is priced
            self.assertNotEqual(store.position(b)["exit_reason"], "no_price")
            store.close()

    def test_a_write_off_is_a_total_loss_however_small_the_price(self):
        with tempfile.TemporaryDirectory() as d:
            dex = FakeDex(accel=1.0); t = [dex.started]
            run = next(p for p in dex.pairs_for_tokens("solana", dex.recent_token_addresses(["solana"])["solana"]) if p["symbol"] == "RUN")
            eng, store = self.engine(dex, t, d=d)
            eng.paper.open(run, t[0])
            tiny = eng.paper.open({"chain": "solana", "token": "TinyMint", "pair": "TinyPool", "symbol": "TINY", "price_usd": 1e-13}, t[0])
            for _ in range(9):                                                      # TINY is never priced again, RUN is
                t[0] += 10 * 60; eng.poll_once()
            pos = store.position(tiny)
            self.assertEqual(pos["exit_reason"], "no_price")
            self.assertLess(pos["realized_usd"], -pos["size_usd"] * 0.99)          # a total loss, not a gain
            store.close()

    def test_a_made_up_price_is_never_booked(self):
        """Live run: a holding at $0.00003 was quoted at $1.017 (a pool opened at a made-up
        price) and sold there - a million-dollar profit that never existed."""
        with tempfile.TemporaryDirectory() as d:
            dex = FakeDex(accel=1.0); t = [dex.started]
            eng, store = self.engine(dex, t, d=d)
            pid = eng.paper.open({"chain": "solana", "token": "Merc", "pair": "MercPool", "symbol": "MRCY", "price_usd": 3e-5}, t[0])
            quote = [3.3e-5]
            orig = dex.prices
            dex.prices = lambda chain, ps, follow=None: dict(orig(chain, ps, follow), MercPool=quote[0])
            t[0] += 10; eng.poll_once()
            quote[0] = 1.017
            for _ in range(5):
                t[0] += 10; eng.poll_once()
            pos = store.position(pid)
            self.assertEqual(pos["remaining_frac"], 1.0)                            # no take-profit at the fantasy price
            self.assertLess(pos["realized_usd"], 0)                                 # only the entry fee
            self.assertEqual(eng.last_prices["MercPool"], 3.3e-5)
            self.assertEqual(sum("MRCY verworfen" in e["message"] for e in store.events()), 1)   # said once
            eng.sell_position(pid, 0.5)                                             # a manual sell neither
            sold = [t for t in store._rows("SELECT * FROM trades WHERE position_id=?", (pid,)) if t["side"] == "sell"]
            self.assertAlmostEqual(sold[0]["price"], 3.3e-5 * (1 - eng.paper.slippage_pct / 100))
            quote[0] = 3.3e-6                                                       # a real fall is believed: the stop fires
            t[0] += 10; eng.poll_once()
            self.assertEqual(store.position(pid)["exit_reason"], "stop_loss")
            store.close()

    def test_editing_the_ladder_never_sells_a_rung_twice(self):
        from bot.paper import Paper
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); cfg = copy.deepcopy(CFG)
            cfg["exits"]["take_profit_ladder"] = [[50, 0.5], [100, 0.25]]
            paper = Paper(store, cfg)
            pid = paper.open({"chain": "solana", "token": "T", "pair": "P", "symbol": "T", "price_usd": 1.0}, 0.0)
            entry = store.position(pid)["entry_price"]
            paper.update(store.open_positions()[0], entry * 1.6, 10.0)              # +60 %: the 50 % rung sells half
            self.assertAlmostEqual(store.position(pid)["remaining_frac"], 0.5)
            cfg["exits"]["take_profit_ladder"] = [[30, 0.2], [50, 0.5], [100, 0.25]]   # a rung added while open
            paper.update(store.open_positions()[0], entry * 1.6, 20.0)
            self.assertAlmostEqual(store.position(pid)["remaining_frac"], 0.3)       # only the new 30 % rung, not 50 % again
            legacy = paper.open({"chain": "solana", "token": "U", "pair": "Q", "symbol": "U", "price_usd": 1.0}, 0.0)
            store.update_position(legacy, ladder_done="[1]")                       # an old record: the rung's index
            self.assertEqual(paper.rungs_done(store.position(legacy)), {50.0})
            store.close()


class SourceHygieneTests(unittest.TestCase):
    """Faults found by a review of the data sources, each with the case that proved it."""

    def test_a_failing_feed_is_not_asked_more_often_than_a_working_one(self):
        from bot.sources.geckoterminal import GeckoTerminal
        from bot.sources.http import HttpError
        from bot.sources.pumpfun import PumpFun
        calls = []
        def down(url, **kw):
            calls.append(url); raise HttpError(503, "Service Unavailable")
        t = [0.0]
        gecko = GeckoTerminal(fetch=down, min_interval=15.0, clock=lambda: t[0])
        pump = PumpFun(fetch=down, min_interval=10.0, clock=lambda: t[0])
        for _ in range(30):                                   # a minute of 2-second polls on four chains
            for chain in ("solana", "base", "ethereum", "bsc"):
                with self.assertRaises(Exception):
                    gecko.new_pools(chain)
            with self.assertRaises(Exception):
                pump.latest()
            t[0] += 2
        self.assertLessEqual(sum("geckoterminal" in u for u in calls), 4 * 4)   # one per chain and 15 s, not 120
        self.assertLessEqual(sum("pump.fun" in u for u in calls), 6)

    def test_a_rate_limit_pause_is_logged_once(self):
        from bot.sources.geckoterminal import GeckoTerminal
        from bot.sources.http import HttpError
        def limited(url, **kw): raise HttpError(429, "Too Many Requests")
        t = [0.0]; lines = []
        gecko = GeckoTerminal(fetch=limited, clock=lambda: t[0])
        disc = Discovery({"discovery": {"sources": ["geckoterminal"]}}, {"geckoterminal": gecko}, log=lambda lvl, msg: lines.append(msg))
        for _ in range(30):
            disc.recent(["solana"]); t[0] += 2
        self.assertEqual(len(lines), 1, lines)

    def test_a_blocked_feed_is_logged_once(self):
        """Live log: pump.fun's Cloudflare block alternated between "HttpError: ..." and
        "RuntimeError: HttpError: ..." - a new line every ten seconds."""
        from bot.sources.geckoterminal import GeckoTerminal
        from bot.sources.http import HttpError
        from bot.sources.pumpfun import PumpFun
        def blocked(url, **kw): raise HttpError(403, "von Cloudflare blockiert")
        t = [0.0]; lines = []
        feeds = {"pumpfun": PumpFun(fetch=blocked, clock=lambda: t[0]),
                 "geckoterminal": GeckoTerminal(fetch=blocked, clock=lambda: t[0])}
        disc = Discovery({"discovery": {"sources": list(feeds)}}, feeds, log=lambda lvl, msg: lines.append(msg))
        for _ in range(30):
            disc.recent(["solana"]); t[0] += 3
        self.assertEqual(len(lines), 2, lines)
        self.assertEqual(lines[0], "Quelle pumpfun: HttpError: HTTP 403: von Cloudflare blockiert")

    def test_rugcheck_looks_again_and_one_unknown_token_pauses_nothing(self):
        from bot.sources.http import HttpError
        from bot.sources.rugcheck import CACHE_TTL_S, RugCheck
        level = ["warn"]; t = [0.0]
        def fetch(url, **kw):
            if "Unknown" in url:
                raise HttpError(404, '{"error":"not found"}')
            return {"score_normalised": 5, "risks": [{"name": "Top holders", "level": level[0]}]}
        rc = RugCheck(fetch=fetch, clock=lambda: t[0])
        self.assertEqual(rc.summary("Good")["danger"], [])
        level[0] = "danger"; t[0] += CACHE_TTL_S + 1                # the token turned dangerous meanwhile
        self.assertEqual(rc.summary("Good")["danger"], ["Top holders"])
        for i in range(5):
            self.assertIsNone(rc.summary(f"Unknown{i}"))            # not indexed yet
        self.assertIsNotNone(rc.summary("Other"))                   # RugCheck is not paused for everyone


class CashTests(unittest.TestCase):
    def test_cash_never_goes_negative_when_the_book_fills_up(self):
        from bot.paper import Paper
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            cfg = copy.deepcopy(CFG); cfg["risk_per_trade_pct"] = 10; cfg["max_open_positions"] = 50; cfg["paper"]["fee_pct"] = 5
            paper = Paper(store, cfg)
            for i in range(30):
                if paper.can_open("solana", f"T{i}"):
                    break
                paper.open({"chain": "solana", "token": f"T{i}", "pair": f"P{i}", "symbol": f"S{i}", "price_usd": 1.0}, 1000.0 + i)
                self.assertGreaterEqual(paper.cash(), -1e-9, f"after {i + 1} buys: cash {paper.cash():.4f}")
            store.close()


class VanishedPairTests(unittest.TestCase):
    def setUp(self):
        import bot.demo as demo
        self.cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite")
        self.dex = FakeDex(accel=1.0); self.t = [self.dex.started]; self.dex.now = lambda: self.t[0]
        self.eng = Engine(copy.deepcopy(CFG), self.store, self.dex, FakeRug(), clock=self.dex.now, feeds=demo_feeds(self.dex))
        self.eng.poll_once()
        self.pos = self.store.open_positions()[0]
        self.real = self.dex.price

    def tearDown(self):
        import bot.demo as demo
        demo.CYCLE_MIN = self.cycle
        self.store.close(); self.tmp.cleanup()

    def run_minutes(self, minutes, step=5):
        for _ in range(0, minutes, step):
            self.t[0] += step * 60
            self.eng.poll_once()

    def test_a_pair_that_vanished_is_written_off_after_the_time_stop(self):
        pair = self.pos["pair"]
        self.dex.price = lambda chain, p: None if p == pair else self.real(chain, p)   # the pair is gone (rug)
        self.run_minutes(40)
        self.assertEqual(self.store.position(self.pos["id"])["status"], "open")      # not yet: could be a hiccup
        self.run_minutes(60)
        closed = self.store.position(self.pos["id"])
        self.assertEqual((closed["status"], closed["exit_reason"]), ("closed", "no_price"))
        self.assertLess(closed["realized_usd"], 0)
        self.assertTrue(any("kein Kurs" in e["message"] for e in self.store.events(40)))

    def test_a_general_outage_does_not_write_positions_off(self):
        self.dex.price = lambda chain, p: None                                          # DexScreener down for everything
        def down(chain, addrs): raise RuntimeError("DexScreener 503")
        self.dex.pairs_for_tokens = down
        self.run_minutes(120)
        self.assertEqual(self.store.position(self.pos["id"])["status"], "open")


class ConfigFileTests(unittest.TestCase):
    def test_a_broken_config_file_does_not_stop_the_start(self):
        from bot.main import load_config
        with tempfile.TemporaryDirectory() as d:
            home = Path(d); (home / "config.json").write_text('{"poll_seconds": 15, "filters": {')     # cut off mid-write
            cfg = load_config(home)
            self.assertEqual(cfg["poll_seconds"], CFG["poll_seconds"])                              # defaults
            self.assertTrue(list(home.glob("config.json.kaputt-*")), "the broken file is kept for inspection")
            self.assertEqual(json.loads((home / "config.json").read_text()).get("_hint") is not None, True)

    def test_invalid_values_in_the_file_fall_back_to_defaults(self):
        from bot.main import load_config
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "config.json").write_text(json.dumps({
                "poll_seconds": "abc", "risk_per_trade_pct": 500, "max_open_positions": 3,
                "filters": {"min_liquidity_usd": -5, "min_age_minutes": 3, "max_age_minutes": 2},
                "ai": {"mode": "yolo", "provider": "openrouter"}, "bankroll_usd": "viel"}))
            cfg = load_config(home)
            self.assertEqual(cfg["poll_seconds"], CFG["poll_seconds"])
            self.assertEqual(cfg["risk_per_trade_pct"], CFG["risk_per_trade_pct"])
            self.assertEqual(cfg["max_open_positions"], 3)                                         # valid values stay
            self.assertEqual(cfg["filters"]["min_liquidity_usd"], CFG["filters"]["min_liquidity_usd"])
            self.assertLess(cfg["filters"]["min_age_minutes"], cfg["filters"]["max_age_minutes"])  # cross-check holds
            self.assertEqual(cfg["ai"]["mode"], CFG["ai"]["mode"]); self.assertEqual(cfg["ai"]["provider"], "openrouter")
            self.assertEqual(cfg["bankroll_usd"], CFG["bankroll_usd"])

    def test_saving_survives_a_broken_file_and_writes_atomically(self):
        from bot.main import persist_to
        with tempfile.TemporaryDirectory() as d:
            home = Path(d); (home / "config.json").write_text("{nonsense")
            persist_to(home)({"poll_seconds": 12})
            self.assertEqual(json.loads((home / "config.json").read_text())["poll_seconds"], 12)
            self.assertEqual([p.name for p in home.iterdir() if p.name.endswith(".tmp")], [])


class NumberMessageTests(unittest.TestCase):
    def test_non_numbers_get_a_german_message(self):
        from bot import settings
        for raw in ("abc", "", None, [], "inf", "nan", "1e999"):
            _, errors = settings.validate({"poll_seconds": raw})
            self.assertIn("poll_seconds", errors, raw)
            self.assertIn(errors["poll_seconds"], ("keine Zahl",), (raw, errors))
        self.assertEqual(settings.validate({"poll_seconds": "12,0"})[0]["poll_seconds"], 12)


class TrackerBatchTests(unittest.TestCase):
    """The edge report is only as honest as the outcome tracking behind it."""

    def make(self, prices_of, price_of=lambda chain, pair: None):
        from bot.tracker import Tracker
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.store = Store(Path(self.tmp.name) / "t.sqlite"); self.addCleanup(self.store.close)
        return Tracker(self.store, CFG, price_of, prices_of)

    def add(self, tracker, i, seen_at=1000.0, chain="solana"):
        return tracker.record({"seen_at": seen_at, "chain": chain, "token": f"T{i}", "pair": f"P{i}", "symbol": f"S{i}",
                               "price_usd": 1.0, "score": 50, "decision": "skip", "reasons": [], "snapshot": {}})

    def test_a_busy_poll_is_measured_on_time_in_few_requests(self):
        calls = []
        def prices_of(chain, pairs, follow=None):
            calls.append(len(pairs)); return {p: 1.5 for p in pairs}
        tr = self.make(prices_of)
        for i in range(40):
            self.add(tr, i)
        filled = sum(tr.fill_due(now=1000.0 + minute * 60 + 5) for minute in (5, 15, 60))
        self.assertEqual(filled, 120)                                  # 40 candidates x 3 horizons, no backlog
        self.assertLessEqual(len(calls), 6); self.assertTrue(all(n <= 30 for n in calls))   # 2 requests per horizon
        self.assertEqual(self.store._one("SELECT COUNT(*) AS n FROM outcomes WHERE filled_at IS NULL")["n"], 0)

    def test_a_made_up_price_is_no_outcome(self):
        tr = self.make(lambda chain, pairs, follow=None: {p: (34_000.0 if p == "P1" else 3.0) for p in pairs})
        c0 = self.add(tr, 0); c1 = self.add(tr, 1)
        tr.fill_due(now=1000.0 + 5 * 60 + 5)
        one = lambda c: self.store._one("SELECT * FROM outcomes WHERE candidate_id=? AND horizon_min=5", (c,))
        self.assertEqual(one(c0)["change_pct"], 200.0)                    # a tripling is a market
        self.assertIsNotNone(one(c1)["filled_at"])
        self.assertIsNone(one(c1)["change_pct"])                          # +3,400,000 % is a bad quote: unknown

    def test_an_old_absurd_outcome_does_not_swamp_the_edge(self):
        """Live page: "buy after 5 min: +78,967 %" - outcomes booked before the made-up-price fix."""
        tr = self.make(lambda chain, pairs, follow=None: {p: 1.2 for p in pairs})
        self.add(tr, 0); old = self.add(tr, 1)
        tr.fill_due(now=1000.0 + 5 * 60 + 5)
        self.store.fill_outcome(old, 5, 79_000.0, 7_899_900.0)                 # what an older version stored
        rep = {(r["horizon_min"], r["decision"]): r for r in self.store.edge_report()}
        self.assertEqual(rep[(5, "skip")]["n"], 1)
        self.assertAlmostEqual(rep[(5, "skip")]["avg_change_pct"], 20.0)

    def test_a_vanished_pair_counts_as_a_total_loss(self):
        def prices_of(chain, pairs, follow=None):
            return {p: 2.0 for p in pairs if p != "P1"}                # P1 was pulled; the rest is priced
        tr = self.make(prices_of)
        self.add(tr, 0); c1 = self.add(tr, 1)
        tr.fill_due(now=1000.0 + 6 * 60)                               # 5-min outcome just due: give it a moment
        row = self.store._one("SELECT * FROM outcomes WHERE candidate_id=? AND horizon_min=5", (c1,))
        self.assertIsNone(row["filled_at"])
        tr.fill_due(now=1000.0 + 16 * 60)                              # 10 min later still nothing: gone
        row = self.store._one("SELECT * FROM outcomes WHERE candidate_id=? AND horizon_min=5", (c1,))
        self.assertEqual(row["change_pct"], -100.0)
        rep = {(r["horizon_min"], r["decision"]): r for r in self.store.edge_report()}
        self.assertEqual(rep[(5, "skip")]["n"], 2)                     # the loss is in the statistics now
        self.assertAlmostEqual(rep[(5, "skip")]["avg_change_pct"], (100.0 - 100.0) / 2)

    def test_a_failed_request_is_never_booked_as_a_rug(self):
        """60 pairs go out in two requests; one fails. Its 30 pairs are unknown, not pulled."""
        def prices_of(chain, pairs, follow=None):
            if "P0" in pairs:
                raise OSError("timeout")
            return {p: 2.0 for p in pairs}
        tr = self.make(prices_of)
        ids = [self.add(tr, i) for i in range(60)]
        tr.fill_due(now=1000.0 + 16 * 60)                              # the 5-min outcomes are 11 min overdue
        rugs = self.store._one("SELECT COUNT(*) AS n FROM outcomes WHERE change_pct = -100")["n"]
        self.assertEqual(rugs, 0)
        open_ = self.store._one("SELECT COUNT(*) AS n FROM outcomes WHERE horizon_min=5 AND filled_at IS NULL")["n"]
        self.assertEqual(open_, 30)                                    # tried again next poll
        self.assertEqual(len(ids), 60)

    def test_an_outage_is_never_booked_as_a_loss(self):
        tr = self.make(lambda chain, pairs: {})                        # DexScreener answers nothing at all
        cid = self.add(tr, 0)
        tr.fill_due(now=1000.0 + 30 * 60)
        self.assertIsNone(self.store._one("SELECT filled_at FROM outcomes WHERE candidate_id=? AND horizon_min=5", (cid,))["filled_at"])
        tr.fill_due(now=1000.0 + 70 * 60)                              # an hour past due: give up as unknown
        row = self.store._one("SELECT * FROM outcomes WHERE candidate_id=? AND horizon_min=5", (cid,))
        self.assertIsNotNone(row["filled_at"]); self.assertIsNone(row["change_pct"])

    def test_without_a_batch_source_single_lookups_still_work(self):
        from bot.tracker import Tracker
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            tr = Tracker(store, CFG, lambda chain, pair: 3.0)
            tr.record({"seen_at": 0.0, "chain": "solana", "token": "t", "pair": "p", "symbol": "T", "price_usd": 1.0,
                       "score": 1, "decision": "buy", "reasons": [], "snapshot": {}})
            self.assertEqual(sum(tr.fill_due(now=minute * 60 + 5.0) for minute in (5, 15, 60)), 3)
            store.close()


class CsvTests(unittest.TestCase):
    def test_token_names_cannot_become_spreadsheet_formulas(self):
        from bot.server import _csv
        rows = [{"symbol": "=HYPERLINK(\"http://evil\",\"x\")", "name": "+cmd|' /C calc'!A0", "reasons": "@SUM(1)",
                 "note": "-2+3", "tab": "\t=1", "ok": "PEPE", "pnl": -5.25, "price": 0.0001}]
        text = _csv(rows, ["symbol", "name", "reasons", "note", "tab", "ok", "pnl", "price"]).decode("utf-8-sig")
        line = text.splitlines()[1].split(";")
        self.assertTrue(all(cell.lstrip('"').startswith("'") for cell in line[:5]), line)
        self.assertEqual(line[5], "PEPE")
        self.assertEqual(line[6], "-5.25")                     # real numbers stay numbers
        self.assertEqual(line[7], "0.0001")


class SlowWorldTests(unittest.TestCase):
    """Real APIs are slow: a poll must still check the stop losses promptly."""

    def setUp(self):
        import bot.demo as demo
        self.cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "t.sqlite")
        self.dex = FakeDex(accel=1.0); self.t = [self.dex.started]; self.dex.now = lambda: self.t[0]

    def tearDown(self):
        import bot.demo as demo
        demo.CYCLE_MIN = self.cycle
        self.store.close(); self.tmp.cleanup()

    def test_rugcheck_is_only_asked_for_tokens_that_pass_the_other_filters(self):
        from bot.strategy import evaluate
        rug = FakeRug(); asked = []
        orig = rug.summary
        rug.summary = lambda mint: (asked.append(mint), orig(mint))[1]
        eng = Engine(copy.deepcopy(CFG), self.store, self.dex, rug, clock=self.dex.now, feeds={"dexscreener": demo_feeds(self.dex)["dexscreener"]})
        eng.poll_once()
        pairs = self.dex.pairs_for_tokens("solana", self.dex.recent_token_addresses(["solana"])["solana"])
        need = {p["token"] for p in pairs if evaluate(p, None, CFG)["decision"] != "skip"}
        self.assertEqual(set(asked), need)
        self.assertLess(len(asked), len(pairs))

    def test_stop_loss_fires_even_when_discovery_is_slow(self):
        import time as _t
        import bot.engine as engine_mod
        eng = Engine(copy.deepcopy(CFG), self.store, self.dex, FakeRug(), clock=self.dex.now, feeds=demo_feeds(self.dex))
        eng.poll_once()
        pid = self.store.open_positions()[0]["id"]
        real = self.dex.price
        self.dex.price = lambda c, p: (real(c, p) or 0) * 0.4
        self.dex.prices = lambda c, ps, follow=None: {p: v * 0.4 for p, v in FakeDex.prices(self.dex, c, ps).items()}
        many = [{"token": f"Slow{i}", "snapshot": None} for i in range(200)]
        feeds = demo_feeds(self.dex); feeds["slow"] = StubFeed({"solana": many})
        eng.discovery.feeds = feeds; eng.cfg["discovery"]["sources"] = ["slow", "dexscreener"]
        orig_pairs = FakeDex.pairs_for_tokens
        def slow_pairs(chain, addrs):
            _t.sleep(0.02 * len(addrs)); return orig_pairs(self.dex, chain, addrs)
        self.dex.pairs_for_tokens = slow_pairs
        old_budget = engine_mod.DISCOVERY_BUDGET_S; engine_mod.DISCOVERY_BUDGET_S = 0.5
        self.addCleanup(setattr, engine_mod, "DISCOVERY_BUDGET_S", old_budget)
        seen_closed_at = []
        orig_discover = eng._discover
        def spy(now, counts):
            seen_closed_at.append(self.store.position(pid)["status"])   # state when discovery starts
            return orig_discover(now, counts)
        eng._discover = spy
        self.t[0] += 120
        started = _t.time(); eng.poll_once(); took = _t.time() - started
        self.assertEqual(seen_closed_at, ["closed"])                     # exits ran before the slow part
        self.assertEqual(self.store.position(pid)["exit_reason"], "stop_loss")
        self.assertLess(took, 8.0)

    def test_a_struggling_rugcheck_is_paused_instead_of_costing_seconds_per_token(self):
        from bot.sources.rugcheck import RugCheck
        calls = []
        def fetch(url, **kw):
            calls.append(kw); raise OSError("429 Too Many Requests")
        t = [1000.0]
        rc = RugCheck(fetch=fetch, clock=lambda: t[0])
        for i in range(10):
            self.assertIsNone(rc.summary(f"M{i}"))
        self.assertEqual(len(calls), 3)                                  # three failures, then a pause
        self.assertTrue(all(kw.get("retries") == 0 for kw in calls))     # no retry sleeps inside a poll
        self.assertIn("Pause", rc.health()["last_error"])
        t[0] += 61
        rc.summary("M99"); self.assertEqual(len(calls), 4)               # tries again after the pause


def mint_value(freeze=None, mint_auth=None, program="spl-token", extensions=None):
    info = {"decimals": 6, "freezeAuthority": freeze, "isInitialized": True, "mintAuthority": mint_auth, "supply": "1000000000000000"}
    if extensions is not None:
        info["extensions"] = extensions
    return {"data": {"parsed": {"info": info, "type": "mint"}, "program": program, "space": 82},
            "executable": False, "lamports": 1461600, "owner": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA", "rentEpoch": 0}


class OnChainCheckTests(unittest.TestCase):
    def test_assess_mint_reads_authorities_and_token2022_traps(self):
        from bot.sources.solana_rpc import assess_mint
        clean = assess_mint(mint_value())
        self.assertEqual((clean["danger"], clean["warn"], clean["source"]), ([], [], "onchain"))
        self.assertIn("Freeze", assess_mint(mint_value(freeze="Creator111"))["danger"][0])
        self.assertIn("Mint", assess_mint(mint_value(mint_auth="Creator111"))["warn"][0])
        ext = [{"extension": "permanentDelegate", "state": {"delegate": "Evil111"}},
               {"extension": "transferHook", "state": {"programId": "Hook111", "authority": None}},
               {"extension": "transferFeeConfig", "state": {"newerTransferFee": {"transferFeeBasisPoints": 250}}},
               {"extension": "defaultAccountState", "state": {"accountState": "frozen"}},
               {"extension": "metadataPointer", "state": {}}]
        r = assess_mint(mint_value(program="spl-token-2022", extensions=ext))
        self.assertEqual(len(r["danger"]), 3, r)
        self.assertIn("Transfergebühr 2.5 %", r["warn"])
        harmless = assess_mint(mint_value(program="spl-token-2022", extensions=[
            {"extension": "permanentDelegate", "state": {"delegate": None}}, {"extension": "transferHook", "state": {"programId": None}},
            {"extension": "transferFeeConfig", "state": {"newerTransferFee": {"transferFeeBasisPoints": 0}}}]))
        self.assertEqual((harmless["danger"], harmless["warn"]), ([], []))
        self.assertIsNone(assess_mint(None)); self.assertIsNone(assess_mint({"data": ["base64", "..."]}))
        self.assertIsNone(assess_mint({"data": {"parsed": {"type": "account", "info": {}}}}))

    def test_rpc_client_caches_and_pauses_after_failures(self):
        from bot.sources.solana_rpc import OnChainCheck
        seen = []
        def post(url, body, timeout=None, headers=None):
            seen.append(body)
            return {"jsonrpc": "2.0", "id": 1, "result": {"context": {"slot": 1}, "value": mint_value()}}
        oc = OnChainCheck(post=post, url="https://rpc.example")
        self.assertEqual(oc.summary("MintA")["danger"], [])
        n = len(seen)
        oc.summary("MintA"); self.assertEqual(len(seen), n)               # cached
        self.assertEqual(seen[0]["method"], "getAccountInfo"); self.assertEqual(seen[0]["params"][1]["encoding"], "jsonParsed")
        t = [0.0]; calls = []
        def broken(url, body, timeout=None, headers=None):
            calls.append(1); return {"jsonrpc": "2.0", "id": 1, "error": {"code": 429, "message": "Too many requests"}}
        oc2 = OnChainCheck(post=broken, url="x", clock=lambda: t[0])
        for i in range(6):
            self.assertIsNone(oc2.summary(f"M{i}"))
        self.assertEqual(len(calls), 3); self.assertIn("Too many", oc2.health()["last_error"])
        self.assertIsNone(OnChainCheck(post=lambda *a, **k: {"result": {"value": None}}, url="x").summary("NoMint"))

    def test_safety_check_prefers_rugcheck_and_falls_back(self):
        from bot.sources.solana_rpc import SafetyCheck
        class R:
            def __init__(self, answer): self.answer, self._cache, self.last_error = answer, {}, ""
            def summary(self, mint): return self.answer
            def health(self): return {"calls": 1, "fails": 0 if self.answer else 1, "last_error": "", "ok": bool(self.answer)}
        onchain = R({"score": 0.0, "danger": [], "warn": [], "source": "onchain"})
        self.assertEqual(SafetyCheck(R({"score": 100, "danger": [], "warn": []}), onchain).summary("M")["source"], "rugcheck")
        both_down = SafetyCheck(R(None), R(None))
        self.assertIsNone(both_down.summary("M"))
        self.assertEqual(SafetyCheck(R(None), onchain).summary("M")["source"], "onchain")
        self.assertIn("fallback", SafetyCheck(R(None), onchain).health())

    def test_strategy_with_the_onchain_result(self):
        from bot.strategy import evaluate
        from bot.sources.solana_rpc import assess_mint
        pairs = FakeDex(accel=1.0).pairs_for_tokens("solana", FakeDex(accel=1.0).recent_token_addresses(["solana"])["solana"])
        run = next(p for p in pairs if p["symbol"] == "RUN")
        clean = dict(assess_mint(mint_value()), holders={"top1": 2.0, "top10": 12.0, "wallets": 10, "programs": 70.0})
        v = evaluate(run, clean, CFG)
        self.assertNotEqual(v["decision"], "skip"); self.assertFalse(v.get("watch_only"))
        self.assertIn("rugcheck 5", " ".join(v["reasons"]))                 # half of RugCheck's points
        creator_only = dict(assess_mint(mint_value()), creator={"creator": "W", "wallets": 1, "share": 1.0})
        self.assertFalse(evaluate(run, creator_only, CFG).get("watch_only"))  # the creator's share is enough
        blind = assess_mint(mint_value())                                    # neither holders nor creator known
        v = evaluate(run, blind, CFG)
        self.assertEqual(v["decision"], "watch"); self.assertTrue(v["watch_only"])
        self.assertTrue(v["reasons"][0].startswith("holder check missing"), v["reasons"])
        cfg = copy.deepcopy(CFG); cfg["filters"]["require_holder_check"] = False
        self.assertFalse(evaluate(run, blind, cfg).get("watch_only"))       # the rule can be switched off
        v = evaluate(run, assess_mint(mint_value(freeze="Creator")), CFG)
        self.assertEqual(v["decision"], "skip"); self.assertIn("onchain danger", v["reasons"][0])
        v = evaluate(run, assess_mint(mint_value(mint_auth="Creator")), CFG)
        self.assertIn("rugcheck 3", " ".join(v["reasons"]))                 # a warning costs two points

    def test_engine_buys_on_the_onchain_check_when_rugcheck_is_down(self):
        from bot.sources.solana_rpc import SafetyCheck, OnChainCheck
        class DownRug:
            _cache = {}; last_error = "DNS"
            def summary(self, mint): return None
            def health(self): return {"calls": 1, "fails": 1, "last_error": "DNS", "ok": False}
        import bot.demo as demo
        cycle = demo.CYCLE_MIN; demo.CYCLE_MIN = 1e9
        self.addCleanup(setattr, demo, "CYCLE_MIN", cycle)
        def node(holders_answer):
            def post(url, body, timeout=None):
                if body["method"] == "getTokenLargestAccounts":
                    return holders_answer
                if body["method"] == "getMultipleAccounts":
                    return {"result": {"value": [{"data": {"parsed": {"info": {"owner": HolderTests.WALLETS[0]}}}}]}}
                return {"result": {"value": mint_value()}}
            return post
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0)
            rpc = OnChainCheck(post=node({"result": {"value": [{"address": "Acct1", "amount": "10000000000000"}]}}), url="x")
            eng = Engine(copy.deepcopy(CFG), store, dex, SafetyCheck(DownRug(), rpc), clock=dex.now, feeds=demo_feeds(dex))
            counts = eng.poll_once()
            self.assertEqual(counts["buy"], 1, counts)                          # RUN bought on the own check
            run = next(c for c in store.candidates() if c["symbol"] == "RUN")
            self.assertEqual(run["snapshot"]["rug"]["source"], "onchain")
            self.assertEqual(run["snapshot"]["rug"]["holders"]["top1"], 1.0)
            h = eng.state()["rugcheck"]
            self.assertFalse(h["ok"]); self.assertTrue(h["fallback"]["ok"])
            store.close()
        with tempfile.TemporaryDirectory() as d:                                  # the node throttles the holder query
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0)
            rpc = OnChainCheck(post=node({"error": {"code": 429, "message": "Too many requests"}}), url="x")
            eng = Engine(copy.deepcopy(CFG), store, dex, SafetyCheck(DownRug(), rpc), clock=dex.now, feeds=demo_feeds(dex))
            counts = eng.poll_once()
            self.assertEqual(counts["buy"], 0, counts); self.assertEqual(store.open_positions(), [])
            run = next(c for c in store.candidates() if c["symbol"] == "RUN")
            self.assertEqual(run["decision"], "watch")
            self.assertTrue(run["reasons"][0].startswith("holder check missing"), run["reasons"])
            self.assertIn("Halter unbekannt (nur beobachtet)", [r["label"] for r in store.skip_reasons()["reasons"]])
            store.close()


class DoctorRugRowTests(unittest.TestCase):
    def test_rugcheck_row_tests_rugcheck_alone(self):
        """With RugCheck down the RugCheck row must say so even though the fallback answers:
        a note (yellow) while the own check covers for it, an error (red) without one."""
        from bot.doctor import run_checks
        from bot.sources.rugcheck import RugCheck
        from bot.sources.solana_rpc import SafetyCheck, OnChainCheck
        down = RugCheck(fetch=lambda url, **kw: (_ for _ in ()).throw(OSError("Could not resolve host: api.rugcheck.xyz")))
        answers = {"getAccountInfo": mint_value(), "getTokenLargestAccounts": [{"address": "Acct1", "amount": "50000000000000"}],
                   "getMultipleAccounts": [{"data": {"parsed": {"info": {"owner": HolderTests.WALLETS[0]}}}}]}
        rpc = OnChainCheck(post=lambda url, body, **k: {"result": {"value": answers[body["method"]]}}, url="x")
        dex = FakeDex()
        rows = {c["name"]: c for c in run_checks(CFG, dex, demo_feeds(dex), SafetyCheck(down, rpc), None)}
        self.assertTrue(rows["RugCheck"]["ok"]); self.assertTrue(rows["RugCheck"].get("warn"))
        self.assertIn("resolve host", rows["RugCheck"]["detail"]); self.assertIn("springt ein", rows["RugCheck"]["detail"])
        self.assertTrue(rows["Eigenprüfung über Solana-RPC (Ersatz für RugCheck)"]["ok"])
        self.assertFalse(rows["Eigenprüfung über Solana-RPC (Ersatz für RugCheck)"].get("warn"))
        self.assertIn("größte Wallet 5.0 %", rows["Eigenprüfung über Solana-RPC (Ersatz für RugCheck)"]["detail"])
        alone = {c["name"]: c for c in run_checks(CFG, dex, demo_feeds(dex), down, None)}
        self.assertFalse(alone["RugCheck"]["ok"])

    def test_a_rate_limit_is_a_note(self):
        from bot.doctor import _check
        from bot.sources.http import HttpError
        def limited():
            raise RuntimeError("solana: " + str(HttpError(429, '{"status":{"error_code":429}}')))
        row = _check("GeckoTerminal – neue Pools & Parser", limited)
        self.assertTrue(row["ok"]); self.assertTrue(row["warn"]); self.assertIn("Rate-Limit", row["detail"])
        self.assertFalse(_check("x", lambda: (_ for _ in ()).throw(RuntimeError("HTTP 500: down")))["ok"])

    def test_curve_reserves_row(self):
        from bot.demo import FakeCurves
        from bot.doctor import run_checks
        dex = FakeDex(); feeds = demo_feeds(dex)
        rows = {c["name"]: c for c in run_checks(CFG, dex, feeds, FakeRug(), None, FakeCurves())}
        self.assertIn("pump.fun-Kurven (Solana-RPC)", rows)
        self.assertTrue(rows["pump.fun-Kurven (Solana-RPC)"]["ok"], rows["pump.fun-Kurven (Solana-RPC)"])


class CurveTests(unittest.TestCase):
    """pump.fun bonding curves: DexScreener sends no liquidity, GeckoTerminal a
    token-side reserve. The figure comes from the curve account on the chain.
    Records below are live data from the macOS CI run."""

    WRLD = {"chainId": "solana", "dexId": "pumpfun", "url": "https://dexscreener.com/solana/7rhi",
            "pairAddress": "7RhioiM25aCurve", "baseToken": {"address": "MintBhinu", "name": "bhinu", "symbol": "bhinu"},
            "quoteToken": {"address": "So11111111111111111111111111111111111111112", "name": "Wrapped SOL", "symbol": "SOL"},
            "priceNative": "0.00000002925", "priceUsd": "0.000003086",
            "txns": {"m5": {"buys": 5, "sells": 1}, "h1": {"buys": 5, "sells": 1}},
            "volume": {"m5": 41.18, "h1": 41.18}, "priceChange": {"m5": 30.21, "h1": 30.21},
            "fdv": 3086.59, "marketCap": 3086.59, "pairCreatedAt": 1792395462000}
    # (virtual tokens, virtual quote, real tokens, real quote, supply) of live curve accounts
    BHINU = (1048881697855587, 30689829050, 768981697855587, 689829050, 1000000000000000)       # SOL, standard curve
    DOG_THINK = (947380763814062, 774488104, 667480763814062, 124825557, 1000000000000000)    # USDC-quoted curve
    CHAROC = (1063000000000000, 300000000, 783100000000000, 100000000, 1000000000000000)      # SOL, tiny curve

    @staticmethod
    def account(fields, complete=False):
        import struct
        return b"\x17\xb7\xf8\x37\x60\xd8\xac\x60" + struct.pack("<5Q", *fields) + bytes([1 if complete else 0]) + b"\x00" * 117

    def rpc(self, accounts, owner="6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P"):
        import base64
        calls = []

        def post(url, body, timeout=None):
            calls.append(body)
            values = []
            for a in body["params"][0]:
                data = accounts.get(a)
                values.append(None if data is None else {"owner": owner, "lamports": 1, "executable": False,
                                                           "data": [base64.b64encode(data).decode(), "base64"]})
            return {"jsonrpc": "2.0", "id": 1, "result": {"context": {"slot": 1}, "value": values}}
        return post, calls

    def test_the_account_layout_matches_the_live_record(self):
        from bot.sources.curve import parse_pump_curve, pool_liquidity
        st = parse_pump_curve(self.account(self.BHINU))
        self.assertAlmostEqual(st["virtual_tokens"], 1048881697.855587)
        self.assertEqual(st["virtual_quote_raw"], 30689829050); self.assertFalse(st["complete"])
        # a constant product holds as much quote as its virtual tokens are worth: 2 x 30.69 SOL x $105.5
        sol_usd = 105.5
        price = (30689829050 / 1e9) / (1048881697855587 / 1e6) * sol_usd
        self.assertAlmostEqual(pool_liquidity(st["virtual_tokens"], price), 2 * 30.689829050 * sol_usd, places=6)
        self.assertTrue(parse_pump_curve(self.account(self.BHINU, complete=True))["complete"])
        self.assertIsNone(parse_pump_curve(b"\x00" * 20))

    def test_pairs_get_their_liquidity_from_the_chain_in_one_call(self):
        from bot.sources.curve import CurveReader
        from bot.sources.dexscreener import normalize_pair
        post, calls = self.rpc({"7RhioiM25aCurve": self.account(self.BHINU), "DogCurve": self.account(self.DOG_THINK),
                                "DoneCurve": self.account(self.BHINU, complete=True)})
        bhinu = normalize_pair(self.WRLD)
        self.assertEqual((bhinu["liquidity_kind"], bhinu["liquidity_usd"]), ("unknown", 0.0))
        dog = normalize_pair(dict(self.WRLD, pairAddress="DogCurve", priceUsd="0.00000553",
                                  quoteToken={"address": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", "symbol": "USDC"}))
        done = normalize_pair(dict(self.WRLD, pairAddress="DoneCurve"))
        dbc = normalize_pair(dict(self.WRLD, dexId="meteoradbc", pairAddress="DbcPool"))
        pool = normalize_pair(dict(self.WRLD, dexId="raydium", pairAddress="RayPool", liquidity={"usd": 42000.0}))
        reader = CurveReader(post=post)
        self.assertEqual(reader.enrich([bhinu, dog, done, dbc, pool]), 3)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["method"], "getMultipleAccounts")
        self.assertEqual(sorted(calls[0]["params"][0]), ["7RhioiM25aCurve", "DogCurve", "DoneCurve"])
        self.assertEqual(bhinu["liquidity_kind"], "curve")
        self.assertAlmostEqual(bhinu["liquidity_usd"], 2 * 1048881697.855587 * 3.086e-6, places=2)        # ~ $6,474
        self.assertAlmostEqual(dog["liquidity_usd"], 2 * 947380763.814062 * 5.53e-6, places=2)            # USDC quote works too
        self.assertEqual((done["liquidity_kind"], done["liquidity_usd"]), ("graduated", 0.0))
        self.assertEqual((dbc["liquidity_kind"], dbc["liquidity_usd"]), ("unknown", 0.0))
        self.assertEqual((pool["liquidity_kind"], pool["liquidity_usd"]), ("reported", 42000.0))

    def test_foreign_accounts_and_rpc_trouble_leave_the_figure_unknown(self):
        from bot.sources.curve import CurveReader
        from bot.sources.dexscreener import normalize_pair
        post, _ = self.rpc({"7RhioiM25aCurve": self.account(self.BHINU)}, owner="11111111111111111111111111111111")
        p = normalize_pair(self.WRLD)
        self.assertEqual(CurveReader(post=post).enrich([p]), 0)
        self.assertEqual(p["liquidity_kind"], "unknown")
        t = [0.0]
        def broken(url, body, timeout=None):
            raise OSError("RPC down")
        reader = CurveReader(post=broken, clock=lambda: t[0])
        for _ in range(3):
            self.assertEqual(reader.enrich([normalize_pair(self.WRLD)]), 0)
        self.assertIn("Pause", reader.last_error)
        calls = reader.calls
        reader.enrich([normalize_pair(self.WRLD)])
        self.assertEqual(reader.calls, calls)                                   # paused: no further calls
        self.assertFalse(reader.health()["ok"])

    def test_the_price_alone_would_be_wrong_for_many_curves(self):
        # CHAROC traded on a curve with 0.3 SOL virtual reserves: the standard-curve formula
        # would have claimed ~20 SOL; the account says a few hundred dollars
        from bot.sources.curve import CurveReader
        from bot.sources.dexscreener import normalize_pair
        from bot.strategy import evaluate
        post, _ = self.rpc({"CharocCurve": self.account(self.CHAROC)})
        p = normalize_pair(dict(self.WRLD, pairAddress="CharocCurve", priceNative="0.00000001247", priceUsd="0.000001316"))
        CurveReader(post=post).enrich([p])
        self.assertLess(p["liquidity_usd"], 3000)
        self.assertTrue(any(r.startswith("liquidity $") for r in evaluate(p, None, copy.deepcopy(CFG))["reasons"]))

    def test_gecko_curve_reserve_is_not_taken_for_liquidity(self):
        def pool(dex, reserve):
            return {"attributes": {"address": "P" + dex, "name": "X / SOL", "reserve_in_usd": reserve,
                                   "base_token_price_usd": "0.000004", "quote_token_price_usd": "105.873245"},
                    "relationships": {"base_token": {"data": {"id": "solana_MintX"}},
                                      "dex": {"data": {"id": dex}}}}
        for dex, reserve in (("pump-fun", "3147.5328"), ("meteora-dbc", "0.0"), ("raydium-launchlab", "3544.9146")):
            n = normalize_pool(pool(dex, reserve), "solana", {})
            self.assertEqual((n["liquidity_kind"], n["liquidity_usd"], n["curve"]), ("unknown", 0.0, True), dex)
        amm = normalize_pool(pool("raydium", "42000.5"), "solana", {})
        self.assertEqual((amm["liquidity_kind"], amm["liquidity_usd"], amm["curve"]), ("reported", 42000.5, False))

    def test_the_filter_names_the_real_reason(self):
        from bot.sources.dexscreener import normalize_pair
        from bot.strategy import evaluate
        cfg = copy.deepcopy(CFG)
        unknown = normalize_pair(dict(self.WRLD, dexId="meteoradbc"))
        self.assertTrue(any(r.startswith("liquidity unknown") for r in evaluate(unknown, None, cfg)["reasons"]))
        done = dict(normalize_pair(self.WRLD), liquidity_kind="graduated")
        self.assertTrue(any(r.startswith("curve completed") for r in evaluate(done, None, cfg)["reasons"]))
        busy = dict(normalize_pair(dict(self.WRLD, txns={"m5": {"buys": 60, "sells": 20}}, volume={"m5": 9000.0},
                                        priceChange={"m5": 12.0}), now=1792395462 + 600),
                    liquidity_usd=26000.0, liquidity_kind="curve")
        verdict = evaluate(busy, {"score": 0.0, "danger": [], "warn": [], "source": "onchain"}, cfg)
        self.assertNotEqual(verdict["decision"], "skip", verdict)
        self.assertTrue(any(r.startswith("pump.fun-Kurve") for r in verdict["reasons"]), verdict)
        labels = [label for _, label, _ in Store.REASON_RULES]
        self.assertIn("Liquidität unbekannt (Bonding-Kurve ohne Angabe)", labels)
        self.assertIn("Kurve abgeschlossen (Handel wechselt in den Pool)", labels)

    def test_the_engine_reads_only_curves_that_are_due(self):
        from bot.demo import FakeCurves
        seen = []
        class Spy(FakeCurves):
            def enrich(self, pairs):
                seen.append(sorted(p["symbol"] for p in pairs if p.get("dex") == "pumpfun"))
                return super().enrich(pairs)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started + 7 * 60]; dex.now = lambda: t[0]
            eng = Engine(copy.deepcopy(CFG), store, dex, FakeRug(), clock=dex.now, curves=Spy())
            eng.poll_once()
            curve = next(c for c in store.candidates() if c["symbol"] == "CURVE")
            self.assertEqual(curve["snapshot"]["liquidity_kind"], "curve")
            t[0] += 10
            eng.poll_once()                                 # judged 10 s ago: not due, not read again
            self.assertEqual(seen, [["CURVE"], []])
            store.close()


class ReentryPauseTests(unittest.TestCase):
    """The demo runner CURVE exits on its trailing stop at minute 29 and still
    looks like a buy afterwards: it must not be bought straight back."""

    def run_demo(self, pause):
        import bot.demo as demo
        cycle = demo.CYCLE_MIN
        demo.CYCLE_MIN = 1e9
        self.addCleanup(setattr, demo, "CYCLE_MIN", cycle)
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        store = Store(Path(tmp.name) / "t.sqlite"); self.addCleanup(store.close)
        cfg = copy.deepcopy(CFG); cfg["reentry_pause_minutes"] = pause
        cfg["filters"]["allow_curve_buys"] = True          # the pause is what is tested, on the demo's curve coin
        dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
        from bot.demo import FakeCurves
        eng = Engine(cfg, store, dex, FakeRug(), clock=dex.now, curves=FakeCurves())
        for minutes in range(0, 60, 2):
            t[0] = dex.started + minutes * 60
            eng.poll_once()
        buys = [c for c in store.candidates(500) if c["symbol"] == "CURVE" and c["decision"] == "buy"]
        return store, eng, buys

    def test_a_sold_token_is_not_bought_straight_back(self):
        store, eng, buys = self.run_demo(120)
        self.assertEqual(len(buys), 1)
        later = [c for c in store.candidates(500) if c["symbol"] == "CURVE" and c["seen_at"] > buys[0]["seen_at"]]
        self.assertTrue(any(any("re-entry pause" in r for r in c["reasons"]) for c in later), later)
        self.assertIn("Kauf blockiert (Limit, Pause, Bestand)", [r["label"] for r in store.skip_reasons()["reasons"]])
        # the button is the user's own decision: it still buys
        cid = later[-1]["id"]
        self.assertTrue(eng.open_from_candidate(cid)["ok"])

    def test_pause_zero_allows_the_re_entry(self):
        _store, _eng, buys = self.run_demo(0)
        self.assertGreaterEqual(len(buys), 2)

    def test_the_setting_is_in_the_form(self):
        entry = next(e for e in settings.SCHEMA if e["path"] == "reentry_pause_minutes")
        self.assertEqual(entry["group"], "Risiko")
        self.assertEqual(settings.validate({"reentry_pause_minutes": -5})[1].keys(), {"reentry_pause_minutes"})
        self.assertEqual(settings.validate({"reentry_pause_minutes": 0})[0], {"reentry_pause_minutes": 0.0})



class GraduationTests(unittest.TestCase):
    """A pump.fun curve completes and the token moves to a PumpSwap pool. The
    curve pair then either freezes or disappears; a holding and the outcome
    tracker must follow the token to its new pool instead."""

    SOL = {"address": "So11111111111111111111111111111111111111112", "symbol": "SOL"}

    def raw(self, pair, token, dex, price, liquidity=None, native=None):
        r = {"chainId": "solana", "dexId": dex, "pairAddress": pair, "url": f"https://dexscreener.com/solana/{pair}",
             "baseToken": {"address": token, "symbol": "GRAD", "name": "Graduate"}, "quoteToken": self.SOL,
             "priceUsd": str(price), "priceNative": str(native if native is not None else price / 150.0),
             "txns": {"m5": {"buys": 0, "sells": 0}}, "volume": {"m5": 0}, "priceChange": {"m5": 0},
             "pairCreatedAt": 1_799_990_000_000}
        if liquidity is not None:
            r["liquidity"] = {"usd": liquidity}
        return r

    def fake_http(self, pairs):
        calls = []

        def fetch(url, **_kw):
            calls.append(url)
            if "/latest/dex/pairs/" in url:
                wanted = url.rsplit("/", 1)[1].split(",")
                return {"pairs": [p for p in pairs if p["pairAddress"] in wanted]}
            if "/tokens/v1/" in url:                       # every pair the token is part of, either side
                wanted = [w.lower() for w in url.rsplit("/", 1)[1].split(",")]   # the real API ignores 0x case
                return [p for p in pairs if p["baseToken"]["address"].lower() in wanted or p["quoteToken"]["address"].lower() in wanted]
            return []
        return fetch, calls

    def test_a_completed_curve_is_priced_from_its_new_pool(self):
        from bot.sources.dexscreener import DexScreener
        # the curve froze at completion (~115 virtual SOL); the PumpSwap pool trades on, 40 % lower
        frozen_native = 115.0 ** 2 / 32.19e9
        curve = self.raw("Curve1", "Mint1", "pumpfun", frozen_native * 150, native=frozen_native)
        pool = self.raw("Swap1", "Mint1", "pumpswap", frozen_native * 150 * 0.6, liquidity=17000)
        fetch, calls = self.fake_http([curve, pool])
        dex = DexScreener(fetch=fetch)
        got = dex.prices("solana", ["Curve1"], {"Curve1": "Mint1"})
        self.assertAlmostEqual(got["Curve1"], frozen_native * 150 * 0.6)
        # discovery also picks the pool, not the frozen curve
        best = dex.pairs_for_tokens("solana", ["Mint1"])[0]
        self.assertEqual(best["pair"], "Swap1")

    def test_a_running_curve_and_a_plain_pool_keep_their_own_price(self):
        from bot.sources.dexscreener import DexScreener
        running = self.raw("Curve2", "Mint2", "pumpfun", 60.0 ** 2 / 32.19e9 * 150, native=60.0 ** 2 / 32.19e9)
        junk = self.raw("Junk2", "Mint2", "raydium", 1.0, liquidity=40)        # a dust pool someone opened
        plain = self.raw("Pool3", "Mint3", "raydium", 0.002, liquidity=50000)
        fetch, calls = self.fake_http([running, junk, plain])
        got = DexScreener(fetch=fetch).prices("solana", ["Curve2", "Pool3"], {"Curve2": "Mint2", "Pool3": "Mint3"})
        self.assertAlmostEqual(got["Curve2"], 60.0 ** 2 / 32.19e9 * 150)
        self.assertEqual(got["Pool3"], 0.002)
        self.assertEqual(sum("/tokens/v1/" in u for u in calls), 1)              # only the curve was looked up
        self.assertNotIn("Mint3", next(u for u in calls if "/tokens/v1/" in u))

    def test_a_foreign_pool_next_to_a_running_curve_never_prices_it(self):
        """Someone opens their own pool beside a running pump.fun curve, at a very different
        price: a holding on the curve must not be stopped out at that price."""
        from bot.sources.dexscreener import DexScreener
        price = 60.0 ** 2 / 32.19e9 * 150
        running = self.raw("Curve7", "Mint7", "pumpfun", price, native=price / 150)
        foreign = self.raw("Meteora7", "Mint7", "meteora", price * 0.1, liquidity=25000)
        fetch, _ = self.fake_http([running, foreign])
        got = DexScreener(fetch=fetch).prices("solana", ["Curve7"], {"Curve7": "Mint7"})
        self.assertAlmostEqual(got["Curve7"], price)                              # not the pool's -90 %
        heir = self.raw("Swap7", "Mint7", "pumpswap", price * 0.8, liquidity=15000)  # it graduates after all
        fetch, _ = self.fake_http([running, foreign, heir])
        got = DexScreener(fetch=fetch).prices("solana", ["Curve7"], {"Curve7": "Mint7"})
        self.assertAlmostEqual(got["Curve7"], price * 0.8)                        # the PumpSwap pool, though smaller
        fetch, _ = self.fake_http([foreign])                                       # the curve is gone: any pool
        self.assertAlmostEqual(DexScreener(fetch=fetch).prices("solana", ["Curve7"], {"Curve7": "Mint7"})["Curve7"], price * 0.1)
        dbc = self.raw("Dbc8", "Mint8", "meteoradbc", 0.001, native=0.001 / 150)      # Meteora's launchpad curve
        rogue = self.raw("Pool8", "Mint8", "meteora", 0.0001, liquidity=30000)       # an ordinary Meteora pool beside it
        fetch, _ = self.fake_http([dbc, rogue])
        self.assertAlmostEqual(DexScreener(fetch=fetch).prices("solana", ["Dbc8"], {"Dbc8": "Mint8"})["Dbc8"], 0.001)

    def test_a_pool_at_a_made_up_price_never_prices_a_holding(self):
        """Live run: a coin worth $0.00003 had a second pool opened at $1 with only its own
        tokens in it - DexScreener reads that as $1M of liquidity. The holding's pool
        dropped out of one answer and the bot sold at $1.017."""
        from bot.sources.dexscreener import DexScreener, normalize_pair
        usdc = {"address": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", "symbol": "USDC"}
        fake = self.raw("Fake10", "Mint10", "meteora", 1.017, native=1.017)
        fake.update(quoteToken=usdc, liquidity={"usd": 1_000_000, "base": 983_000, "quote": 3})
        side = self.raw("Side10", "Mint10", "raydium", 3.1e-5)
        side["liquidity"] = {"usd": 20_000, "base": 66.7 * 150 / 3.1e-5, "quote": 66.7}   # 66.7 SOL = $10,000 paired
        self.assertEqual(normalize_pair(fake)["liquidity_usd"], 6.0)                 # 3 USDC is all one could sell into
        self.assertAlmostEqual(normalize_pair(side)["liquidity_usd"], 20_000, delta=50)
        fetch, _ = self.fake_http([fake, side])
        dex = DexScreener(fetch=fetch)
        self.assertAlmostEqual(dex.prices("solana", ["Main10"], {"Main10": "Mint10"})["Main10"], 3.1e-5)
        self.assertEqual(dex.pairs_for_tokens("solana", ["Mint10"])[0]["pair"], "Side10")
        fetch, _ = self.fake_http([fake])                                            # nothing but the fake pool
        self.assertEqual(DexScreener(fetch=fetch).prices("solana", ["Main10"], {"Main10": "Mint10"}), {})
        flipped = self.raw("Flip10", "JunkMint", "meteora", 5.0, native=5.0 / 3.1e-5)  # our token on the quote side,
        flipped.update(quoteToken={"address": "Mint10", "symbol": "MRCY"},          # the pool holding only junk
                       liquidity={"usd": 500_000, "base": 100_000, "quote": 0})
        fetch, _ = self.fake_http([flipped])
        self.assertEqual(DexScreener(fetch=fetch).prices("solana", ["Main10"], {"Main10": "Mint10"}), {})

    def test_a_pool_is_priced_by_its_reserves_not_by_its_last_trade(self):
        """Live probe: DexScreener's price sat 27 % above what a quiet PumpSwap pool's
        reserves pay (89 % on one with no trade for minutes) - the vaults on the chain
        matched DexScreener's own reserve figures to the token. A sale gets the reserves'
        price; the last trade's is history."""
        from bot.sources.dexscreener import normalize_pair, token_price
        lion = self.raw("Lion1", "LionMint", "pumpswap", 2.392e-05, native=2.392e-05 / 104.54)
        lion["liquidity"] = {"usd": 11446, "base": 276543383, "quote": 46.22}
        n = normalize_pair(lion)
        self.assertAlmostEqual(n["price_usd"], 46.22 * 104.54 / 276543383)          # 1.747e-05, not 2.392e-05
        self.assertEqual(n["price_last_usd"], 2.392e-05)
        self.assertAlmostEqual(token_price(n, "LionMint"), n["price_usd"])
        self.assertAlmostEqual(n["liquidity_base_usd"], n["liquidity_quote_usd"])    # at the true price both sides weigh the same
        curve = self.raw("Curve9", "CurveMint", "pumpfun", 1e-5)
        curve["liquidity"] = {"base": 8e8, "quote": 30}                               # a curve's reserves are virtual: its own price
        self.assertEqual(normalize_pair(curve)["price_usd"], 1e-5)
        odd = self.raw("Odd9", "OddMint", "meteora", 2e-5)
        odd.update(quoteToken={"address": "SomeMemeMint", "symbol": "MEME"}, liquidity={"usd": 9000, "base": 1, "quote": 1})
        self.assertEqual(normalize_pair(odd)["price_usd"], 2e-5)                      # an unknown quote: no dollar price for it

    def test_a_price_always_belongs_to_the_token_held(self):
        """Live data showed outcomes of +9,000,000 % in 15 minutes: a pool listing the token
        on its quote side reports the OTHER token's price (here a dollar coin at 0.96)."""
        from bot.sources.dexscreener import DexScreener
        usd = {"address": "USD1mint", "symbol": "USD1"}
        inverted = {"chainId": "solana", "dexId": "pumpswap", "pairAddress": "Inv9", "url": "https://dexscreener.com/solana/inv9",
                    "baseToken": usd, "quoteToken": {"address": "Mint9", "symbol": "TRUMP"},
                    "priceUsd": "0.96", "priceNative": str(0.96 / 1e-5), "liquidity": {"usd": 30000},
                    "txns": {"m5": {"buys": 3, "sells": 1}}, "volume": {"m5": 100}, "priceChange": {"m5": 0},
                    "pairCreatedAt": 1_799_990_000_000}
        fetch, _ = self.fake_http([inverted])
        dex = DexScreener(fetch=fetch)
        self.assertAlmostEqual(dex.prices("solana", ["Inv9"], {"Inv9": "Mint9"})["Inv9"], 1e-5)   # not 0.96
        self.assertAlmostEqual(dex.price("solana", "Inv9", "Mint9"), 1e-5)
        self.assertEqual(dex.pairs_for_tokens("solana", ["Mint9"]), [])          # no candidate for the dollar coin
        stranger = dict(inverted, quoteToken={"address": "Other", "symbol": "X"})  # a pair the token is not part of
        fetch, _ = self.fake_http([stranger])
        self.assertEqual(DexScreener(fetch=fetch).prices("solana", ["Inv9"], {"Inv9": "Mint9"}), {})
        # the token's pair vanished; only a dust pool with a fantasy price is left: no price, a rug
        dust = self.raw("Dust9", "Mint10", "raydium", 0.9, liquidity=40)
        fetch, _ = self.fake_http([dust])
        self.assertEqual(DexScreener(fetch=fetch).prices("solana", ["Gone10"], {"Gone10": "Mint10"}), {})
        # and the token's pool listed the other way round still prices it, also when followed
        flipped = dict(inverted, pairAddress="Flip11")
        fetch, _ = self.fake_http([flipped])
        self.assertAlmostEqual(DexScreener(fetch=fetch).prices("solana", ["Gone11"], {"Gone11": "Mint9"})["Gone11"], 1e-5)

    def test_evm_addresses_are_one_token_however_they_are_spelled(self):
        from bot.sources.dexscreener import DexScreener
        checksum = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        pool = dict(self.raw("0xPool", checksum, "uniswap", 1.0, liquidity=500000), chainId="base")
        fetch, _ = self.fake_http([pool])
        got = DexScreener(fetch=fetch).pairs_for_tokens("base", [checksum.lower()])        # GeckoTerminal's spelling
        self.assertEqual([g["token"] for g in got], [checksum.lower()])
        feeds = {"a": StubFeed({"base": [{"token": checksum, "snapshot": None}]}),
                 "b": StubFeed({"base": [{"token": checksum.lower(), "snapshot": None}]})}
        found = Discovery({"discovery": {"sources": ["a", "b"]}}, feeds).recent(["base"])
        self.assertEqual(list(found["base"]), [checksum.lower()])                          # one token, not two

    def test_a_dead_promotion_feed_shows_as_down(self):
        from bot.sources.dexscreener import DexScreener
        def fetch(url, **kw): raise OSError("403")
        with self.assertRaises(OSError):
            DexScreener(fetch=fetch).recent_token_addresses(["solana"])
        status = Discovery({"discovery": {"sources": ["dexscreener"]}}, {"dexscreener": DexScreenerFeed(DexScreener(fetch=fetch))})
        status.recent(["solana"])
        self.assertFalse(status.status()[0]["ok"])

    def test_a_vanished_pair_follows_the_token_and_a_true_rug_stays_missing(self):
        from bot.sources.dexscreener import DexScreener
        pool = self.raw("Swap4", "Mint4", "pumpswap", 0.0001, liquidity=20000)
        fetch, _ = self.fake_http([pool])
        got = DexScreener(fetch=fetch).prices("solana", ["Curve4", "Gone5"], {"Curve4": "Mint4", "Gone5": "Mint5"})
        self.assertEqual(got, {"Curve4": 0.0001})

    def test_holding_and_tracker_follow_the_graduation(self):
        from bot.sources.dexscreener import DexScreener
        frozen_native = 115.0 ** 2 / 32.19e9
        entry = frozen_native * 150 * 0.9
        pairs = [self.raw("Curve6", "Mint6", "pumpfun", entry, native=entry / 150)]
        fetch, _ = self.fake_http(pairs)
        dex = DexScreener(fetch=fetch)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            t = [1_800_000_000.0]
            eng = Engine(copy.deepcopy(CFG), store, dex, FakeRug(), clock=lambda: t[0])
            pid = eng.paper.open({"chain": "solana", "token": "Mint6", "pair": "Curve6", "symbol": "GRAD", "price_usd": entry}, t[0])
            eng.tracker.record({"seen_at": t[0], "chain": "solana", "token": "Mint6", "pair": "Curve6", "symbol": "GRAD",
                                "price_usd": entry, "score": 70, "decision": "buy", "reasons": [], "snapshot": {}})
            # the curve completes: DexScreener drops it, the token trades in PumpSwap at half the entry
            pairs[:] = [self.raw("Swap6", "Mint6", "pumpswap", entry * 0.5, liquidity=18000)]
            t[0] += 5 * 60 + 1
            eng.poll_once()
            pos = store.position(pid)
            self.assertEqual((pos["status"], pos["exit_reason"]), ("closed", "stop_loss"))   # sold on the real market, not written off
            self.assertFalse(any("abgeschrieben" in e["message"] for e in store.events(50)))
            five = next(o for o in store.outcomes_for(store.candidates()[0]["id"]) if o["horizon_min"] == 5)
            self.assertAlmostEqual(five["change_pct"], -50.0, places=1)                       # not -100 % "rug"
            store.close()

    def test_manual_close_and_buy_follow_the_new_pool(self):
        # the Schließen button on a token whose curve completed sells at the new pool's price
        from bot.sources.dexscreener import DexScreener
        frozen_native = 115.0 ** 2 / 32.19e9
        frozen = frozen_native * 150
        pairs = [self.raw("Curve7", "Mint7", "pumpfun", frozen, native=frozen_native),
                 self.raw("Swap7", "Mint7", "pumpswap", frozen * 0.6, liquidity=17000)]
        fetch, _ = self.fake_http(pairs)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite")
            eng = Engine(copy.deepcopy(CFG), store, DexScreener(fetch=fetch), FakeRug(), clock=lambda: 1_800_000_000.0)
            pid = eng.paper.open({"chain": "solana", "token": "Mint7", "pair": "Curve7", "symbol": "GRAD", "price_usd": frozen}, 1_800_000_000.0)
            self.assertTrue(eng.close_position(pid)["ok"])
            sell = [t for t in store.trades_for(pid) if t["side"] == "sell"][0]
            self.assertAlmostEqual(sell["price"], frozen * 0.6 * (1 - eng.paper.slippage_pct / 100), places=12)
            cid = eng.tracker.record({"seen_at": 1_800_000_000.0, "chain": "solana", "token": "Mint7", "pair": "Curve7", "symbol": "GRAD",
                                      "price_usd": frozen, "score": 1, "decision": "watch", "reasons": [], "snapshot": {}})
            r = eng.open_from_candidate(cid)
            self.assertTrue(r["ok"], r)
            self.assertAlmostEqual(r["position"]["entry_price"], frozen * 0.6 * (1 + eng.paper.slippage_pct / 100), places=12)
            store.close()


class HttpRetryTests(unittest.TestCase):
    def test_no_sleep_after_the_last_attempt(self):
        import urllib.error
        from unittest import mock
        from bot.sources import http
        slept = []
        with mock.patch.object(http.urllib.request, "urlopen", side_effect=urllib.error.URLError("nodename nor servname provided")), \
                mock.patch.object(http.time, "sleep", side_effect=slept.append):
            with self.assertRaises(urllib.error.URLError):
                http.get_json("https://api.rugcheck.xyz/x", retries=0)
            self.assertEqual(slept, [])                      # RugCheck (retries=0) fails at once
            with self.assertRaises(urllib.error.URLError):
                http.get_json("https://api.example/x", retries=2)
            self.assertEqual(slept, [1.0, 2.0])              # between attempts only

    def test_an_error_page_is_named_not_pasted(self):
        from bot.sources.http import HttpError
        challenge = '<!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title>' + "x" * 500
        e = HttpError(403, challenge)
        self.assertEqual(str(e), "HTTP 403: von Cloudflare blockiert (Browser-Prüfung) – von dieser Internetadresse aus nicht abrufbar")
        self.assertEqual(e.body, challenge)                                   # the page itself stays available
        self.assertEqual(str(HttpError(502, "\n <html><body>Bad gateway</body></html>")), "HTTP 502: HTML-Seite statt Daten")
        origin_down = "<!DOCTYPE html><title>example.com | 521: Web server is down</title>Cloudflare Ray ID: 8f"
        self.assertEqual(str(HttpError(521, origin_down)), "HTTP 521: HTML-Seite statt Daten")     # down, not blocked
        self.assertEqual(str(HttpError(429, '{"error":"Too many requests"}')), 'HTTP 429: {"error":"Too many requests"}')



class PaperLiveSnapshotTests(unittest.TestCase):
    """tools/paper_live.py renders what the published window shows."""

    def test_snapshot_renders_and_escapes_strangers_text(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("paper_live", ROOT / "tools" / "paper_live.py")
        pl = importlib.util.module_from_spec(spec); spec.loader.exec_module(pl)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d) / "t.sqlite"); dex = FakeDex(accel=1.0); t = [dex.started + 7 * 60]; dex.now = lambda: t[0]
            from bot.demo import FakeCurves
            eng = Engine(copy.deepcopy(CFG), store, dex, FakeRug(), clock=dex.now, feeds=demo_feeds(dex), curves=FakeCurves())
            eng.poll_once()
            state = json.loads(json.dumps(eng.state()))
            state["candidates"][0]["symbol"] = '<script>alert(1)</script>|x'
            out = Path(d) / "site"
            pl.write(state, out, "https://example.invalid/")
            page = (out / "index.html").read_text()
            report = (out / "REPORT.md").read_text()
            self.assertNotIn("<script>alert(1)", page); self.assertIn("&lt;script&gt;", page)
            self.assertIn("Offene Positionen", page); self.assertIn("https://pump.fun/coin/", page)   # the demo curve token
            self.assertIn("Kurve", page)
            self.assertIn("| Bankroll (realisiert) |", report); self.assertNotIn("</script>|x", report)
            self.assertEqual(json.loads((out / "state.json").read_text())["app"], "new-token-bot")
            pl.write({"candidates": [], "open_positions": [], "closed": [], "stats": {}}, out)        # a bot that has not polled yet
            self.assertIn("noch kein Poll", (out / "REPORT.md").read_text())
            store.close()


class HolderTests(unittest.TestCase):
    """Who holds the supply? Wallets (ed25519 keys) count, program-owned accounts
    (the pump.fun curve, pools, lockers: off-curve addresses) do not."""

    # deterministic real ed25519 public keys (RFC 8032 derivation of sha256("wallet<i>"))
    WALLETS = ['7QmZqUQCrHWsEanUyUPpHw1vFymTyiQ9vjrpjspiT5nv', '9hbzj3oVQx7b8keUiqMk4XNqCSBvuqkpZG3TAjnAHBi8',
               '2rjcX6cLDS8uw8tjCcLzUcCnM5q6hJVahbycXn6VAVmt', 'HufzXQeKo93k6X9kCxBWosFiBsLruTNRBhc7CK6px1vN',
               'FwBKLMDuj58Utja1aB5AuNJ8AeeBrQmAvypuYd2Xk8kS', '4CdrXNeEBpE7wqNkdvSqxdeyLwpyBShGKSZfSi922euy',
               'BKQ8MXCuhfe17w58UdvrPKHej7nfDuxo4UZZoS721XmL', 'DHUWntrwfKXXwTqc7JNFcaYf6AyfYcHe6KZbBBGdB6N7',
               'Ag3F7t84EzWreF961jNgFG7eGQ9KUtimkFbfXDDMECtj', '4Mj2SH7Vay6omJhBgobehSxJDPkgVBh1j5FG2KDaiNtc',
               '8n614VToDPSZcvXAX6KjQm8FDscMa57kjZ957nAL4ZC4', 'J5hQDshHP8L6VVyMBsVZiVnmedwTJP2QnmboHQeAC55r']
    CURVE = "7ycZsifNrbZmVdKPEjV9NguxsyHD4n2fTw8piQNsJBai"        # a live pump.fun bonding curve (a PDA)

    def test_on_curve_tells_wallets_from_program_addresses(self):
        from bot.sources.solana_rpc import on_curve
        self.assertTrue(all(on_curve(w) is True for w in self.WALLETS))
        for pda in (self.CURVE, "4xiW3NYhNYPTDGm5frrWKzYJZDptgpUamsLApfLtskX4", "5Q544fKrFoe6tsEbD7S8EmxGTJYAKtTVhAW5Q5pge4j1"):
            self.assertIs(on_curve(pda), False, pda)
        self.assertIsNone(on_curve("not-an-address")); self.assertIsNone(on_curve("1111"))

    def rpc(self, holdings, supply=1_000_000_000_000_000):
        """holdings: [(owner, share %)] -> a fake RPC answering the three calls."""
        accounts = [{"address": f"TokenAcct{i}", "amount": str(int(supply * share / 100)), "decimals": 6}
                    for i, (_, share) in enumerate(holdings)]
        owners = {f"TokenAcct{i}": owner for i, (owner, _) in enumerate(holdings)}
        calls = []

        def post(url, body, timeout=None):
            calls.append(body["method"])
            if body["method"] == "getAccountInfo":
                return {"result": {"value": mint_value()}}
            if body["method"] == "getTokenLargestAccounts":
                return {"result": {"value": accounts}}
            if body["method"] == "getMultipleAccounts":
                return {"result": {"value": [{"data": {"parsed": {"type": "account", "info": {"owner": owners[a]}}}}
                                             for a in body["params"][0]]}}
            raise AssertionError(body["method"])
        return post, calls

    def test_a_fresh_pump_coin_with_the_curve_on_top_is_fine(self):
        from bot.sources.solana_rpc import OnChainCheck
        post, calls = self.rpc([(self.CURVE, 78.0)] + [(w, 2.0) for w in self.WALLETS[:8]])
        r = OnChainCheck(post=post, url="x").summary("MintCurve")
        self.assertEqual(calls, ["getAccountInfo", "getTokenLargestAccounts", "getMultipleAccounts"])
        self.assertEqual((r["danger"], r["warn"]), ([], []))
        self.assertEqual(r["holders"], {"top1": 2.0, "top10": 16.0, "wallets": 8, "programs": 78.0})

    def test_a_whale_or_a_cluster_is_danger_and_skipped(self):
        from bot.sources.solana_rpc import OnChainCheck
        from bot.strategy import evaluate
        post, _ = self.rpc([(self.WALLETS[0], 30.0), (self.CURVE, 50.0)] + [(w, 1.0) for w in self.WALLETS[1:6]])
        whale = OnChainCheck(post=post, url="x").summary("MintWhale")
        self.assertTrue(any("eine Wallet hält 30 %" in d for d in whale["danger"]), whale)
        post, _ = self.rpc([(w, 6.5) for w in self.WALLETS[:10]])
        cluster = OnChainCheck(post=post, url="x").summary("MintCluster")
        self.assertTrue(any("10 größten Wallets halten 65 %" in d for d in cluster["danger"]), cluster)
        post, _ = self.rpc([(self.WALLETS[0], 12.0)] + [(w, 3.0) for w in self.WALLETS[1:9]])
        mild = OnChainCheck(post=post, url="x").summary("MintMild")
        self.assertEqual(mild["danger"], []); self.assertEqual(len(mild["warn"]), 2, mild)       # 12 % and 36 %
        cfg = copy.deepcopy(CFG)
        pair = {"chain": "solana", "token": "MintWhale", "pair": "P", "price_usd": 1.0, "liquidity_usd": 40000.0,
                "volume_m5": 9000.0, "buys_m5": 40, "sells_m5": 10, "change_m5": 10.0, "fdv": 1e6, "age_min": 10.0}
        self.assertIn("Wallet hält 30 %", evaluate(pair, whale, cfg)["reasons"][0])

    def test_holder_rpc_trouble_is_a_warning_not_a_failure(self):
        from bot.sources.solana_rpc import OnChainCheck
        def post(url, body, timeout=None):
            if body["method"] == "getAccountInfo":
                return {"result": {"value": mint_value()}}
            return {"error": {"code": 429, "message": "Too many requests"}}
        oc = OnChainCheck(post=post, url="x")
        r = oc.summary("MintX")
        self.assertIsNotNone(r); self.assertEqual(r["danger"], [])
        self.assertIn("Halterverteilung unbekannt (RPC ohne Antwort)", r["warn"])
        self.assertEqual(oc.fails, 0)                                  # the check itself answered

    def test_extra_holder_endpoints_are_tried_and_the_answering_one_kept_first(self):
        from bot.sources import solana_rpc
        post, calls = self.rpc([(self.WALLETS[0], 5.0)])
        asked, owners_from = [], []
        def routed(url, body, timeout=None):
            if body["method"] == "getMultipleAccounts":
                owners_from.append(url)
            if body["method"] == "getTokenLargestAccounts":
                asked.append(url)
                if url != "https://keyed.example/?api-key=k":
                    return {"error": {"code": 429, "message": "Too many requests for a specific RPC call"}}
            return post(url, body, timeout)
        env = {"SOLANA_RPC_URL": "https://public.example", "SOLANA_HOLDER_RPCS": " https://busy.example , https://keyed.example/?api-key=k,"}
        with mock.patch.dict(os.environ, env):
            self.assertEqual(solana_rpc.holder_urls(), ["https://public.example", "https://busy.example", "https://keyed.example/?api-key=k"])
            oc = solana_rpc.OnChainCheck(post=routed)
        r = oc.summary("M1")
        self.assertEqual(r["holders"]["top1"], 5.0); self.assertEqual(oc.health()["last_error"], "")
        self.assertEqual(asked, ["https://public.example", "https://busy.example", "https://keyed.example/?api-key=k"])
        oc.summary("M2")
        self.assertEqual(asked[3:], ["https://keyed.example/?api-key=k"])     # straight to the one that answers
        self.assertEqual(owners_from, ["https://keyed.example/?api-key=k"] * 2)   # the owners from the same node
        self.assertEqual(solana_rpc.OnChainCheck(post=routed, url="x").holder_urls, ["x"])   # an explicit URL is used alone

    MINT = "7nnvdguRdh7W1A7tTMAxGB3VJ4A2Jz9afVaMr5Lepump"      # live pump.fun coin and its curve (DexScreener's pair)
    MINT_CURVE = "4axbdpx2RGX7YUvdzq7gsQ2D3gTgRUbTojKtw4UQepMU"

    def creator_rpc(self, amounts, program="spl-token", curve_owner=None, creator=None, fee_config=None):
        """Holder query throttled; the curve's creator field names `creator` (default WALLETS[0]);
        `amounts` maps a wallet to the raw amount in its token account (absent: no account)."""
        import base64, struct
        from bot.sources.solana_rpc import PUMP_FEES_PROGRAM, PUMP_PROGRAM, TOKEN_PROGRAMS, ATA_PROGRAM, b58decode, find_program_address
        creator = creator or self.WALLETS[0]
        data = b"\x17" * 8 + struct.pack("<5Q", 10**15, 3 * 10**10, 8 * 10**14, 10**9, 10**15) + b"\x00" + b58decode(creator)
        ata_of = {find_program_address([b58decode(w), b58decode(TOKEN_PROGRAMS[program]), b58decode(self.MINT)], ATA_PROGRAM): w
                  for w in self.WALLETS}
        asked = []
        def post(url, body, timeout=None):
            method, params = body["method"], body["params"]
            asked.append((method, params[0]))
            if method == "getTokenLargestAccounts":
                return {"error": {"code": 429, "message": "Too many requests for a specific RPC call"}}
            if method == "getAccountInfo" and params[0] == self.MINT:
                return {"result": {"value": mint_value(program=program)}}
            if method == "getAccountInfo" and params[0] == creator:              # the fee-sharing account
                return {"result": {"value": None if fee_config is None else
                                   {"owner": PUMP_FEES_PROGRAM, "data": [base64.b64encode(fee_config).decode(), "base64"]}}}
            if method == "getAccountInfo":                                       # the curve
                return {"result": {"value": {"owner": curve_owner or PUMP_PROGRAM, "data": [base64.b64encode(data + b"\x00" * 85).decode(), "base64"]}}}
            if method == "getMultipleAccounts":                                  # the creator side's token accounts
                out = []
                for a in params[0]:
                    w = ata_of[a]
                    out.append(None if w not in amounts else {"data": {"parsed": {"type": "account", "info": {
                        "mint": self.MINT, "owner": w, "tokenAmount": {"amount": str(amounts[w])}}}}})
                return {"result": {"value": out}}
            raise AssertionError(method)
        return post, asked

    def fee_config(self, admin, holders, mint=None):
        import struct
        from bot.sources.solana_rpc import b58decode
        blob = bytes.fromhex("d84a0900388c5d4b") + bytes([251, 2, 1]) + b58decode(mint or self.MINT) + b58decode(admin) + b"\x00"
        blob += struct.pack("<I", len(holders)) + b"".join(b58decode(a) + struct.pack("<H", bps) for a, bps in holders)
        return blob + b"\x00" * (1024 - len(blob))

    def test_without_the_holder_query_the_creator_of_a_pump_coin_is_checked(self):
        from bot.sources.solana_rpc import OnChainCheck, find_program_address, b58encode, b58decode
        self.assertEqual(b58encode(b58decode(self.MINT)), self.MINT)
        self.assertEqual(find_program_address([b"bonding-curve", b58decode(self.MINT)], "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P"), self.MINT_CURVE)
        post, asked = self.creator_rpc({self.WALLETS[0]: 200_000_000_000_000})          # 20 % of 10^15
        r = OnChainCheck(post=post, url="x").summary(self.MINT)
        self.assertEqual(asked[2], ("getAccountInfo", self.MINT_CURVE))
        self.assertEqual(r["creator"], {"creator": self.WALLETS[0], "wallets": 1, "share": 20.0})
        self.assertTrue(any("Ersteller hält 20 %" in d for d in r["danger"]), r)
        self.assertTrue(any("nur der Ersteller geprüft (20.0 %)" in w for w in r["warn"]), r)
        post, _ = self.creator_rpc({})                                                    # sold out: no token account left
        r = OnChainCheck(post=post, url="x").summary(self.MINT)
        self.assertEqual((r["danger"], r["creator"]["share"]), ([], 0.0))
        post, asked22 = self.creator_rpc({self.WALLETS[0]: 60_000_000_000_000}, program="spl-token-2022")
        r = OnChainCheck(post=post, url="x").summary(self.MINT)
        self.assertEqual(r["warn"][0], "der Ersteller hält 6 %")
        self.assertNotEqual(asked22[3][1], asked[3][1])                                  # Token-2022 accounts live elsewhere
        post, asked = self.creator_rpc({}, curve_owner="SomeOtherProgram1111111111111111111111111")
        r = OnChainCheck(post=post, url="x").summary(self.MINT)
        self.assertNotIn("creator", r); self.assertIn("Halterverteilung unbekannt (RPC ohne Antwort)", r["warn"])

    def test_a_coin_sharing_its_fees_is_checked_through_its_fee_account(self):
        from bot.sources.solana_rpc import OnChainCheck
        pda = self.CURVE                                                                 # an off-curve address
        admin, a, b = self.WALLETS[1], self.WALLETS[2], self.WALLETS[3]
        good = self.fee_config(admin, [(a, 7000), (b, 3000)])
        post, asked = self.creator_rpc({admin: 50_000_000_000_000, b: 70_000_000_000_000}, creator=pda, fee_config=good)
        r = OnChainCheck(post=post, url="x").summary(self.MINT)
        self.assertEqual(r["creator"], {"creator": admin, "wallets": 3, "share": 12.0})
        self.assertIn("Ersteller und Gebühren-Teilhaber (3 Wallets) halten 12 %", r["warn"])
        self.assertEqual(len(next(p for m, p in asked if m == "getMultipleAccounts")), 3)
        for bad in (self.fee_config(admin, [(a, 7000), (b, 2000)]),                     # shares do not add up
                    self.fee_config(admin, [(a, 10000)], mint=self.WALLETS[5]),          # another coin's account
                    b"\x00" * 40):                                                       # too short
            post, _ = self.creator_rpc({admin: 50_000_000_000_000}, creator=pda, fee_config=bad)
            r = OnChainCheck(post=post, url="x").summary(self.MINT)
            self.assertNotIn("creator", r); self.assertIn("Halterverteilung unbekannt (RPC ohne Antwort)", r["warn"])
        post, _ = self.creator_rpc({}, creator=pda, fee_config=None)                     # named, but no such account
        self.assertNotIn("creator", OnChainCheck(post=post, url="x").summary(self.MINT))

    def test_after_a_429_the_holder_query_rests_and_the_creator_check_carries_on(self):
        from bot.sources.solana_rpc import HOLDER_PAUSE_S, OnChainCheck
        post, asked = self.creator_rpc({self.WALLETS[0]: 10_000_000_000_000})
        t = [0.0]
        oc = OnChainCheck(post=post, url="x", clock=lambda: t[0])
        oc.summary(self.MINT)
        oc._cache.clear(); t[0] += 5
        r = oc.summary(self.MINT)
        self.assertEqual([m for m, _ in asked].count("getTokenLargestAccounts"), 1)      # resting: not asked again
        self.assertEqual(r["creator"]["share"], 1.0)                                      # the creator check still ran
        self.assertIn("ruht", oc.health()["last_error"])
        oc._cache.clear(); t[0] += HOLDER_PAUSE_S
        oc.summary(self.MINT)
        self.assertEqual([m for m, _ in asked].count("getTokenLargestAccounts"), 2)      # tried again after the pause

    def test_results_expire_so_holders_are_looked_at_again(self):
        from bot.sources.solana_rpc import CACHE_TTL_S, OnChainCheck
        post, calls = self.rpc([(self.WALLETS[0], 5.0)])
        t = [0.0]
        oc = OnChainCheck(post=post, url="x", clock=lambda: t[0])
        oc.summary("M"); oc.summary("M")
        self.assertEqual(calls.count("getTokenLargestAccounts"), 1)
        t[0] += CACHE_TTL_S + 1
        oc.summary("M")
        self.assertEqual(calls.count("getTokenLargestAccounts"), 2)



class ChainPriceTests(unittest.TestCase):
    """DexScreener refreshes a pair about every 30 seconds (live: the same price three
    polls in a row); a PumpSwap pool's vaults on the chain hold this second's price."""

    KEYS = {name: __import__("hashlib").sha256(name.encode()).digest()
            for name in ("pool", "creator", "mint", "lp", "base_vault", "quote_vault", "other", "foreign")}

    def addr(self, name):
        from bot.sources.solana_rpc import b58encode
        return b58encode(self.KEYS[name])

    def chain(self, base_raw=2_000_000 * 10 ** 6, quote_raw=30 * 10 ** 9, base_mint="mint"):
        import base64
        import struct
        from bot.sources.curve import PUMPSWAP_PROGRAM, WSOL
        from bot.sources.solana_rpc import b58decode
        k = self.KEYS
        pool = (b"\0" * 8 + b"\xfe" + b"\0\0" + k["creator"] + k[base_mint] + b58decode(WSOL) + k["lp"]
                + k["base_vault"] + k["quote_vault"] + struct.pack("<Q", 1) + k["creator"])
        vault = lambda mint, amount: mint + k["pool"] + struct.pack("<Q", amount) + b"\0" * 93
        mint = lambda dec: b"\0" * 36 + struct.pack("<Q", 10 ** 15) + bytes([dec, 1]) + b"\0" * 36
        accounts = {self.addr("pool"): (PUMPSWAP_PROGRAM, pool),
                    self.addr("foreign"): ("SomeOtherAmm1111111111111111111111111111111", pool),
                    self.addr("base_vault"): ("Tokenkeg", vault(k["mint"], base_raw)),
                    self.addr("quote_vault"): ("Tokenkeg", vault(b58decode(WSOL), quote_raw)),
                    self.addr("mint"): ("Tokenkeg", mint(6)), self.addr("other"): ("Tokenkeg", mint(6)),
                    WSOL: ("Tokenkeg", mint(9))}
        calls = []

        def post(url, body, timeout=None):
            asked = body["params"][0]; calls.append(asked)
            return {"result": {"value": [None if a not in accounts else
                                         {"owner": accounts[a][0], "data": [base64.b64encode(accounts[a][1]).decode(), "base64"]}
                                         for a in asked]}}
        return post, calls

    def test_a_pumpswap_pool_is_priced_from_its_vaults(self):
        from bot.sources.curve import WSOL, CurveReader
        post, calls = self.chain()
        reader = CurveReader(post=post, url="http://rpc")
        sol = {WSOL: 150.0}
        got = reader.pool_prices({self.addr("pool"): self.addr("mint")}, sol)
        self.assertAlmostEqual(got[self.addr("pool")], 30 / 2_000_000 * 150.0)           # 30 SOL for 2M tokens
        self.assertEqual(len(calls), 3)                                                 # pool, mints, vaults
        reader.pool_prices({self.addr("pool"): self.addr("mint")}, sol)
        self.assertEqual(len(calls), 4)                                                 # from now on: the vaults only
        self.assertEqual(set(calls[-1]), {self.addr("base_vault"), self.addr("quote_vault")})
        # another token's pool, a pool of another program, an unknown account: no price, never asked again
        odd = {self.addr("pool"): self.addr("other"), self.addr("foreign"): self.addr("mint"), self.addr("lp"): self.addr("mint")}
        fresh = CurveReader(post=post, url="http://rpc")
        self.assertEqual(fresh.pool_prices(odd, sol), {})
        n = len(calls)
        self.assertEqual(fresh.pool_prices(odd, sol), {})
        self.assertEqual(len(calls), n)
        self.assertEqual(CurveReader(post=post, url="http://rpc").pool_prices({self.addr("pool"): self.addr("mint")}, {}), {})   # no SOL price yet

    def test_dexscreener_learns_the_sol_price_from_its_pairs(self):
        from bot.sources.dexscreener import DexScreener
        sol = {"address": "So11111111111111111111111111111111111111112", "symbol": "SOL"}
        pairs = [{"chainId": "solana", "dexId": "pumpswap", "pairAddress": f"P{i}", "baseToken": {"address": f"T{i}"},
                  "quoteToken": sol, "priceUsd": str(0.00001 * px), "priceNative": "0.00001",
                  "liquidity": {"usd": 9000, "base": 4e8, "quote": 30}}             # reserves at another price than the last trade
                 for i, px in enumerate((149, 150, 151, 9999))]
        dex = DexScreener(fetch=lambda url, **kw: {"pairs": pairs})
        dex.prices("solana", ["P0", "P1", "P2", "P3"])
        self.assertAlmostEqual(dex.quote_usd["So11111111111111111111111111111111111111112"], 151.0)   # the median, not the outlier

    def engine(self, d, chain_price):
        dex = FakeDex(accel=1.0); t = [dex.started]; dex.now = lambda: t[0]
        run = next(p for p in dex.pairs_for_tokens("solana", dex.recent_token_addresses(["solana"])["solana"]) if p["symbol"] == "RUN")

        class Chain:
            calls = 0
            def health(self): return {}
            def read(self, accounts): return {}
            def pool_prices(self, pairs, quote_usd):
                Chain.calls += 1
                return {p: chain_price[0] for p in pairs if p == run["pair"] and chain_price[0]}
        store = Store(Path(d) / "t.sqlite")
        return Engine(copy.deepcopy(CFG), store, dex, FakeRug(), clock=lambda: t[0], feeds=demo_feeds(dex), curves=Chain()), store, run, t

    def test_holdings_and_buys_use_the_chain_price(self):
        with tempfile.TemporaryDirectory() as d:
            chain_price = [None]
            eng, store, run, t = self.engine(d, chain_price)
            listed = 0.001
            eng.dex.prices = lambda chain, ps, follow=None: {run["pair"]: listed}
            p, fell = eng._entry_price("solana", run)
            self.assertEqual((p["price_usd"], fell), (run["price_usd"], None))           # nothing on the chain: DexScreener's
            chain_price[0] = run["price_usd"] * 1.2                                      # it ran on since DexScreener's figure
            p, fell = eng._entry_price("solana", run)
            self.assertEqual(p["price_usd"], run["price_usd"] * 1.2); self.assertIsNone(fell)
            self.assertEqual(p["price_dex"], run["price_usd"])
            chain_price[0] = run["price_usd"] * 0.5                                      # it crashed meanwhile: no buy
            self.assertIn("-50% on the chain", eng._entry_price("solana", run)[1])
            pid = eng.paper.open(run, t[0])
            chain_price[0] = listed * 0.9
            self.assertAlmostEqual(eng._position_prices([store.position(pid)])[pid], listed * 0.9)
            chain_price[0] = listed * 5                                                  # no half minute explains that
            self.assertAlmostEqual(eng._position_prices([store.position(pid)])[pid], listed)
            store.close()

    def test_the_exit_watch_sells_between_polls(self):
        with tempfile.TemporaryDirectory() as d:
            chain_price = [None]
            eng, store, run, t = self.engine(d, chain_price)
            pid = eng.paper.open(run, t[0]); store.tick(pid, t[0], run["price_usd"])
            ticks = lambda: len(store.ticks_for(pid))
            t[0] += 2
            self.assertEqual(eng._watch_exits(t[0]), 0)                                  # the chain cannot price it: nothing
            chain_price[0] = run["price_usd"] * 1.05
            t[0] += 2
            self.assertEqual(eng._watch_exits(t[0]), 0)
            self.assertEqual(ticks(), 1)                                                 # no tick every two seconds
            chain_price[0] = run["price_usd"] * 0.6                                      # the fall, seconds before the poll
            t[0] += 2
            self.assertEqual(eng._watch_exits(t[0]), 1)
            pos = store.position(pid)
            self.assertEqual(pos["exit_reason"], "stop_loss")
            self.assertEqual(ticks(), 2)                                                 # the price it sold at is on the chart
            store.close()
