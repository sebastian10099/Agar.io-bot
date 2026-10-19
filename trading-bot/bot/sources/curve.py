"""Bonding curves: a launchpad's price curve that a new token trades against
before it gets a real pool. DexScreener reports no liquidity for them and
GeckoTerminal a token-side reserve close to the FDV, so without this module
the liquidity filter rejects every one of them, however busy.

pump.fun's standard SOL curve is a constant product with fixed virtual
reserves: virtual SOL x virtual tokens = 30 SOL x 1,073,000,000 tokens
(checked against pump.fun's own reserve figures on live coins). The price
alone therefore gives the reserves, virtual SOL = sqrt(K x price in SOL),
and the curve fills orders like a constant-product pool holding that much:
2 x virtual SOL in USD is the liquidity of the pool with the same price
impact. Other curves (Meteora DBC, LaunchLab, pump.fun curves against other
quote tokens) have their own parameters; their liquidity stays unknown
rather than guessed."""
from __future__ import annotations

import math
from typing import Any, Optional

PUMP_K = 30 * 1.073e9                 # virtual SOL x virtual tokens, whole units
PUMP_VSOL_RANGE = (29.5, 116.0)       # launch (30 SOL) .. complete (85 SOL raised + 30 virtual)
SOL_MINT = "So11111111111111111111111111111111111111112"
PUMP_DEXES = {"pumpfun", "pump-fun"}
CURVE_DEXES = PUMP_DEXES | {"meteoradbc", "meteora-dbc", "launchlab", "raydium-launchlab"}


def is_curve(dex: Any) -> bool:
    return str(dex or "").lower() in CURVE_DEXES


def pump_liquidity(price_sol: float, sol_usd: float) -> Optional[float]:
    """Pool-equivalent liquidity in USD of a pump.fun SOL curve at this price,
    or None when the price does not lie on the standard curve."""
    if not (price_sol > 0 and sol_usd > 0):
        return None
    v_sol = math.sqrt(PUMP_K * price_sol)
    if not PUMP_VSOL_RANGE[0] <= v_sol <= PUMP_VSOL_RANGE[1]:
        return None
    return 2.0 * v_sol * sol_usd


def progress(price_sol: float) -> Optional[float]:
    """Share of the 85 SOL a pump.fun curve raises before it completes, 0..1."""
    if price_sol <= 0:
        return None
    v_sol = math.sqrt(PUMP_K * price_sol)
    return max(0.0, min(1.0, (v_sol - 30.0) / 85.0))
