"""The polling loop: discover -> evaluate -> record -> (paper) trade -> manage exits."""
from __future__ import annotations

import threading
import time
from typing import Any, Callable, Optional

from . import settings
from .ai import ClaudeAdvisor
from .discovery import DexScreenerFeed, Discovery
from .paper import Paper
from .sources.dexscreener import payout_price
from .store import Store
from .strategy import evaluate
from .tracker import Tracker

RESEE_SECONDS = 30 * 60      # a hard skip (rug danger, too old, parabolic) is not re-evaluated within half an hour
RESEE_TOO_NEW = 2 * 60       # "too new" is a timing issue, not a verdict: look again in two minutes
RESEE_WATCH = 5 * 60         # a watch passed every filter; its numbers move fast, so re-check every five minutes
FOLLOW_GRACE_S = 10 * 60     # a token followed past its feed: this long after it is due for DexScreener to list it
FOLLOW_MAX = 2000
FOLLOW_RESTORE_S = 30 * 60   # after a restart, follow-ups are picked up from this far back
# a holding quoted at this many times its last price from one poll to the next is a bad quote (a pool
# opened at a made-up price, another token's number), not a market: no real pool moves 10x in seconds
PRICE_JUMP_MAX = 10.0
# a pool's price read on the chain is this second's, DexScreener's up to half a minute old: the chain's
# wins - unless it is this many times above DexScreener's, which no half minute explains (a misread)
CHAIN_MAX_ABOVE = 3.0
# a pool's quote reserve (its SOL) down by this much from its high while the price has not fallen
# like a sale would make it: the liquidity is being pulled - out before the tokens are dumped into it.
# In a constant-product pool a sale that takes 25 % of the SOL drops the price by 44 %; a withdrawal
# takes both sides and leaves the price where it was.
LIQ_PULL = 0.25
LIQ_PULL_PRICE = 0.30        # ... and the price is down less than this from where the reserve peaked
EXIT_WATCH_S = 2.0           # between polls, holdings priced on the chain are checked this often


_PRESETS: Optional[dict[str, dict[str, Any]]] = None


def presets() -> dict[str, dict[str, Any]]:
    """Shipped parameter sets (bot/presets.json): Locker / Standard / Streng."""
    global _PRESETS
    if _PRESETS is None:
        import json as _json
        from pathlib import Path as _P
        try:
            _PRESETS = _json.loads((_P(__file__).parent / "presets.json").read_text())
        except (OSError, ValueError):
            _PRESETS = {}
    return _PRESETS


def resee_after(last: Optional[dict[str, Any]]) -> float:
    """How long after its last evaluation a token may be looked at again."""
    if last is None:
        return 0.0
    if last["decision"] == "skip" and any("too new" in r for r in last["reasons"]):
        return RESEE_TOO_NEW
    if last["decision"] == "watch":
        return RESEE_WATCH
    return RESEE_SECONDS
VERSION = "0.9"
APP_ID = "new-token-bot"      # marker in /api/state so starters can tell this bot from whatever else listens on the port
TICK_KEEP_DAYS = 7
HISTORY_KEEP_DAYS = 30       # candidates and outcomes older than this are dropped at start
# the price every report measures with: 2 = what a pool's reserves pay (1 was DexScreener's last
# trade, which kept dying coins at their old price). A database from before starts its edge anew.
PRICE_MODEL = 2
PATH_KEEP_DAYS = 7           # price paths (the backtest's data, the bulk of the database) this long
DISCOVERY_BUDGET_S = 20.0      # seconds per poll for finding and judging new tokens; the rest waits for the next poll
NO_PRICE_WRITE_OFF_MIN = 30.0   # minutes without any price (and past the time stop) before a position is written off
REPORT_TTL = 10.0            # seconds: edge reports and breakdowns are recomputed at most this often       # price ticks of positions closed longer ago are dropped at start


