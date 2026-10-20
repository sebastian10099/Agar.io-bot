"""Filters and scoring for freshly listed tokens.

Hard filters produce 'skip'. Survivors get a 0-100 score; 'buy' needs
min_score, everything else is 'watch'. Every decision is recorded with its
reasons so the tracker can later tell whether the rules have an edge.
"""
from __future__ import annotations

import math
from typing import Any, Optional


def _clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def _scale(x: float, lo: float, hi: float, pts: float) -> float:
    """Linear 0..pts as x goes lo..hi."""
    if hi <= lo:
        return pts
    return _clamp((x - lo) / (hi - lo), 0.0, 1.0) * pts


# The pool a pump.fun coin moves to after its curve belongs to pump.fun: nobody can pull its
# liquidity, and an "LP unlocked" there is a warning, not a verdict. pump.fun's coins end in
# "pump". Any other pool on PumpSwap (or Meteora) was opened by someone for a coin of their own
# and holds their LP - RugCheck flags 77 of 80 of those, 1 of 10 of pump.fun's own (live,
# 19 Oct 2026). Flagged and bought anyway, 3 of 10 such PumpSwap pools and 3 of 5 on Meteora
# went to zero in one step: the liquidity was pulled, faster than any stop. On PumpSwap the
# loss came from buying late: bought within their first minute, the same pools mostly rose
# (tools/backtest.py tests that idea, fixed in advance, on the data that came after).
LP_MANAGED_DEXES = {"pumpswap"}
PUMPFUN_SUFFIX = "pump"


# A pool pump.fun opens for a coin leaving its curve holds about a fifth of the coin: the coin is
# worth ~4x the pool. Whoever opens a pool for a coin of their own puts most of it in: the pool is
# worth more than the coin. Scammers grind addresses ending in "pump" too (20 Oct 2026: three such
# pools, valued 0.6-0.8x their liquidity, were emptied within five minutes of the buy).
PUMPFUN_MIN_FDV_LIQ = 1.2


def lp_managed(p: dict[str, Any]) -> bool:
    if str(p.get("dex") or "").lower() not in LP_MANAGED_DEXES or not str(p.get("token") or "").endswith(PUMPFUN_SUFFIX):
        return False
    fdv, liq = float(p.get("fdv") or 0), float(p.get("liquidity_usd") or 0)
    return not (fdv > 0 and liq > 0 and fdv / liq < PUMPFUN_MIN_FDV_LIQ)


def own_pumpswap_pool(p: dict[str, Any]) -> bool:
    """A pool someone opened on PumpSwap for a coin of their own (not one of pump.fun's)."""
    return str(p.get("dex") or "").lower() == "pumpswap" and not lp_managed(p)


