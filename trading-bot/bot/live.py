"""Real-money execution is deliberately NOT included.

An executor that signs transactions with a funded wallet cannot be tested
from where this code was written, and an untested executor is how wallets
get drained. The interface below is what a live adapter has to implement
(for Solana: Jupiter quote + swap, signed with a local keypair). Run the
paper mode for weeks first and look at the edge report before writing it.
"""
from __future__ import annotations

from typing import Any


class LiveExecutor:
    def buy(self, pair: dict[str, Any], usd: float) -> dict[str, Any]:
        raise NotImplementedError(
            "Echtgeld-Ausfuehrung ist absichtlich nicht enthalten. "
            "Erst Paper-Modus laufen lassen und den Edge-Report lesen.")

    def sell(self, position: dict[str, Any], frac: float) -> dict[str, Any]:
        raise NotImplementedError("siehe LiveExecutor.buy")
