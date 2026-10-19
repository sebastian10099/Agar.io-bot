"""Own safety check straight from the Solana chain, used when RugCheck does not
answer. One public RPC call per token (getAccountInfo on the mint) reveals the
signals that make a token a trap no matter what its chart looks like:

- freeze authority still set   -> the creator can freeze your tokens (honeypot)
- mint authority still set     -> the creator can print unlimited supply
- Token-2022 extensions        -> permanent delegate, transfer hook, pausable,
                                  frozen-by-default accounts, non-transferable:
                                  all let someone take or lock your tokens;
                                  a transfer fee is a warning.

- one wallet or the ten largest wallets holding a big share of the supply
                                -> they can dump on every buyer (the classic rug
                                   since LP pulls became rare); token accounts
                                   owned by programs - the pump.fun curve, AMM
                                   pools, lockers - do not count: their owner
                                   address lies off the ed25519 curve.
- when the holder query gets no answer (the public endpoint throttles it hard):
  for a pump.fun coin the creator's share - its curve account names the
  creator, whose token account address follows from it; plain reads. Where
  the coin shares its creator fees, the curve names pump.fun's fee-sharing
  account instead, and that one lists the admin and the fee shareholders:
  their combined share counts.

It sees less than RugCheck did (no LP-lock or insider analysis), so the
strategy gives it only half of RugCheck's score points. RPC: SOLANA_RPC_URL,
default the public mainnet endpoint (rate-limited, enough for the few tokens
that reach this check)."""
from __future__ import annotations

import base64
import hashlib
import os
import struct
import time
from typing import Any, Callable, Optional

from .http import post_json

DEFAULT_RPC = "https://api.mainnet-beta.solana.com"
TIMEOUT_S = 8
TRIP_AFTER = 3
PAUSE_S = 60.0

PUMP_PROGRAM = "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P"
PUMP_FEES_PROGRAM = "pfeeUxB6jkeY1Hxd7CsFCAjcbHA9rWtchMGdZ6VojVZ"
ATA_PROGRAM = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
TOKEN_PROGRAMS = {"spl-token": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
                  "spl-token-2022": "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"}
CREATOR_DANGER, CREATOR_WARN = 15.0, 5.0   # % of supply still in the creator's wallet

CACHE_TTL_S = 300.0           # holders move: a token seen again after 5 minutes is checked again
HOLDER_DANGER = (25.0, 60.0)  # % of supply: one wallet, the ten largest wallets
HOLDER_WARN = (10.0, 35.0)
BURN = {"1nc1nerator11111111111111111111111111111111"}

_P = 2 ** 255 - 19
_D = (-121665 * pow(121666, _P - 2, _P)) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)
_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58decode(text: str) -> bytes:
    n = 0
    for ch in text:
        n = n * 58 + _B58.index(ch)                     # ValueError on a foreign character
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    return b"\x00" * (len(text) - len(text.lstrip("1"))) + raw


def b58encode(raw: bytes) -> str:
    n = int.from_bytes(raw, "big")
    out = ""
    while n:
        n, r = divmod(n, 58)
        out = _B58[r] + out
    return "1" * (len(raw) - len(raw.lstrip(b"\x00"))) + out


def find_program_address(seeds: list[bytes], program: str) -> str:
    """The chain's own derivation: the first bump (from 255 down) whose hash is off the curve."""
    pid = b58decode(program)
    for bump in range(255, -1, -1):
        h = hashlib.sha256(b"".join(seeds) + bytes([bump]) + pid + b"ProgramDerivedAddress").digest()
        if not _point_on_curve(h):
            return b58encode(h)
    raise ValueError("no program address")


def on_curve(address: str) -> Optional[bool]:
    """Is this Solana address an ed25519 public key (a wallet) or not (a
    program-derived address)? Same test as the chain's own: does the 32-byte
    point decompress? None for something that is no address at all."""
    try:
        b = b58decode(address)
    except ValueError:
        return None
    if len(b) != 32:
        return None
    return _point_on_curve(b)