def evaluate(p: dict[str, Any], rug: Optional[dict[str, Any]], cfg: dict[str, Any]) -> dict[str, Any]:
    f = cfg["filters"]
    reasons: list[str] = []

    # --- hard gates -----------------------------------------------------
    age = p.get("age_min")
    if age is None:
        reasons.append("age unknown")
    elif age < f["min_age_minutes"]:
        # rounded down: 1.47 min must not read "1.5" against a 1.5 minimum
        reasons.append(f"too new ({math.floor(age * 10) / 10:.1f} min < {f['min_age_minutes']:g})")
    elif age > f["max_age_minutes"]:
        reasons.append(f"too old ({age:.0f} min)")

    liq = p["liquidity_usd"]
    if p.get("liquidity_kind") == "graduated":
        reasons.append("curve completed - trading moves to its new pool")
    elif p.get("liquidity_kind") == "unknown" and liq <= 0:
        reasons.append("liquidity unknown (bonding curve without a figure)")
    elif liq < f["min_liquidity_usd"]:
        reasons.append(f"liquidity ${liq:,.0f} < ${f['min_liquidity_usd']:,.0f}")
    elif liq > f["max_liquidity_usd"]:
        reasons.append(f"liquidity ${liq:,.0f} too large for a new token")

    if p["volume_m5"] < f["min_volume_m5_usd"]:
        reasons.append(f"5m volume ${p['volume_m5']:,.0f} < ${f['min_volume_m5_usd']:,.0f}")

    if p["buys_m5"] < f["min_buys_m5"]:
        reasons.append(f"5m buys {p['buys_m5']} < {f['min_buys_m5']}")

    ratio = p["buys_m5"] / max(1, p["sells_m5"])
    if ratio < f["min_buy_sell_ratio_m5"]:
        reasons.append(f"buy/sell {ratio:.2f} < {f['min_buy_sell_ratio_m5']}")

    if p["change_m5"] > f["max_price_change_m5_pct"]:
        reasons.append(f"5m change +{p['change_m5']:.0f}% - too late, parabolic")
    elif p["change_m5"] < f["min_price_change_m5_pct"]:
        reasons.append(f"5m change {p['change_m5']:.0f}% - falling")

    if p["fdv"] and p["fdv"] > f["max_fdv_usd"]:
        reasons.append(f"FDV ${p['fdv']:,.0f} > ${f['max_fdv_usd']:,.0f}")
    # a valuation many times the pool behind it: few sellers empty it (live: 31-40 % of such pools
    # crashed by 80 % within the hour, 13 % of the rest). Curves keep their own liquidity measure.
    cap = float(f.get("max_fdv_liquidity_ratio") or 0)
    on_curve_now = p.get("curve") or p.get("liquidity_kind") == "curve"
    # "Frühkauf" (filters.early_own_pools, a paper test): only pools their creator opened on PumpSwap,
    # bought in their first minutes - bought then, they mostly rose; bought minutes later, they lost
    # (19 Oct 2026). Their creator holds the LP, so its "unlocked" is accepted there - a known risk.
    early = bool(f.get("early_own_pools", False))
    if early and not own_pumpswap_pool(p):
        reasons.append("early mode: only pools their creator opened on PumpSwap")
    lp_soft = lp_managed(p) or (early and own_pumpswap_pool(p))
    if cap > 0 and not on_curve_now and liq > 0 and p["fdv"] and p["fdv"] / liq > cap:
        reasons.append(f"thin pool: valuation {p['fdv'] / liq:.1f}x its liquidity > {cap:g}x")

    if p["price_usd"] <= 0:
        reasons.append("no price")

    watch_only = False
    holders_unknown = False
    lp_unknown = False
    if f["require_rugcheck"] and p.get("chain") == "solana":
        if rug is None:
            if not f["allow_rugcheck_unknown"]:
                # no safety check possible: never buy, but keep scoring and tracking the
                # token so the outage does not also blind the edge report
                watch_only = True
        elif rug.get("source") == "onchain":
            # own on-chain check (RugCheck had no answer): authorities and Token-2022 traps
            if rug["danger"]:
                reasons.append("onchain danger: " + ", ".join(rug["danger"][:3]))
            # it cannot see who holds a pool's liquidity - outside pump.fun's own pools that is the
            # question (live: 80 % of Meteora pools fell 90 % within the hour)
            lp_unknown = not lp_soft and not on_curve_now
        else:
            danger = list(rug["danger"])
            if lp_soft:
                soft = [d for d in danger if "LP Unlocked" in str(d)]
                danger = [d for d in danger if d not in soft]
            if danger:
                reasons.append("rugcheck danger: " + ", ".join(danger[:3]))
            if rug["score"] > f["max_rugcheck_score"]:
                reasons.append(f"rugcheck score {rug['score']:.0f} > {f['max_rugcheck_score']}")
    # two of RugCheck's warnings as hard filters (off by default): in the Frühkauf test 4 of 5 coins
    # whose creator can still change them ("Mutable metadata") and 2 of 3 with one wallet over 10 %
    # were pulled to zero (19 Oct 2026, 32 trades - tested from then on, on new data only)
    if rug is not None:
        top1 = (rug.get("holders") or {}).get("top1")
        cap = float(f.get("max_top_holder_pct", 100) or 100)
        if cap < 100 and top1 is not None and float(top1) > cap:
            reasons.append(f"top holder {float(top1):.0f} % > {cap:g} %")
        if f.get("reject_mutable_metadata") and any("Mutable metadata" in str(w) for w in rug.get("warn") or []):
            reasons.append("mutable metadata: its creator can still change the coin")
    if f.get("require_holder_check", True) and p.get("chain") == "solana":
        # who could dump on the buyers? RugCheck looks at the holders; the own check only when it got
        # the distribution or the creator's share. No answer at all is no answer either.
        known = rug is not None and (rug.get("source") != "onchain" or rug.get("holders") or rug.get("creator"))
        holders_unknown = not known                # never bought, still tracked

    if reasons:
        return {"decision": "skip", "score": 0.0, "reasons": reasons}

    # --- scoring --------------------------------------------------------
    parts: dict[str, float] = {}
    # absolute log band, deliberately independent of the filter floor: moving
    # min_liquidity_usd must not change how a given token scores, or the
    # hindsight sweep would compare apples with oranges
    parts["liquidity"] = _scale(math.log10(max(1.0, liq)), math.log10(20_000), math.log10(500_000), 20)
    vol_ratio = p["volume_m5"] / max(1.0, liq)
    parts["activity"] = _scale(vol_ratio, 0.05, 0.5, 20)
    parts["pressure"] = _scale(ratio, f["min_buy_sell_ratio_m5"], 3.0, 20)
    parts["momentum"] = _scale(p["change_m5"], 3, 40, 15)
    if age is not None:
        parts["age"] = 10.0 if 5 <= age <= 30 else _scale(60 - abs(age - 17.5), 0, 55, 10)
    parts["socials"] = 5.0 if p.get("has_socials") else 0.0
    if rug is not None and rug.get("source") == "onchain":
        # sees less than RugCheck (no holder or LP analysis): at most half of its points
        parts["rugcheck"] = max(0.0, 5.0 - 2.0 * len(rug["warn"]))
    elif rug is not None:
        parts["rugcheck"] = _scale(f["max_rugcheck_score"] - rug["score"], 0, f["max_rugcheck_score"], 10)
        warnings = len(rug["warn"]) + (len(rug["danger"]) if lp_soft else 0)
        if warnings:
            parts["rugcheck"] = max(0.0, parts["rugcheck"] - 2.0 * warnings)
    else:
        parts["rugcheck"] = 5.0

    score = round(sum(parts.values()), 1)
    decision = "buy" if score >= cfg["scoring"]["min_score"] else "watch"
    notes = [f"{k} {v:.0f}" for k, v in parts.items()]
    if p.get("liquidity_kind") == "curve":
        notes.append(f"pump.fun-Kurve: Liquidität ${liq:,.0f} aus den Reserven auf der Chain")
    if decision == "watch":
        notes.insert(0, f"score {score} < {cfg['scoring']['min_score']}")
    on_curve = p.get("curve") or p.get("liquidity_kind") == "curve"
    if watch_only:
        decision = "watch"
        notes.insert(0, "rugcheck unavailable - watch only, no buy without the safety check")
    elif on_curve and not f.get("allow_curve_buys", False):
        # live test, October 2026: tokens still on a bonding curve lost 30 % on average after costs within
        # 15 minutes (12 % up), strong ones too; watched, they are bought once they move into a pool
        watch_only = True
        decision = "watch"
        notes.insert(0, "still on its bonding curve - watch only until it trades in a pool")
    elif holders_unknown:
        watch_only = True
        decision = "watch"
        notes.insert(0, "holder check missing - watch only: neither the holder distribution nor the creator's share is known")
    elif lp_unknown:
        watch_only = True
        decision = "watch"
        notes.insert(0, "LP unknown - watch only: without RugCheck nobody sees who holds this pool's liquidity")
    return {"decision": decision, "score": score, "reasons": notes, "watch_only": watch_only}
