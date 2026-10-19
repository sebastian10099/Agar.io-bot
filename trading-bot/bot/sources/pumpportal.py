"""pump.fun launches and migrations from PumpPortal's free data stream.

pump.fun's own API sits behind Cloudflare, which refuses data-center
addresses (GitHub's runners, many VPS): from there the bot saw no pump.fun
coin at all. PumpPortal (pumpportal.fun) streams the same events over a
websocket, without a key: every new coin ("create") and every coin whose
bonding curve completed and moved to its PumpSwap pool ("migrate") - the
latter are exactly the pool tokens the strategy trades.

One connection, kept open by a background thread and reopened with a
growing pause when it drops. The websocket client below is the small part
of RFC 6455 a client needs (text frames, ping/pong, close), on the standard
library only."""
from __future__ import annotations

import base64
import collections
import json
import os
import socket
import ssl
import struct
import threading
import time
from typing import Any, Callable, Optional

HOST = "pumpportal.fun"
PATH = "/api/data"
SUBSCRIBE = [{"method": "subscribeNewToken"}, {"method": "subscribeMigration"}]
KEEP = 2000                    # events held between two polls at most
SILENT_ERROR_S = 90.0          # without a connection this long, the feed reports its trouble


class WebSocketError(Exception):
    pass


class WebSocket:
    """A text-frame websocket client over TLS."""

    def __init__(self, host: str, path: str, timeout: float = 20.0, connect: Callable[..., Any] = socket.create_connection) -> None:
        raw = connect((host, 443), timeout=timeout)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                           "User-Agent: new-token-bot/0.1\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise WebSocketError("Verbindung beim Aufbau geschlossen")
            head += chunk
            if len(head) > 65536:
                raise WebSocketError("Antwort ohne Ende")
        status = head.split(b"\r\n", 1)[0].decode("latin-1")
        if " 101 " not in status + " ":
            raise WebSocketError(f"kein Websocket: {status[:80]}")
        self._buf = head.split(b"\r\n\r\n", 1)[1]

    def _read(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise WebSocketError("Verbindung geschlossen")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def _send(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        n = len(payload)
        head = bytes([0x80 | opcode])
        head += bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 \
            else bytes([0x80 | 127]) + struct.pack(">Q", n)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def send(self, text: str) -> None:
        self._send(0x1, text.encode())

    def recv(self) -> str:
        """The next text message; answers pings on the way."""
        parts: list[bytes] = []
        while True:
            b1, b2 = self._read(2)
            fin, opcode = b1 & 0x80, b1 & 0x0F
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b2 & 0x80 else b""
            data = self._read(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x8:
                raise WebSocketError("vom Server geschlossen")
            if opcode == 0x9:
                self._send(0xA, data)
                continue
            if opcode == 0xA:
                continue
            parts.append(data)
            if fin:
                return b"".join(parts).decode("utf-8", "replace")

    def close(self) -> None:
        try:
            self._send(0x8, b"")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


class PumpPortal:
    """Discovery feed fed by the stream: `discover(chains)` hands out what arrived since."""

    label = "pump.fun über PumpPortal (Datenstrom)"

    def __init__(self, open_socket: Callable[[], Any] = lambda: WebSocket(HOST, PATH),
                 clock: Callable[[], float] = time.time, start: bool = True) -> None:
        self.open_socket = open_socket
        self.clock = clock
        self._events: collections.deque = collections.deque(maxlen=KEEP)
        self._lock = threading.Lock()
        self._thread: Optional[threading.Thread] = None
        self._autostart = start
        self.connected_at: Optional[float] = None
        self.started_at = clock()
        self.last_error = ""
        self.received = 0

    def _ensure_running(self) -> None:
        if self._autostart and (self._thread is None or not self._thread.is_alive()):
            self._thread = threading.Thread(target=self._run, name="pumpportal", daemon=True)
            self._thread.start()

    def _run(self) -> None:
        pause = 2.0
        while True:
            ws = None
            try:
                ws = self.open_socket()
                for message in SUBSCRIBE:
                    ws.send(json.dumps(message))
                self.connected_at, self.last_error, pause = self.clock(), "", 2.0
                while True:
                    self.take(ws.recv())
            except Exception as error:  # noqa: BLE001 - reopened after a pause, the poll goes on without
                self.connected_at = None
                self.last_error = f"{type(error).__name__}: {str(error)[:120]}"
            finally:
                if ws is not None:
                    ws.close()
            time.sleep(pause)
            pause = min(60.0, pause * 2)

    def take(self, text: str) -> None:
        """One message from the stream: a coin event is kept, anything else ignored."""
        try:
            msg = json.loads(text)
        except ValueError:
            return
        if not isinstance(msg, dict) or not isinstance(msg.get("mint"), str) or not msg["mint"]:
            return
        kind = "migrate" if str(msg.get("txType") or "").lower() == "migrate" else "create"
        with self._lock:
            self._events.append({"mint": msg["mint"], "kind": kind, "at": self.clock(),
                                 "symbol": msg.get("symbol"), "name": msg.get("name"),
                                 "curve": msg.get("bondingCurveKey")})
            self.received += 1

    def discover(self, chains: list[str]) -> dict[str, list[dict[str, Any]]]:
        if "solana" not in chains:
            return {}
        self._ensure_running()
        with self._lock:
            events, self._events = list(self._events), collections.deque(maxlen=KEEP)
        if not events and self.connected_at is None and self.last_error \
                and self.clock() - self.started_at > SILENT_ERROR_S:
            raise RuntimeError(f"PumpPortal nicht erreichbar – {self.last_error}")
        out, seen = [], set()
        for e in reversed(events):                         # newest first, one entry per coin
            if e["mint"] in seen:
                continue
            seen.add(e["mint"])
            migrated = e["kind"] == "migrate"
            out.append({"token": e["mint"], "snapshot": None if migrated else {
                "chain": "solana", "dex": "pumpfun", "pair": e["curve"] or e["mint"], "token": e["mint"],
                "symbol": e["symbol"], "name": e["name"], "url": f"https://pump.fun/coin/{e['mint']}",
                "price_usd": 0.0, "liquidity_usd": 0.0, "liquidity_kind": "unknown", "fdv": 0.0, "market_cap": 0.0,
                "volume_m5": 0.0, "volume_h1": 0.0, "buys_m5": 0, "sells_m5": 0, "buys_h1": 0, "sells_h1": 0,
                "change_m5": 0.0, "change_h1": 0.0, "age_min": (self.clock() - e["at"]) / 60.0, "boosts": 0,
                "has_socials": False, "graduated": False}})
        return {"solana": out}


class PumpFeed:
    """The "pumpfun" source: pump.fun's API and PumpPortal's stream side by side. Either
    one is enough; only when both fail is the source reported as failing."""

    label = "pump.fun – neue Coins & Umzüge"

    def __init__(self, api: Any, stream: Any) -> None:
        self.api = api
        self.stream = stream
        self.note = ""

    def discover(self, chains: list[str]) -> dict[str, list[dict[str, Any]]]:
        if "solana" not in chains:
            return {}
        items: list[dict[str, Any]] = []
        errors: list[Exception] = []
        for src in (self.stream, self.api):
            try:
                items += (src.discover(chains) or {}).get("solana", [])
            except Exception as error:  # noqa: BLE001 - the other way may still deliver
                errors.append(error)
        if len(errors) == 2:
            raise errors[1]
        self.note = f"API: {type(errors[0]).__name__}" if errors else ""
        return {"solana": items}
