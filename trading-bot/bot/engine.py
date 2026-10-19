"""The polling loop: discover -> evaluate -> record -> (paper) trade -> manage exits."""
from __future__ import annotations

import threading
import time
from typing import Any, Callable, Optional

from . import settings
from .ai import ClaudeAdvisor
from .discovery import DexScreenerFeed, Discovery
from .paper import Paper
from .store import Store
from .strategy import evaluate
from .tracker import Tracker

RESEE_SECONDS = 30 * 60      # a hard skip (rug danger, too old, parabolic) is not re-evaluated within half an hour
RESEE_TOO_NEW = 2 * 60       # "too new" is a timing issue, not a verdict: look again in two minutes
RESEE_WATCH = 5 * 60         # a watch passed every filter; its numbers move fast, so re-check every five minutes


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
REPORT_TTL = 10.0            # seconds: edge reports and breakdowns are recomputed at most this often       # price ticks of positions closed longer ago are dropped at start


class Engine:
    def __init__(self, cfg: dict[str, Any], store: Store, dex: Any, rug: Any,
                 clock: Callable[[], float] = time.time, advisor: Any = None,
                 feeds: Optional[dict[str, Any]] = None) -> None:
        self.cfg = cfg
        self.store = store
        self.dex = dex
        self.rug = rug
        self.clock = clock
        self.discovery = Discovery(cfg, feeds if feeds is not None else {"dexscreener": DexScreenerFeed(dex)}, log=store.log)
        self.advisor = advisor or ClaudeAdvisor(cfg, log=store.log)
        self.paper = Paper(store, cfg)
        self.tracker = Tracker(store, cfg, dex.price)
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
        found = self.discovery.recent(list(self.cfg["chains"]))
        for chain, tokens in found.items():
            if not tokens:
                continue
            pairs = self.dex.pairs_for_tokens(chain, list(tokens))
            indexed = {p["token"] for p in pairs}
            for token, info in tokens.items():
                snap = info.get("snapshot")
                if token not in indexed and snap and snap.get("pair") and snap.get("price_usd"):
                    pairs.append(dict(snap, via_feed=True))   # not on DexScreener yet: judge the feed's own numbers (needs a price)
            for p in pairs:                                    # DexScreener sometimes lacks the listing time; the feed knows it
                snap = (tokens.get(p["token"]) or {}).get("snapshot")
                if p.get("age_min") is None and snap and snap.get("age_min") is not None:
                    p["age_min"] = snap["age_min"]
                    p["age_from_feed"] = True
            for p in pairs:
                if now - self._bad_tokens.get(p.get("token") or "", -1e18) < RESEE_SECONDS:
                    continue                                   # broke last time: give its record half an hour
                try:
                    p["source"] = (tokens.get(p["token"]) or {}).get("source")
                    counts["seen"] += 1
                    last = self.store.last_verdict(chain, p["token"])
                    if last is not None and now - last["seen_at"] < resee_after(last):
                        continue
                    counts["new"] += 1
                    rug = self.rug.summary(p["token"]) if chain == "solana" else None
                    verdict = evaluate(p, rug, self.cfg)
                    decision = verdict["decision"]
                    p["rule_decision"] = decision
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
                        # check and open in one step under the dashboard's lock, or a manual
                        # "Kaufen" in between could open the same token a second time
                        with self._lock:
                            blocked = self.paper.can_open(chain, p["token"])
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
                except Exception as error:  # noqa: BLE001 - one broken record must not stop the others
                    self.errors += 1
                    self._bad_tokens[p.get("token") or ""] = now
                    self.store.log("error", f"Token {p.get('symbol') or p.get('token')} übersprungen (30 min): "
                                            f"{type(error).__name__}: {error}")


    def _poll(self, now: float) -> dict[str, int]:
        counts = {"seen": 0, "new": 0, "buy": 0, "watch": 0, "skip": 0, "exits": 0}

        try:
            self._discover(now, counts)
            if self._last_discovery_error:
                self.store.log("info", "Suche nach neuen Tokens läuft wieder")
                self._last_discovery_error = ""
        except Exception as error:  # noqa: BLE001 - discovery trouble must never suspend the exits below
            self.errors += 1
            msg = f"{type(error).__name__}: {error}"
            if msg != self._last_discovery_error:          # log a lasting outage once, not every poll
                self.store.log("error", f"Suche nach neuen Tokens abgebrochen (Exits laufen weiter): {msg}")
                self._last_discovery_error = msg

        for listed in self.store.open_positions():
            try:
                price = self.dex.price(listed["chain"], listed["pair"])   # network: outside the lock
            except Exception as error:  # noqa: BLE001 - one position without a price must not stop the others
                self.store.log("error", f"Kein Kurs für {listed.get('symbol')}: {type(error).__name__}: {error}")
                continue
            if not price:
                continue
            with self._lock:
                # re-read: a manual close or partial sell may have happened while we waited
                pos = self.store.position(listed["id"])
                if pos is None or pos["status"] != "open":
                    continue
                self.last_prices[pos["pair"]] = price
                self.paper.update(pos, price, now)
                if pos["opened_at"] < now:             # the entry already wrote this poll's tick
                    self.store.tick(pos["id"], now, price)
                if pos["status"] != "open":
                    counts["exits"] += 1

        try:
            self.tracker.fill_due(now)
        except Exception as error:  # noqa: BLE001
            self.store.log("error", f"Tracker: {type(error).__name__}: {error}")
        self.last_poll = now
        self.last_poll_wall = time.time()
        self.poll_count += 1
        return counts

    # --- loop -----------------------------------------------------------
    def run(self) -> None:
        interval = float(self.cfg["poll_seconds"])
        self.store.log("info", f"engine started, mode={self.cfg['mode']}, every {interval:.0f}s")
        self.store.prune_ticks(self.clock() - TICK_KEEP_DAYS * 86400)
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
            self._wake.wait(max(1.0, interval - (time.time() - started)))
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
            price = self.dex.price(pos["chain"], pos["pair"]) or self.last_prices.get(pos["pair"])
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
            price = self.dex.price(pos["chain"], pos["pair"]) or self.last_prices.get(pos["pair"])
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
            fresh = self.dex.pair(c["chain"], c["pair"])
            price = fresh["price_usd"] if fresh and fresh["price_usd"] > 0 else None
            if not price:
                return {"ok": False, "error": "Kein aktueller Kurs für diesen Token"}
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
        return {**presets(), **(self.store.get("profiles", {}) or {})}

    def save_profile(self, name: str, flat: Optional[dict[str, Any]] = None) -> dict[str, Any]:
        name = (name or "").strip()
        if not name or len(name) > 40:
            return {"ok": False, "error": "Name fehlt oder ist länger als 40 Zeichen"}
        if name in presets():
            return {"ok": False, "error": "Voreinstellungen (★) können nicht überschrieben werden – anderen Namen wählen"}
        flat = flat if flat is not None else settings.flat(self.cfg)
        clean, errors = settings.validate(flat)
        if errors:
            return {"ok": False, "error": "Profil enthält ungültige Werte: " + ", ".join(errors)}
        profiles = self.profiles()
        profiles[name] = clean
        self.store.set("profiles", profiles)
        self.store.log("info", f"dashboard: Profil „{name}“ gespeichert")
        return {"ok": True, "profiles": profiles}

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

    def _can_update(self) -> bool:
        from pathlib import Path as _P
        from . import updater
        return updater.available(_P(__file__).resolve().parent.parent)

    def doctor(self) -> dict[str, Any]:
        """Self-test against this engine's own sources (fakes in the demo)."""
        from . import doctor as _doctor
        checks = _doctor.run_checks(self.cfg, self.dex, self.discovery.feeds, self.rug, self.home)
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
            "ai": self.advisor.status(),
            "sources": self.discovery.status(),
            "exits_by_reason": self._report("exits", self.store.exit_breakdown),
            "skip_reasons": self._report("why", self.store.skip_reasons),
            "rugcheck": self.rug.health() if hasattr(self.rug, "health") else {"calls": 0, "fails": 0, "last_error": "", "ok": None},
            "equity": self.store.equity_curve(),
            "config": settings.flat(self.cfg),
        }
