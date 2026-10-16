import copy
import json
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
        self.assertIn("discovery.sources", settings.validate({"discovery.sources": ["pumpfun"]})[1])
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