def _point_on_curve(b: bytes) -> bool:
    y = int.from_bytes(b, "little")
    sign, y = y >> 255, y & ((1 << 255) - 1)
    if y >= _P:
        return False
    u, v = (y * y - 1) % _P, (_D * y * y + 1) % _P
    x = (u * pow(v, 3, _P) * pow(u * pow(v, 7, _P), (_P - 5) // 8, _P)) % _P
    vx2 = (v * x * x) % _P
    if vx2 == (-u) % _P and vx2 != u:
        x = (x * _SQRT_M1) % _P
    elif vx2 != u:
        return False
    return not (x == 0 and sign)


DANGER_EXTENSIONS = {
    "permanentDelegate": "Permanent Delegate (kann Tokens aus jedem Konto ziehen)",
    "transferHook": "Transfer-Hook (fremdes Programm entscheidet über Verkäufe)",
    "pausableConfig": "pausierbar (Handel kann gestoppt werden)",
    "nonTransferable": "nicht übertragbar",
}


def rpc_url() -> str:
    return os.environ.get("SOLANA_RPC_URL") or DEFAULT_RPC


def holder_urls() -> list[str]:
    """getTokenLargestAccounts is the one call the public mainnet endpoint throttles
    hard ("Too many requests for a specific RPC call"), and no free public endpoint
    answers it without a key (checked October 2026: publicnode, drpc, ankr,
    onfinality, omniatech). SOLANA_HOLDER_RPCS adds endpoints, comma-separated -
    e.g. a free Helius key URL - that are tried in turn."""
    extra = [u.strip() for u in os.environ.get("SOLANA_HOLDER_RPCS", "").split(",") if u.strip()]
    return list(dict.fromkeys([rpc_url()] + extra))


def assess_mint(value: Optional[dict[str, Any]]) -> Optional[dict[str, Any]]:
    """getAccountInfo(jsonParsed).result.value of a mint -> safety summary, or None if it is no SPL mint."""
    if not isinstance(value, dict):
        return None
    data = value.get("data")
    parsed = data.get("parsed") if isinstance(data, dict) else None
    if not isinstance(parsed, dict) or parsed.get("type") != "mint":
        return None
    info = parsed.get("info") or {}
    danger: list[str] = []
    warn: list[str] = []
    if info.get("freezeAuthority"):
        danger.append("Freeze Authority aktiv (Konten können eingefroren werden)")
    if info.get("mintAuthority"):
        warn.append("Mint Authority aktiv (Menge kann erhöht werden)")
    for ext in info.get("extensions") or []:
        name = (ext or {}).get("extension")
        state = (ext or {}).get("state") or {}
        if name in DANGER_EXTENSIONS:
            if name == "permanentDelegate" and not state.get("delegate"):
                continue
            if name == "transferHook" and not state.get("programId"):
                continue
            danger.append(DANGER_EXTENSIONS[name])
        elif name == "defaultAccountState" and str(state.get("accountState", "")).lower() == "frozen":
            danger.append("Konten standardmäßig eingefroren")
        elif name == "transferFeeConfig":
            fee = ((state.get("newerTransferFee") or {}).get("transferFeeBasisPoints")
                   or (state.get("olderTransferFee") or {}).get("transferFeeBasisPoints") or 0)
            if int(fee) > 0:
                warn.append(f"Transfergebühr {int(fee) / 100:g} %")
    try:
        supply = int(info.get("supply") or 0)
    except (TypeError, ValueError):
        supply = 0
    return {"score": 0.0, "danger": danger, "warn": warn, "source": "onchain",
            "program": data.get("program") if isinstance(data, dict) else None, "supply_raw": supply}


def creator_field(data: bytes) -> Optional[str]:
    """pump.fun BondingCurve: 8-byte discriminator, five u64 reserves, the 'complete' flag,
    then the creator (bytes 49-81): a wallet, or pump.fun's fee-sharing account."""
    return b58encode(data[49:81]) if len(data) >= 81 else None


def parse_fee_sharing(data: bytes, mint: str) -> Optional[list[str]]:
    """pump.fun fee-sharing account (program pfee...): discriminator, bump, version,
    status, the coin's mint (bytes 11-43), the admin, an admin-revoked flag, then
    the shareholders (address, share in basis points). Wallets on the creator's
    side, admin first; None unless the record checks out (right mint, shares adding
    up to exactly 100 %), so a changed layout never yields a wrong answer."""
    if len(data) < 80 or b58encode(data[11:43]) != mint:
        return None
    n = struct.unpack_from("<I", data, 76)[0]
    if not 0 < n <= 32 or len(data) < 80 + 34 * n:
        return None
    holders, total = [], 0
    for i in range(n):
        off = 80 + 34 * i
        holders.append(b58encode(data[off:off + 32]))
        total += struct.unpack_from("<H", data, off + 32)[0]
    if total != 10_000:
        return None
    wallets = [a for a in [b58encode(data[43:75])] + holders if on_curve(a)]
    return list(dict.fromkeys(wallets)) or None


def judge_creator(share: float, wallets: int = 1) -> tuple[list[str], list[str]]:
    who = "der Ersteller hält" if wallets <= 1 else f"Ersteller und Gebühren-Teilhaber ({wallets} Wallets) halten"
    if share >= CREATOR_DANGER:
        return [f"{who} {share:.0f} % (können jederzeit abverkaufen)" if wallets > 1
                else f"{who} {share:.0f} % (kann jederzeit abverkaufen)"], []
    if share >= CREATOR_WARN:
        return [], [f"{who} {share:.0f} %"]
    return [], []


def judge_holders(h: dict[str, Any]) -> tuple[list[str], list[str]]:
    """Danger and warning lines from a holder breakdown."""
    danger: list[str] = []
    warn: list[str] = []
    if h["top1"] >= HOLDER_DANGER[0]:
        danger.append(f"eine Wallet hält {h['top1']:.0f} % aller Tokens")
    elif h["top1"] >= HOLDER_WARN[0]:
        warn.append(f"eine Wallet hält {h['top1']:.0f} %")
    if h["top10"] >= HOLDER_DANGER[1]:
        danger.append(f"die 10 größten Wallets halten {h['top10']:.0f} %")
    elif h["top10"] >= HOLDER_WARN[1]:
        warn.append(f"die 10 größten Wallets halten {h['top10']:.0f} %")
    return danger, warn


class OnChainCheck:
    label = "Eigenprüfung (Solana-RPC)"

    def __init__(self, post: Callable[..., Any] = post_json, url: Optional[str] = None,
                 clock: Callable[[], float] = time.time) -> None:
        self.post = post
        self.url = url or rpc_url()
        self.holder_urls = [self.url] + [u for u in holder_urls() if u != self.url] if url is None else [self.url]
        self.clock = clock
        self._cache: dict[str, tuple[float, dict[str, Any]]] = {}
        self.calls = 0
        self.fails = 0
        self.last_error = ""
        self._streak = 0
        self._paused_until = 0.0

    def health(self) -> dict[str, Any]:
        return {"calls": self.calls, "fails": self.fails, "last_error": self.last_error,
                "ok": None if not self.calls else (self.last_error == "")}

    def _rpc(self, method: str, params: list[Any], url: Optional[str] = None) -> Any:
        answer = self.post(url or self.url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, timeout=TIMEOUT_S)
        if not isinstance(answer, dict):
            raise RuntimeError("unerwartete Antwort")
        if answer.get("error"):
            raise RuntimeError(str((answer["error"] or {}).get("message", answer["error"]))[:120])
        return (answer.get("result") or {}).get("value")

    def holders(self, mint: str, supply_raw: int) -> Optional[dict[str, Any]]:
        """Share of the supply in the largest wallets, program-owned accounts left out."""
        largest, last, used = None, None, self.url
        for url in list(self.holder_urls):
            try:
                largest = self._rpc("getTokenLargestAccounts", [mint, {"commitment": "confirmed"}], url)
            except Exception as error:  # noqa: BLE001 - throttled or refused: the next endpoint
                last = error
                continue
            if url != self.holder_urls[0]:                  # remember the one that answers
                self.holder_urls.remove(url)
                self.holder_urls.insert(0, url)
            used = url
            break
        else:
            raise last or RuntimeError("kein RPC-Endpunkt")
        if not isinstance(largest, list) or supply_raw <= 0:
            return None
        accounts = [a for a in largest if isinstance(a, dict) and a.get("address")][:20]
        values = self._rpc("getMultipleAccounts", [[a["address"] for a in accounts],
                                                   {"encoding": "jsonParsed", "commitment": "confirmed"}], used)
        if not isinstance(values, list) or len(values) != len(accounts):
            return None
        wallets: dict[str, float] = {}
        programs = 0.0
        for acc, value in zip(accounts, values):
            info = ((((value or {}).get("data") or {}).get("parsed") or {}).get("info") or {}) if isinstance(value, dict) else {}
            owner = info.get("owner")
            share = int(acc.get("amount") or 0) / supply_raw * 100
            if not owner:
                continue
            if owner in BURN or on_curve(owner) is False:
                programs += share                        # curve, pool, locker: not a seller
            else:
                wallets[owner] = wallets.get(owner, 0.0) + share
        top = sorted(wallets.values(), reverse=True)
        return {"top1": round(top[0], 2) if top else 0.0, "top10": round(sum(top[:10]), 2),
                "wallets": len(top), "programs": round(programs, 2)}

    def creator_share(self, mint: str, program: Optional[str], supply_raw: int) -> Optional[dict[str, Any]]:
        """Share of the supply in the creator's wallet, for a pump.fun coin (None for any other)."""
        if supply_raw <= 0 or program not in TOKEN_PROGRAMS:
            return None
        curve = self._rpc("getAccountInfo", [find_program_address([b"bonding-curve", b58decode(mint)], PUMP_PROGRAM),
                                             {"encoding": "base64", "commitment": "confirmed"}])
        if not isinstance(curve, dict) or curve.get("owner") != PUMP_PROGRAM:
            return None                                    # not a pump.fun coin
        who = creator_field(base64.b64decode((curve.get("data") or [""])[0]))
        if who is None:
            return None
        if on_curve(who):
            wallets = [who]
        else:                                              # fee sharing: the curve names its account
            cfg = self._rpc("getAccountInfo", [who, {"encoding": "base64", "commitment": "confirmed"}])
            if not isinstance(cfg, dict) or cfg.get("owner") != PUMP_FEES_PROGRAM:
                return None
            wallets = parse_fee_sharing(base64.b64decode((cfg.get("data") or [""])[0]), mint) or []
            if not wallets:
                return None
        atas = [find_program_address([b58decode(w), b58decode(TOKEN_PROGRAMS[program]), b58decode(mint)], ATA_PROGRAM)
                for w in wallets]
        values = self._rpc("getMultipleAccounts", [atas, {"encoding": "jsonParsed", "commitment": "confirmed"}])
        if not isinstance(values, list) or len(values) != len(atas):
            return None
        amount = 0
        for acc in values:                                 # no account: sold out or never bought
            info = ((((acc or {}).get("data") or {}).get("parsed") or {}).get("info") or {}) if isinstance(acc, dict) else {}
            amount += int((info.get("tokenAmount") or {}).get("amount") or 0)
        return {"creator": wallets[0], "wallets": len(wallets), "share": round(amount / supply_raw * 100, 2)}

    def summary(self, mint: str) -> Optional[dict[str, Any]]:
        hit = self._cache.get(mint)
        if hit and self.clock() - hit[0] < CACHE_TTL_S:
            return hit[1]
        if self.clock() < self._paused_until:
            return None
        self.calls += 1
        try:
            result = assess_mint(self._rpc("getAccountInfo", [mint, {"encoding": "jsonParsed", "commitment": "confirmed"}]))
            if result is None:
                raise RuntimeError("kein SPL-Token-Mint")
        except Exception as error:  # noqa: BLE001 - unknown stays unknown: the token is watched, never bought
            self.fails += 1
            self._streak += 1
            self.last_error = f"{type(error).__name__}: {str(error)[:120]}"
            if self._streak >= TRIP_AFTER:
                self._paused_until = self.clock() + PAUSE_S
                self.last_error += f" – Pause {PAUSE_S:.0f} s nach {self._streak} Fehlern"
                self._streak = 0
            return None
        self.last_error = ""
        self._streak = 0
        supply = int(result.pop("supply_raw", 0) or 0)
        try:
            h = self.holders(mint, supply)
        except Exception as error:  # noqa: BLE001 - the authority check stands; the gap is shown
            h = None
            self.last_error = f"Halter: {type(error).__name__}: {str(error)[:100]}"
        if h is None:
            c = None
            if mint.endswith("pump"):
                try:
                    c = self.creator_share(mint, result.get("program"), supply)
                except Exception as error:  # noqa: BLE001 - then the gap stays as it is
                    self.last_error = (self.last_error + " · " if self.last_error else "") + \
                        f"Ersteller: {type(error).__name__}: {str(error)[:80]}"
            if c is None:
                result["warn"].append("Halterverteilung unbekannt (RPC ohne Antwort)")
            else:
                danger, warn = judge_creator(c["share"], c.get("wallets", 1))
                result["danger"] += danger
                result["warn"] += warn
                result["warn"].append(f"Halterverteilung unbekannt – nur der Ersteller geprüft ({c['share']:.1f} %)")
                result["creator"] = c
        else:
            danger, warn = judge_holders(h)
            result["danger"] += danger
            result["warn"] += warn
            result["holders"] = h
        self._cache[mint] = (self.clock(), result)
        return result


class SafetyCheck:
    """RugCheck first; when it has no answer, the own on-chain check."""

    def __init__(self, rugcheck: Any, onchain: Any) -> None:
        self.rugcheck = rugcheck
        self.onchain = onchain

    def summary(self, mint: str) -> Optional[dict[str, Any]]:
        r = self.rugcheck.summary(mint)
        if r is not None:
            return dict(r, source=r.get("source", "rugcheck"))
        return self.onchain.summary(mint)

    def health(self) -> dict[str, Any]:
        h = dict(self.rugcheck.health())
        h["fallback"] = self.onchain.health()
        return h

    # the self-test pokes at the RugCheck cache and error text
    @property
    def _cache(self) -> dict[str, Any]:
        return self.rugcheck._cache

    @property
    def last_error(self) -> str:
        return self.rugcheck.last_error
