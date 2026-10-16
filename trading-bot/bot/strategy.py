"""Filters and scoring for freshly listed tokens.

Hard filters produce 'skip'. Survivors get a 0-100 score; 'buy' needs
min_score, everything else is 'watch'. Every decision is recorded with its
reasons so the tracker can later tell whether the rules have an edge.
"""
from __future__ import annotations

from typing import Any, Optional


def _clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def _scale(x: float, lo: float, hi: float, pts: float) -> float:
    """Linear 0..pts as x goes lo..hi."""
    if hi <= lo:
        return pts
    return _clamp((x - lo) / (hi - lo), 0.0, 1.0) * pts


def evaluate(p: dict[str, Any], rug: Optional[dict[str, Any]], cfg: dict[str, Any]) -> dict[str, Any]:
    f = cfg["filters"]
    reasons: list[str] = []

    # --- hard gates -----------------------------------------------------
    age = p.get("age_min")
    if age is None:
        reasons.append("age unknown")
    elif age < f["min_age_minutes"]:
        reasons.append(f"too new ({age:.1f} min)")
    elif age > f["max_age_minutes"]:
        reasons.append(f"too old ({age:.0f} min)")

    liq = p["liquidity_usd"]
    if liq < f["min_liquidity_usd"]:
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

    if p["price_usd"] <= 0:
        reasons.append("no price")

    if f["require_rugcheck"] and p.get("chain") == "solana":
        if rug is None:
            if not f["allow_rugcheck_unknown"]:
                reasons.append("rugcheck unavailable")
        else:
            if rug["danger"]:
                reasons.append("rugcheck danger: " + ", ".join(rug["danger"][:3]))
            if rug["score"] > f["max_rugcheck_score"]:
                reasons.append(f"rugcheck score {rug['score']:.0f} > {f['max_rugcheck_score']}")

    if reasons:
        return {"decision": "skip", "score": 0.0, "reasons": reasons}

    # --- scoring --------------------------------------------------------
    parts: dict[str, float] = {}
    parts["liquidity"] = _scale(liq, f["min_liquidity_usd"], f["min_liquidity_usd"] * 10, 20)
    vol_ratio = p["volume_m5"] / max(1.0, liq)
    parts["activity"] = _scale(vol_ratio, 0.05, 0.5, 20)
    parts["pressure"] = _scale(ratio, f["min_buy_sell_ratio_m5"], 3.0, 20)
    parts["momentum"] = _scale(p["change_m5"], 3, 40, 15)
    if age is not None:
        parts["age"] = 10.0 if 5 <= age <= 30 else _scale(60 - abs(age - 17.5), 0, 55, 10)
    parts["socials"] = 5.0 if p.get("has_socials") else 0.0
    if rug is not None:
        parts["rugcheck"] = _scale(f["max_rugcheck_score"] - rug["score"], 0, f["max_rugcheck_score"], 10)
        if rug["warn"]:
            parts["rugcheck"] = max(0.0, parts["rugcheck"] - 2.0 * len(rug["warn"]))
    else:
        parts["rugcheck"] = 5.0

    score = round(sum(parts.values()), 1)
    decision = "buy" if score >= cfg["scoring"]["min_score"] else "watch"
    notes = [f"{k} {v:.0f}" for k, v in parts.items()]
    if decision == "watch":
        notes.insert(0, f"score {score} < {cfg['scoring']['min_score']}")
    return {"decision": decision, "score": score, "reasons": notes}
