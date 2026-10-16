"""Hindsight parameter sweep.

For every stored candidate with a filled forward return, re-run the hard
filters with ONE threshold moved across a grid (all others at their current
value) and report, per grid value, how many candidates would have been
eligible and what their average forward return was. It answers "would a
stricter liquidity floor have helped?" from the bot's own history - one
parameter at a time, which is honest about what the data can support.
"""
from __future__ import annotations

import copy
from typing import Any

from .strategy import evaluate

SWEEPS: list[dict[str, Any]] = [
    {"path": "filters.min_liquidity_usd", "label": "Min. Liquidität", "unit": "$",
     "grid": [5000, 10000, 15000, 25000, 40000, 60000, 100000]},
    {"path": "filters.min_volume_m5_usd", "label": "Min. Volumen 5 min", "unit": "$",
     "grid": [1000, 2000, 3000, 5000, 8000, 12000, 20000]},
    {"path": "filters.min_buys_m5", "label": "Min. Käufe 5 min", "unit": "",
     "grid": [5, 10, 15, 25, 40, 60]},
    {"path": "filters.min_buy_sell_ratio_m5", "label": "Min. Käufe/Verkäufe", "unit": "",
     "grid": [1.0, 1.2, 1.5, 2.0, 2.5, 3.0]},
    {"path": "filters.max_price_change_m5_pct", "label": "Max. Kursänderung 5 min", "unit": "%",
     "grid": [30, 60, 100, 150, 250, 400, 1000]},
    {"path": "filters.min_age_minutes", "label": "Mindestalter", "unit": "min",
     "grid": [0, 1, 2, 5, 10, 20]},
    {"path": "filters.max_age_minutes", "label": "Höchstalter", "unit": "min",
     "grid": [15, 30, 60, 120, 240, 480]},
    {"path": "scoring.min_score", "label": "Min. Score für Kauf", "unit": "",
     "grid": [40, 50, 55, 60, 65, 70, 80]},
]

MIN_N = 5  # fewer eligible candidates than this is noise, not a result


def _set(cfg: dict[str, Any], path: str, value: Any) -> None:
    node = cfg
    keys = path.split(".")
    for k in keys[:-1]:
        node = node[k]
    node[keys[-1]] = value


def _get(cfg: dict[str, Any], path: str) -> Any:
    node = cfg
    for k in path.split("."):
        node = node[k]
    return node


def run(samples: list[dict[str, Any]], cfg: dict[str, Any]) -> dict[str, Any]:
    """samples: [{snapshot, change_pct}] for one horizon. Returns the sweep table."""
    base = copy.deepcopy(cfg)
    # the stored snapshot carries the rug summary when the live run had one;
    # where it is missing, the sweep must not count that as a rejection
    base["filters"]["allow_rugcheck_unknown"] = True
    usable = [s for s in samples if s.get("snapshot") and s.get("change_pct") is not None]
    out: dict[str, Any] = {"n_candidates": len(usable), "min_n": MIN_N, "params": []}
    if not usable:
        return out

    def bucket(trial: dict[str, Any]) -> dict[str, Any]:
        rets = []
        for s in usable:
            v = evaluate(s["snapshot"], s["snapshot"].get("rug"), trial)
            if v["decision"] == "buy":
                rets.append(float(s["change_pct"]))
        n = len(rets)
        return {"n_buy": n, "avg_ret": (sum(rets) / n) if n else None,
                "win_rate": (sum(1 for r in rets if r > 0) / n) if n else None}

    current_bucket = bucket(base)
    for spec in SWEEPS:
        current = _get(base, spec["path"])
        rows = []
        for value in spec["grid"]:
            trial = copy.deepcopy(base)
            _set(trial, spec["path"], value)
            rows.append({"value": value, **bucket(trial), "current": value == current})
        valid = [r for r in rows if r["n_buy"] >= MIN_N and r["avg_ret"] is not None]
        best = None
        if valid:
            top = max(r["avg_ret"] for r in valid)
            tied = [r for r in valid if abs(r["avg_ret"] - top) < 1e-9]
            # among equally good values prefer the smallest change from today's setting
            cur_idx = next((i for i, r in enumerate(rows) if r["current"]), 0)
            best = min(tied, key=lambda r: abs(spec["grid"].index(r["value"]) - cur_idx))
        out["params"].append({"path": spec["path"], "label": spec["label"], "unit": spec["unit"],
                              "current": current, "values": rows,
                              "best": best["value"] if best else None,
                              "best_avg_ret": best["avg_ret"] if best else None,
                              "current_avg_ret": current_bucket["avg_ret"], "current_n": current_bucket["n_buy"]})
    return out