class Engine:
    def __init__(self, cfg: dict[str, Any], store: Store, dex: Any, rug: Any,
                 clock: Callable[[], float] = time.time, advisor: Any = None,
                 feeds: Optional[dict[str, Any]] = None, curves: Any = None) -> None:
        self.cfg = cfg
        self.store = store
        self.dex = dex
        self.rug = rug
        self.curves = curves                     # reads pump.fun curve reserves (liquidity) from the chain
        self.clock = clock
        self.discovery = Discovery(cfg, feeds if feeds is not None else {"dexscreener": DexScreenerFeed(dex)}, log=store.log)
        self.advisor = advisor or ClaudeAdvisor(cfg, log=store.log)
        self.paper = Paper(store, cfg)
        self.tracker = Tracker(store, cfg, dex.price, getattr(dex, "prices", None))
        self.paused = False
        self.last_poll: Optional[float] = None
        self.last_poll_wall: Optional[float] = None   # real time, for the liveness indicator
        self.last_prices: dict[str, float] = {}
        self.poll_count = 0
        self.poll_ms_last: Optional[int] = None
        self.poll_ms_avg: Optional[int] = None
        self.errors = 0
        self.started_at = clock()
        self.persist: Optional[Callable[[dict[str, Any]], None]] = None
        self.home: Optional[Any] = None          # data dir, set by main for the self-test
        self.demo = False                        # set by main: fake market, no real token pages
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._lock = threading.Lock()
        self._reports: dict[str, tuple[float, Any, int]] = {}
        self._bad_tokens: dict[str, float] = {}    # token -> when its record last broke the evaluation
        self._last_discovery_error = ""
        # position id -> engine time of its last price; after a restart the clock starts anew for all,
        # or one missing price would write off a position the bot simply was not watching
        self._last_priced: dict[int, float] = {p["id"]: clock() for p in store.open_positions()}
        self._good_price: dict[int, float] = {}       # position id -> its last believable price
        self._refused: dict[int, float] = {}          # position id -> the bad quote last logged for it
        self._watch_error = ""
        self._liq_peak: dict[int, tuple[float, float]] = {}   # position id -> (highest quote reserve, price then)
        self._dex_answered = False                # did DexScreener itself answer during the last discovery?
        self._dex_answered_now = False
        self._deferred_last = 0
        # tokens to look at again (too new, or watched): (chain, token) -> source, age, when due
        self._followed: dict[tuple[str, str], dict[str, Any]] = {}
        self._restore_followed()
        if store.get("price_model") != PRICE_MODEL:
            store.set("edge_since", clock())
            store.set("price_model", PRICE_MODEL)

    def _report(self, key: str, fn: Callable[[], Any]) -> Any:
        """The page polls every 2 s; the aggregate reports only need to move with the polls."""
        now = time.time()
        hit = self._reports.get(key)
        if hit and now - hit[0] < REPORT_TTL and hit[2] == self.poll_count:
            return hit[1]
        value = fn()
        self._reports[key] = (now, value, self.poll_count)
        return value

    def invalidate_reports(self) -> None:
        self._reports.clear()

    # --- one cycle ------------------------------------------------------
    def poll_once(self) -> dict[str, int]:
        started = time.time()
        try:
            return self._poll(self.clock())
        finally:
            ms = (time.time() - started) * 1000
            self.poll_ms_last = round(ms)
            self.poll_ms_avg = round(ms if self.poll_ms_avg is None else 0.8 * self.poll_ms_avg + 0.2 * ms)

    def _discover(self, now: float, counts: dict[str, int]) -> None:
        """Find, judge and (paper-)buy new tokens."""
        deadline = time.time() + DISCOVERY_BUDGET_S
        self._dex_answered_now = False
        found = self.discovery.recent(list(self.cfg["chains"]))
        self._bring_back(found, now)
        for chain, tokens in found.items():
            if not tokens:
                continue
            pairs: list[dict[str, Any]] = []
            addresses = list(tokens)
            for i in range(0, len(addresses), 30):
                if time.time() > deadline:
                    counts["deferred"] += len(addresses) - i
                    break
                pairs.extend(self.dex.pairs_for_tokens(chain, addresses[i:i + 30]))
            indexed = {p["token"] for p in pairs}
            self._dex_answered_now = self._dex_answered_now or bool(indexed)   # feed snapshots do not count
            for token, info in tokens.items():
                snap = info.get("snapshot")
                if token not in indexed and snap and snap.get("pair") and snap.get("price_usd"):
                    pairs.append(dict(snap, via_feed=True))   # not on DexScreener yet: judge the feed's own numbers (needs a price)
            for p in pairs:                                    # DexScreener sometimes lacks the listing time; the feed knows it
                snap = (tokens.get(p["token"]) or {}).get("snapshot")
                if p.get("age_min") is None and snap and snap.get("age_min") is not None:
                    p["age_min"] = snap["age_min"]
                    p["age_from_feed"] = True
            if self.curves is not None:
                # one RPC call for the liquidity of every pump.fun curve that is due for a verdict
                due = [p for p in pairs if now - self._bad_tokens.get(p.get("token") or "", -1e18) >= RESEE_SECONDS
                       and self._due(chain, p["token"], now)]
                try:
                    self.curves.enrich(due)
                except Exception as error:  # noqa: BLE001 - without the figure the curves are skipped as "unknown"
                    self.store.log("error", f"Kurven-Reserven: {type(error).__name__}: {error}")
            for p in pairs:
                if now - self._bad_tokens.get(p.get("token") or "", -1e18) < RESEE_SECONDS:
                    continue                                   # broke last time: give its record half an hour
                if time.time() > deadline:
                    counts["deferred"] += 1                    # not recorded, so judged on the next poll
                    continue
                try:
                    p["source"] = (tokens.get(p["token"]) or {}).get("source")
                    counts["seen"] += 1
                    if not self._due(chain, p["token"], now):
                        continue
                    counts["new"] += 1
                    # cheap filters first: RugCheck (a slow web call) only for tokens that pass the rest
                    verdict = evaluate(p, None, self.cfg)
                    rug = None
                    if chain == "solana" and verdict["decision"] != "skip":
                        rug = self.rug.summary(p["token"])
                        verdict = evaluate(p, rug, self.cfg)
                    decision = verdict["decision"]
                    p["rule_decision"] = decision
                    if p.get("via_feed") and decision != "skip":
                        # exits are priced by DexScreener: a position it cannot price would never be
                        # stopped out, so a feed-only token is watched until DexScreener lists it
                        verdict["watch_only"] = True
                        verdict["reasons"].insert(0, "noch nicht bei DexScreener – kein Kurs für Stop-Loss, nur beobachten")
                        if decision == "buy":
                            decision = "watch"
                    p["rug"] = rug
                    ai = self.advisor.judge(p, rug, verdict) if decision in ("buy", "watch") else None
                    if ai:
                        p["ai_decision"], p["ai_confidence"] = ai["decision"], round(ai["confidence"], 2)
                        p["ai_reasons"], p["ai_flags"], p["ai_model"] = ai["reasons"], ai["risk_flags"], ai["model"]
                        verdict["reasons"].append("KI " + ai["decision"] + f" ({ai['confidence']:.0%}): " + "; ".join(ai["reasons"][:2]))
                        if self.cfg["ai"].get("mode") == "decide":
                            want = ai["decision"]
                            if want == "buy" and ai["confidence"] < float(self.cfg["ai"].get("min_confidence", 0.6)):
                                want = "watch"
                                verdict["reasons"].append("KI-Vertrauen unter Schwelle")
                            if want == "buy" and verdict.get("watch_only"):
                                want = "watch"                      # no RugCheck answer: the model may not override the safety rule
                            decision = want
                    opened: Optional[int] = None
                    if decision == "buy" and self.paused:
                        decision = "watch"
                        verdict["reasons"].insert(0, "not opened: paused")
                    elif decision == "buy":
                        p, fell = self._entry_price(chain, p)          # network: outside the lock
                        # check and open in one step under the dashboard's lock, or a manual
                        # "Kaufen" in between could open the same token a second time
                        with self._lock:
                            blocked = fell or self.paper.can_open(chain, p["token"]) or self.paper.reentry_paused(chain, p["token"], now)
                            if not blocked:
                                opened = self.paper.open(p, now)
                        if blocked:
                            decision = "watch"
                            verdict["reasons"].insert(0, f"not opened: {blocked}")
                    counts[decision] += 1
                    self.tracker.record({
                        "seen_at": now, "chain": chain, "token": p["token"], "pair": p["pair"],
                        "symbol": p.get("symbol"), "price_usd": p["price_usd"],
                        "score": verdict["score"], "decision": decision,
                        "reasons": verdict["reasons"], "snapshot": p,
                    })
                    if opened is not None:
                        self.last_prices[p["pair"]] = p["price_usd"]
                        self.store.tick(opened, now, p["price_usd"])
                    self._follow(chain, p, decision, verdict["reasons"], now)
                except Exception as error:  # noqa: BLE001 - one broken record must not stop the others
                    self.errors += 1
                    self._bad_tokens[p.get("token") or ""] = now
                    self.store.log("error", f"Token {p.get('symbol') or p.get('token')} übersprungen (30 min): "
                                            f"{type(error).__name__}: {error}")


    def _entry_price(self, chain: str, p: dict[str, Any]) -> tuple[dict[str, Any], Optional[str]]:
        """A buy is filled at the pool's price this second where the chain can be read
        (DexScreener's figure in the verdict may be half a minute old) - and not at all
        when that price has already fallen to the stop loss."""
        fresh = self._fresher(self._chain_prices(chain, {p["pair"]: p["token"]}).get(p["pair"]), p["price_usd"])
        if not fresh or fresh == p["price_usd"]:
            return p, None
        p = dict(p, price_usd=fresh, price_dex=p["price_usd"])
        moved = (fresh / p["price_dex"] - 1) * 100
        if moved <= float(self.cfg["exits"]["stop_loss_pct"]):
            return p, f"price {moved:+.0f}% on the chain since DexScreener's figure"
        return p, None

    def _follow(self, chain: str, p: dict[str, Any], decision: str, reasons: list[str], now: float) -> None:
        """Remember a token that is to be judged again: one that was only too new
        (once it reaches the minimum age) or one being watched (in five minutes)."""
        key = (chain, p["token"])
        age = p.get("age_min")
        if decision == "skip" and any("too new" in r for r in reasons):
            wait = max(RESEE_TOO_NEW, (float(self.cfg["filters"]["min_age_minutes"]) - (age or 0.0)) * 60.0)
        elif decision == "watch":
            wait = RESEE_WATCH
        else:
            self._followed.pop(key, None)
            return
        self._followed[key] = {"source": p.get("source"), "ready_at": now + wait,
                               "born": now - age * 60.0 if age is not None else None}
        if len(self._followed) > FOLLOW_MAX:
            del self._followed[min(self._followed, key=lambda k: self._followed[k]["ready_at"])]

    def _restore_followed(self) -> None:
        """A restart forgets the follow-ups while the feeds have moved on: pick them up
        again from the recorded verdicts, replayed in order so the latest one counts."""
        try:
            rows = self.store.verdicts_since(self.clock() - FOLLOW_RESTORE_S)
        except Exception as error:  # noqa: BLE001 - without them the bot still runs, it only sees less
            self.store.log("error", f"Wiedervorlage nicht geladen: {type(error).__name__}: {error}")
            return
        for r in rows:
            snap = r["snapshot"] if isinstance(r["snapshot"], dict) else {}
            p = {"token": r["token"], "source": snap.get("source"), "age_min": snap.get("age_min")}
            self._follow(r["chain"], p, r["decision"], r["reasons"], r["seen_at"])

    def _bring_back(self, found: dict[str, dict[str, Any]], now: float) -> None:
        """The launch feeds (GeckoTerminal, pump.fun) list only the last few dozen
        tokens: by the time one is old enough to buy, or due for another look while
        watched, they have moved on and it would never be judged again. So the
        engine asks DexScreener for it itself."""
        for (chain, token), info in list(self._followed.items()):
            if chain not in found or now > info["ready_at"] + FOLLOW_GRACE_S:
                del self._followed[(chain, token)]
            elif (now >= info["ready_at"] and token not in found[chain]
                  and now - self._bad_tokens.get(token, -1e18) >= RESEE_SECONDS):   # broke: its half hour first
                # no feed numbers: they would be minutes old; the age is all that still holds
                snap = {"age_min": (now - info["born"]) / 60.0} if info["born"] is not None else None
                found[chain][token] = {"source": info["source"], "snapshot": snap}

    def _due(self, chain: str, token: str, now: float) -> bool:
        last = self.store.last_verdict(chain, token)
        return last is None or now - last["seen_at"] >= resee_after(last)

    def _poll(self, now: float) -> dict[str, int]:
        counts = {"seen": 0, "new": 0, "buy": 0, "watch": 0, "skip": 0, "exits": 0, "deferred": 0}

        # exits first: a slow discovery must never delay a stop loss
        listed_positions = self.store.open_positions()
        priced = self._position_prices(listed_positions)   # network: outside the lock
        dex_answered = bool(priced) or self._dex_answered
        for listed in listed_positions:
            price = priced.get(listed["id"])
            if not price:
                self._maybe_write_off(listed, now, dex_answered, counts)
                continue
            self._last_priced[listed["id"]] = now
            self._apply_price(listed["id"], price, now, counts, tick=True)

        try:
            self._discover(now, counts)
            if self._last_discovery_error:
                self.store.log("info", "Suche nach neuen Tokens läuft wieder")
                self._last_discovery_error = ""
            self._dex_answered = self._dex_answered_now
            if counts["deferred"] and not self._deferred_last:
                self.store.log("info", f"Viele neue Tokens: {counts['deferred']} auf den nächsten Poll verschoben "
                                       f"(Zeitbudget {DISCOVERY_BUDGET_S:.0f} s, Exits laufen trotzdem jede Runde)")
            self._deferred_last = counts["deferred"]
        except Exception as error:  # noqa: BLE001 - discovery trouble must never stop the poll
            self.errors += 1
            self._dex_answered = False                     # an outage: never a reason to write positions off
            msg = f"{type(error).__name__}: {error}"
            if msg != self._last_discovery_error:          # log a lasting outage once, not every poll
                self.store.log("error", f"Suche nach neuen Tokens abgebrochen (Exits laufen weiter): {msg}")
                self._last_discovery_error = msg

        try:
            self.tracker.fill_due(now)
        except Exception as error:  # noqa: BLE001
            self.store.log("error", f"Tracker: {type(error).__name__}: {error}")
        self.last_poll = now
        self.last_poll_wall = time.time()
        self.poll_count += 1
        return counts

    def _apply_price(self, pid: int, price: float, now: float, counts: dict[str, int], tick: bool) -> None:
        """One price for one holding: its stops, ladder and time stop."""
        with self._lock:
            # re-read: a manual close or partial sell may have happened while we waited
            pos = self.store.position(pid)
            if pos is None or pos["status"] != "open":
                return
            price = self._payout(pos, price)
            good = self._believable(pos, price)
            if good is None:
                # stops and the time stop keep working on the last believable price
                self.paper.update(pos, self._reference_price(pos), now)
            elif self._liquidity_pulled(pos, good):
                self.last_prices[pos["pair"]] = good
                self.paper.exit_all(pos, good, "liquidity_pull", now)
                self.store.tick(pos["id"], now, good)
                self.store.log("warn", f"{pos.get('symbol')}: Liquidität wird abgezogen – sofort verkauft")
            else:
                self.last_prices[pos["pair"]] = good
                before = pos["remaining_frac"]
                self.paper.update(pos, good, now)
                # the entry already wrote this poll's tick; between polls only a sale leaves one
                if pos["opened_at"] < now and (tick or pos["remaining_frac"] < before):
                    self.store.tick(pos["id"], now, good)
            if pos["status"] != "open":
                counts["exits"] += 1
                self._last_priced.pop(pos["id"], None)
                self._good_price.pop(pos["id"], None)
                self._refused.pop(pos["id"], None)
                self._liq_peak.pop(pos["id"], None)

    def _depth(self, pair: str) -> Optional[float]:
        """USD on the paying side of this pool, read this second on the chain, else at the
        last DexScreener answer; None when neither knows it."""
        for source in (self.curves, self.dex):
            depth = (getattr(source, "depth", None) or {}).get(pair)
            if depth is not None:
                return float(depth)
        return None

    def _payout(self, pos: dict[str, Any], price: float) -> float:
        """What selling the rest of this holding at `price` really gets from its pool (see
        dexscreener.payout_price): an emptied pool's dust price is no gain, it is a total loss."""
        depth = self._depth(pos["pair"])
        if depth is None or not pos.get("entry_price"):
            return price
        value = pos["remaining_frac"] * pos["size_usd"] / pos["entry_price"] * price
        return payout_price(price, depth, value)

    def _liquidity_pulled(self, pos: dict[str, Any], price: float) -> bool:
        """Read on the chain this poll: has the pool lost a quarter of its SOL since its
        high while the price held? (See LIQ_PULL.) Pools the chain cannot read: never."""
        reserve = (getattr(self.curves, "reserves", None) or {}).get(pos["pair"])
        if not reserve:
            return False
        peak = self._liq_peak.get(pos["id"])
        if peak is None or reserve > peak[0]:
            self._liq_peak[pos["id"]] = (reserve, price)
            return False
        return reserve <= peak[0] * (1 - LIQ_PULL) and price >= peak[1] * (1 - LIQ_PULL_PRICE)

    def _watch_exits(self, now: float) -> int:
        """Between polls: each holding's price on the chain every few seconds, so a
        stop loss fires within seconds of the fall, not at the next poll. Holdings
        the chain cannot price wait for the poll as before."""
        held = [p for p in self.store.open_positions() if p["chain"] == "solana"]
        fresh = self._chain_prices("solana", {p["pair"]: p["token"] for p in held}) if held else {}
        counts = {"exits": 0}
        for pos in held:
            if fresh.get(pos["pair"]):
                self._last_priced[pos["id"]] = now
                self._apply_price(pos["id"], fresh[pos["pair"]], now, counts, tick=False)
        return counts["exits"]

    def _position_prices(self, positions: list[dict[str, Any]]) -> dict[int, float]:
        """Current price per open position: one batch request per chain when the
        source supports it, single lookups otherwise."""
        priced: dict[int, float] = {}
        by_chain: dict[str, list[dict[str, Any]]] = {}
        for pos in positions:
            by_chain.setdefault(pos["chain"], []).append(pos)
        for chain, group in by_chain.items():
            batch = getattr(self.dex, "prices", None)
            if batch is not None:
                try:
                    got = batch(chain, list({p["pair"] for p in group}), {p["pair"]: p["token"] for p in group}) or {}
                except Exception as error:  # noqa: BLE001
                    self.store.log("error", f"Kurse ({chain}): {type(error).__name__}: {error}")
                    got = {}
                fresh = self._chain_prices(chain, {p["pair"]: p["token"] for p in group})
                for pos in group:
                    best = self._fresher(fresh.get(pos["pair"]), got.get(pos["pair"]))
                    if best:
                        priced[pos["id"]] = best
                continue
            for pos in group:
                try:
                    price = self.dex.price(chain, pos["pair"])
                except Exception as error:  # noqa: BLE001 - one position without a price must not stop the others
                    self.store.log("error", f"Kein Kurs für {pos.get('symbol')}: {type(error).__name__}: {error}")
                    price = None
                if price:
                    priced[pos["id"]] = price
        return priced

    def _manual_price(self, pos: dict[str, Any]) -> Optional[float]:
        """Price for a manual sell: the current one if believable, else the last believable one."""
        now = self._price_now(pos["chain"], pos["pair"], pos["token"])
        if now:
            good = self._believable(pos, self._payout(pos, now))
            return good if good is not None else self._reference_price(pos)
        return self.last_prices.get(pos["pair"])

    def _reference_price(self, pos: dict[str, Any]) -> float:
        """The position's last believable price: from this run, else its last tick, else the entry."""
        if pos["id"] in self._good_price:
            return self._good_price[pos["id"]]
        last = self.store.ticks_for(pos["id"], limit=1)
        return float(last[-1]["price"]) if last else float(pos["entry_price"])

    def _believable(self, pos: dict[str, Any], price: float) -> Optional[float]:
        """`price`, unless it jumps more than PRICE_JUMP_MAX-fold above the last believable
        one - then None, logged once per bad quote. A fall is always believed: a rug
        drops a price 100-fold in a moment, and a stop loss must see it."""
        ref = self._reference_price(pos)
        if ref > 0 and price > ref * PRICE_JUMP_MAX:
            if self._refused.get(pos["id"]) != price:
                self._refused[pos["id"]] = price
                self.store.log("warn", f"Kurs für {pos.get('symbol')} verworfen: {price:.6g} ist das "
                                       f"{price / ref:,.0f}-Fache des letzten ({ref:.6g}) – so springt kein echter Markt; "
                                       f"Stops und Zeitstopp rechnen mit dem letzten glaubwürdigen Kurs")
            return None
        self._good_price[pos["id"]] = price
        self._refused.pop(pos["id"], None)
        return price

    def _rpc_status(self) -> dict[str, Any]:
        """Which Solana node the chain readers use - its host only, never the key in its URL."""
        from urllib.parse import urlparse
        urls = getattr(self.curves, "urls", None) or []
        from .sources.solana_rpc import DEFAULT_RPC
        return {"host": urlparse(urls[0]).hostname if urls else None,
                "own": bool(urls) and urls[0] != DEFAULT_RPC and urlparse(urls[0]).hostname != "solana-rpc.publicnode.com"}

    def set_rpc(self, url: str) -> dict[str, Any]:
        """Your own Solana node: stored in the Keychain (it carries an API key) and used at once."""
        from urllib.parse import urlparse
        from . import keychain
        from .sources.solana_rpc import RPC_KEYCHAIN, rpc_urls
        url = (url or "").strip()
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname:
            return {"ok": False, "error": "Bitte die vollständige https-Adresse des Knotens, z. B. https://mainnet.helius-rpc.com/?api-key=…"}
        error = keychain.put(RPC_KEYCHAIN, url)
        if error:
            return {"ok": False, "error": error + " Sonst SOLANA_RPC_URL in der Umgebung setzen."}
        for reader in (self.curves, getattr(self.rug, "onchain", None)):
            if reader is not None and hasattr(reader, "urls"):
                reader.urls[:] = rpc_urls()
        self.store.log("info", f"dashboard: eigener Solana-Knoten gespeichert ({parsed.hostname})")
        return {"ok": True, "solana_rpc": self._rpc_status()}

    def _chain_prices(self, chain: str, pairs: dict[str, str]) -> dict[str, float]:
        """{pair: price this second} for the pools the chain reader can read (PumpSwap)."""
        read = getattr(self.curves, "pool_prices", None)
        if read is None or chain != "solana" or not pairs:
            return {}
        try:
            return read(pairs, getattr(self.dex, "quote_usd", None) or {}) or {}
        except Exception:  # noqa: BLE001 - DexScreener's price stands in
            return {}

    @staticmethod
    def _fresher(chain_price: Optional[float], dex_price: Optional[float]) -> Optional[float]:
        if chain_price and chain_price > 0 and (not dex_price or chain_price <= dex_price * CHAIN_MAX_ABOVE):
            return float(chain_price)
        return float(dex_price) if dex_price else None

    def _price_now(self, chain: str, pair: str, token: str) -> Optional[float]:
        """Current price for a manual action, following the token to its new
        pool like the polls do (a graduated curve is gone or frozen)."""
        fresh = self._chain_prices(chain, {pair: token}).get(pair)
        batch = getattr(self.dex, "prices", None)
        try:
            listed = (batch(chain, [pair], {pair: token}) or {}).get(pair) if batch is not None else self.dex.price(chain, pair)
        except Exception:  # noqa: BLE001 - the caller falls back to the last known price
            listed = None
        return self._fresher(fresh, listed)

    def _maybe_write_off(self, listed: dict[str, Any], now: float, dex_answered: bool, counts: dict[str, int]) -> None:
        """A pair that stopped being priced while DexScreener answers for others has
        most likely been pulled (a rug). Past its time stop and after
        NO_PRICE_WRITE_OFF_MIN minutes without a price, the rest is written off at 0:
        a token that cannot be priced cannot be sold either."""
        last = self._last_priced.get(listed["id"], listed["opened_at"])
        overdue = now - listed["opened_at"] >= float(self.cfg["exits"]["time_stop_minutes"]) * 60
        if not (dex_answered and overdue and now - last >= NO_PRICE_WRITE_OFF_MIN * 60):
            return
        with self._lock:
            pos = self.store.position(listed["id"])
            if pos is None or pos["status"] != "open":
                return
            self.store.log("warn", f"{pos.get('symbol')}: seit {(now - last) / 60:.0f} min kein Kurs (Paar verschwunden?) "
                                   f"– Rest als Verlust abgeschrieben")
            self.paper._sell(pos, pos["remaining_frac"], 0.0, "no_price", now)
            self._last_priced.pop(listed["id"], None)
            counts["exits"] += 1

    # --- loop -----------------------------------------------------------
    def run(self) -> None:
        interval = float(self.cfg["poll_seconds"])
        self.store.log("info", f"engine started, mode={self.cfg['mode']}, every {interval:.0f}s")
        self.store.prune_ticks(self.clock() - TICK_KEEP_DAYS * 86400)
        self.store.prune_paths(self.clock() - PATH_KEEP_DAYS * 86400)
        dropped = self.store.prune_history(self.clock() - HISTORY_KEEP_DAYS * 86400)
        if dropped["candidates"]:
            self.store.log("info", f"Verlauf aufgeräumt: {dropped['candidates']} Kandidaten älter als {HISTORY_KEEP_DAYS} Tage")
        while not self._stop.is_set():
            started = time.time()
            try:
                c = self.poll_once()
                if c["new"] or c["exits"]:
                    self.store.log("poll", f"seen {c['seen']}, new {c['new']}: "
                                           f"buy {c['buy']} watch {c['watch']} skip {c['skip']}, "
                                           f"exits {c['exits']}")
            except Exception as error:  # noqa: BLE001 - keep the loop alive
                self.errors += 1
                self.store.log("error", f"{type(error).__name__}: {error}")
            interval = float(self.cfg["poll_seconds"])
            deadline = started + max(1.0, interval)
            while not self._stop.is_set():
                left = deadline - time.time()
                if left <= 0 or self._wake.wait(min(left, EXIT_WATCH_S)):
                    break
                if getattr(self.curves, "pool_prices", None) is None:
                    continue
                try:
                    if self._watch_exits(self.clock()):
                        self.store.log("poll", "exits zwischen den Polls (Kurs von der Chain)")
                except Exception as error:  # noqa: BLE001 - the next poll prices the holdings anyway
                    if f"{error}" != self._watch_error:          # once, not every two seconds
                        self.store.log("error", f"Exit-Wache: {type(error).__name__}: {error}")
                    self._watch_error = f"{error}"
            self._wake.clear()
        self.store.log("info", "engine stopped")

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()

    # --- controls (called from the dashboard thread) --------------------
    def poll_now(self) -> None:
        self._wake.set()

    def set_paused(self, paused: bool) -> None:
        self.paused = bool(paused)
        self.store.log("info", "dashboard: " + ("pausiert" if paused else "fortgesetzt"))

    def apply_config(self, patch: dict[str, Any]) -> dict[str, Any]:
        """Validate, apply live, persist. Returns {'ok', 'errors', 'config'}."""
        clean, errors = settings.validate(patch)
        if not errors:
            cross = settings.apply(self.cfg, clean)
            if cross:
                errors.update(cross)
        if errors:
            return {"ok": False, "errors": errors, "config": settings.flat(self.cfg)}
        if clean:
            if self.persist:
                try:
                    self.persist(clean)
                except OSError as error:
                    self.store.log("error", f"config not saved: {error}")
            self.store.log("info", "dashboard: " + ", ".join(f"{k}={v}" for k, v in clean.items()))
            self._wake.set()
        return {"ok": True, "errors": {}, "config": settings.flat(self.cfg)}

    def close_position(self, pid: int) -> dict[str, Any]:
        with self._lock:
            pos = self.store.position(pid)
            if pos is None or pos["status"] != "open":
                return {"ok": False, "error": "Position ist nicht offen"}
            price = self._manual_price(pos)
            if not price:
                return {"ok": False, "error": "Kein Kurs verfügbar"}
            self.paper.close_manually(pos, price, self.clock())
            self.last_prices[pos["pair"]] = price
            self.store.tick(pid, self.clock(), price)
            self.invalidate_reports()
            return {"ok": True, "position": self.store.position(pid)}

    def sell_position(self, pid: int, frac: Any) -> dict[str, Any]:
        """Partial manual exit: frac is the share of the original size, 0 < frac <= remaining."""
        try:
            frac = float(str(frac).replace(",", "."))
        except (TypeError, ValueError):
            return {"ok": False, "error": "Anteil ist keine Zahl"}
        if not 0 < frac <= 1:
            return {"ok": False, "error": "Anteil muss zwischen 0 und 1 liegen"}
        with self._lock:
            pos = self.store.position(pid)
            if pos is None or pos["status"] != "open":
                return {"ok": False, "error": "Position ist nicht offen"}
            if frac > pos["remaining_frac"] + 1e-9:
                return {"ok": False, "error": f"Nur noch {pos['remaining_frac'] * 100:.0f}% der Position offen"}
            price = self._manual_price(pos)
            if not price:
                return {"ok": False, "error": "Kein Kurs verfügbar"}
            if abs(frac - pos["remaining_frac"]) < 1e-9:
                self.paper.close_manually(pos, price, self.clock())
            else:
                self.paper.sell_part(pos, frac, price, self.clock())
            self.last_prices[pos["pair"]] = price
            self.store.tick(pid, self.clock(), price)
            self.invalidate_reports()
            return {"ok": True, "position": self.store.position(pid)}

    def reset(self, what: str, bankroll: Optional[float] = None) -> dict[str, Any]:
        if what not in ("positions", "all"):
            return {"ok": False, "error": "what muss 'positions' oder 'all' sein"}
        if bankroll is not None:
            try:
                bankroll = float(str(bankroll).replace(",", "."))
            except ValueError:
                return {"ok": False, "error": "Startkapital ist keine Zahl"}
            if not 10 <= bankroll <= 1e9:
                return {"ok": False, "error": "Startkapital muss zwischen 10 und 1.000.000.000 liegen"}
        with self._lock:
            self.store.reset(what)
            self.last_prices.clear()
            self.invalidate_reports()
            if bankroll is not None:
                self.cfg["bankroll_usd"] = bankroll
                self.paper.initial = bankroll
                if self.persist:
                    try:
                        self.persist({"bankroll_usd": bankroll})
                    except OSError as error:
                        self.store.log("error", f"config not saved: {error}")
            self.store.log("info", "dashboard: reset " + what + (f", Startkapital ${bankroll:,.2f}" if bankroll is not None else ""))
        return {"ok": True, "initial": self.paper.initial}

    def open_from_candidate(self, cid: int) -> dict[str, Any]:
        """Manual paper entry on a token the bot evaluated. The tracker keeps the
        original decision, so manual picks can be compared against the rules."""
        with self._lock:
            c = self.store.candidate(cid)
            if c is None:
                return {"ok": False, "error": "Kandidat nicht gefunden"}
            blocked = self.paper.can_open(c["chain"], c["token"])
            if blocked:
                return {"ok": False, "error": "Nicht eröffnet: " + blocked}
            price = self._price_now(c["chain"], c["pair"], c["token"])
            if not price:
                return {"ok": False, "error": "Kein aktueller Kurs bei DexScreener (ganz neu und noch nicht gelistet, "
                                              "oder das Paar ist weg) – ohne laufenden Kurs gäbe es keinen Stop-Loss"}
            p = {"chain": c["chain"], "token": c["token"], "pair": c["pair"], "symbol": c["symbol"], "price_usd": price}
            pid = self.paper.open(p, self.clock())
            self.last_prices[c["pair"]] = price
            self.store.tick(pid, self.clock(), price)
            self.store.log("trade", f"MANUAL BUY {c['symbol']} via Dashboard (Bot-Urteil: {c['decision']})")
            self._wake.set()
            return {"ok": True, "position": self.store.position(pid)}

    # --- named parameter profiles --------------------------------------
    def profiles(self) -> dict[str, dict[str, Any]]:
        """Built-in presets (★, read-only, only the filter block) first, then the user's own."""
        own = self.store.get("profiles", {}) or {}
        # earlier versions stored the presets along with the user's own: the shipped ones win;
        # a stored profile the validation now refuses (NaN from an older version) is left out
        return {**presets(), **{k: v for k, v in own.items() if k not in presets() and not settings.validate(v)[1]}}

    def save_profile(self, name: str, flat: Optional[dict[str, Any]] = None) -> dict[str, Any]:
        name = (name or "").strip()
        if not name or len(name) > 40:
            return {"ok": False, "error": "Name fehlt oder ist länger als 40 Zeichen"}
        if name in presets() or name.startswith("★"):
            return {"ok": False, "error": "★ ist den Voreinstellungen vorbehalten – anderen Namen wählen"}
        flat = flat if flat is not None else settings.flat(self.cfg)
        clean, errors = settings.validate(flat)
        if errors:
            return {"ok": False, "error": "Profil enthält ungültige Werte: " + ", ".join(errors)}
        own = {k: v for k, v in (self.store.get("profiles", {}) or {}).items() if k not in presets()}
        own[name] = clean
        self.store.set("profiles", own)                   # only the user's own: a new release's presets reach them
        self.store.log("info", f"dashboard: Profil „{name}“ gespeichert")
        return {"ok": True, "profiles": self.profiles()}

    def apply_profile(self, name: str) -> dict[str, Any]:
        profile = self.profiles().get(name)
        if profile is None:
            return {"ok": False, "error": "Profil nicht gefunden"}
        result = self.apply_config(profile)
        if result["ok"]:
            self.store.log("info", f"dashboard: Profil „{name}“ geladen")
        return result

    def delete_profile(self, name: str) -> dict[str, Any]:
        if name in presets():
            return {"ok": False, "error": "Voreinstellungen (★) lassen sich nicht löschen"}
        own = self.store.get("profiles", {}) or {}
        if name not in own:
            return {"ok": False, "error": "Profil nicht gefunden"}
        del own[name]
        self.store.set("profiles", own)
        return {"ok": True, "profiles": self.profiles()}

    def sweep(self, horizon_min: int = 15) -> dict[str, Any]:
        from . import sweep as _sweep
        horizons = [int(h) for h in self.cfg["tracker"]["horizons_minutes"]]
        if horizon_min not in horizons:
            horizon_min = horizons[min(1, len(horizons) - 1)]
        result = _sweep.run(self.store.sweep_samples(horizon_min), self.cfg)
        result["horizon_min"] = horizon_min
        result["horizons"] = horizons
        return result

    def _build(self) -> str:
        """The installed commit (get.sh writes it), shortened; "" for a clone or the demo."""
        from pathlib import Path as _P
        from . import updater
        return updater.installed_version(_P(__file__).resolve().parent.parent)[:7]

    def _can_update(self) -> bool:
        from pathlib import Path as _P
        from . import updater
        return updater.available(_P(__file__).resolve().parent.parent)

    def doctor(self) -> dict[str, Any]:
        """Self-test against this engine's own sources (fakes in the demo)."""
        from . import doctor as _doctor
        checks = _doctor.run_checks(self.cfg, self.dex, self.discovery.feeds, self.rug, self.home, self.curves)
        bad = [c["name"] for c in checks if not c["ok"]]
        self.store.log("warn" if bad else "info", "dashboard: Selbsttest " + ("ohne Befund" if not bad else "– Fehler: " + ", ".join(bad)))
        return {"ok": not bad, "checks": checks, "at": time.time()}

    def candidate_detail(self, cid: int) -> dict[str, Any]:
        c = self.store.candidate(cid)
        if c is None:
            return {"ok": False, "error": "Kandidat nicht gefunden"}
        held = self.store.has_open_for(c["chain"], c["token"])
        return {"ok": True, "candidate": c, "outcomes": self.store.outcomes_for(cid), "held": held,
                "price": self.last_prices.get(c["pair"]), "now": self.clock()}

    def position_detail(self, pid: int) -> dict[str, Any]:
        pos = self.store.position(pid)
        if pos is None:
            return {"ok": False, "error": "Position nicht gefunden"}
        return {"ok": True, "position": pos, "trades": self.store.trades_for(pid),
                "ticks": self.store.ticks_for(pid), "price": self.last_prices.get(pos["pair"]),
                "exits": self.cfg["exits"]}

    # --- state for the dashboard ---------------------------------------
    def state(self) -> dict[str, Any]:
        now = self.clock()
        open_positions = []
        unrealized_total = 0.0
        for pos in self.store.open_positions():
            price = self.last_prices.get(pos["pair"])
            unreal = self.paper.unrealized(pos, price)
            unrealized_total += unreal
            open_positions.append({
                **pos, "price": price, "unrealized": round(unreal, 2),
                "gain_pct": round((price / pos["entry_price"] - 1) * 100, 1) if price else None,
                "age_min": round((now - pos["opened_at"]) / 60, 1),
                "rungs_done": sorted(self.paper.rungs_done(pos)),
            })
        return {
            "app": APP_ID, "can_update": self._can_update(), "mode": self.cfg["mode"], "demo": self.demo, "paused": self.paused, "now": now,
            "started_at": self.started_at, "poll_seconds": self.cfg["poll_seconds"],
            "wall_now": time.time(), "last_poll_wall": self.last_poll_wall,
            "chains": self.cfg["chains"],
            "last_poll": self.last_poll, "polls": self.poll_count, "errors": self.errors,
            "poll_ms_last": self.poll_ms_last, "poll_ms_avg": self.poll_ms_avg,
            "initial": self.paper.initial, "bankroll": round(self.paper.bankroll(), 2),
            "cash": round(self.paper.cash(), 2), "exposure": round(self.paper.exposure(), 2),
            "unrealized": round(unrealized_total, 2), "daily_pnl": round(self.paper.daily_pnl(), 2),
            "daily_limit_hit": self.paper.daily_limit_hit(),
            "stats": self.store.stats(), "open_positions": open_positions,
            "closed": self.store.closed_positions(50), "candidates": self.store.candidates(80),
            "edge": self._report("edge", self.store.edge_report), "events": self.store.events(60),
            "edge_rules": self._report("edge_rules", lambda: self.store.edge_report("rule_decision")),
            "edge_ai": self._report("edge_ai", lambda: self.store.edge_report("ai_decision")),
            "edge_source": self._report("edge_source", lambda: self.store.edge_report("source")),
            "version": VERSION,
            "build": self._build(),
            "ai": self.advisor.status(),
            "sources": self.discovery.status(),
            "exits_by_reason": self._report("exits", self.store.exit_breakdown),
            "skip_reasons": self._report("why", self.store.skip_reasons),
            "rugcheck": self.rug.health() if hasattr(self.rug, "health") else {"calls": 0, "fails": 0, "last_error": "", "ok": None},
            "curves": self.curves.health() if hasattr(self.curves, "health") else None,
            "solana_rpc": self._rpc_status(),
            "equity": self.store.equity_curve(),
            "config": settings.flat(self.cfg),
        }
