"""Local dashboard: static page + JSON state, bound to localhost only."""
from __future__ import annotations

import csv
import io
import json
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from . import settings
from .ai import start_login, store_key

WEB = Path(__file__).parent / "web"
LOCAL_NAMES = {"127.0.0.1", "localhost", "[::1]"}
MAX_BODY = 1_000_000


def _host_name(host: str) -> str:
    """'localhost:8765' -> 'localhost', '[::1]:8765' -> '[::1]'."""
    host = host.strip().lower()
    if host.startswith("["):
        return host.split("]", 1)[0] + "]"
    return host.rsplit(":", 1)[0] if ":" in host else host


class BadRequest(Exception):
    pass


def _cell(value: Any) -> Any:
    """Token names and symbols come from strangers: text that a spreadsheet would
    read as a formula (=, +, -, @, tab, CR) gets a leading apostrophe. Numbers stay numbers."""
    if isinstance(value, str) and value[:1] in ("=", "+", "-", "@", "\t", "\r"):
        return "'" + value
    return value


def _csv(rows: list, columns: list) -> bytes:
    out = io.StringIO()
    w = csv.writer(out, delimiter=";")
    w.writerow(columns)
    for r in rows:
        w.writerow(["" if r.get(c) is None else
                    (datetime.fromtimestamp(r[c]).isoformat(timespec="seconds") if c.endswith("_at") or c == "at" else _cell(r[c]))
                    for c in columns])
    return ("\ufeff" + out.getvalue()).encode("utf-8")


def make_server(engine: Any, host: str, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args: Any) -> None:  # silence per-request logging
            pass

        def _send(self, status: int, body: bytes, ctype: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, payload: Any, status: int = 200) -> None:
            self._send(status, json.dumps(payload).encode("utf-8"), "application/json")

        # --- guards: only the control page itself may talk to this server --------
        def _refuse(self, status: int, why: str) -> None:
            engine.store.log("warn", f"Anfrage abgewiesen ({status}): {why} – {self.command} {self.path[:80]}")
            self._json({"ok": False, "error": why}, status)

        def _host_ok(self) -> bool:
            # a foreign host name reaching 127.0.0.1 is a DNS-rebinding attempt
            host = self.headers.get("Host")
            return host is None or _host_name(host) in LOCAL_NAMES

        def _origin_ok(self) -> bool:
            origin = self.headers.get("Origin")
            if origin is None:
                return True                      # same-origin requests may omit it
            port = self.server.server_address[1]
            return origin.strip().lower() in {f"http://{n}:{port}" for n in LOCAL_NAMES}

        def _guarded(self, handler) -> None:
            try:
                handler()
            except BadRequest as error:
                self._json({"ok": False, "error": str(error)}, 400)
            except (ValueError, TypeError, KeyError, AttributeError) as error:
                self._json({"ok": False, "error": f"ungültige Eingabe: {error}"}, 400)
            except Exception as error:  # noqa: BLE001 - answer instead of dropping the connection
                engine.store.log("error", f"API {self.command} {self.path[:80]}: {type(error).__name__}: {error}")
                self._json({"ok": False, "error": f"interner Fehler: {type(error).__name__}"}, 500)

        def do_GET(self) -> None:  # noqa: N802 - http.server API
            if not self._host_ok():
                self._refuse(403, "fremder Host-Name")
                return
            self._guarded(self._get)

        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(min(length, MAX_BODY)) if length > 0 else b""
            if not self._host_ok():
                self._refuse(403, "fremder Host-Name")
                return
            if not self._origin_ok():
                self._refuse(403, "fremde Herkunft – nur die Steuerseite darf den Bot steuern")
                return
            ctype = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
            if ctype != "application/json":
                # a form on another web page can send text/plain without asking; JSON it cannot
                self._refuse(415, "nur application/json")
                return
            if length > MAX_BODY:
                self._json({"ok": False, "error": "Anfrage zu groß"}, 413)
                return
            try:
                body = json.loads(raw or b"{}")
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._json({"error": "bad json"}, 400)
                return
            if not isinstance(body, dict):
                self._json({"ok": False, "error": "JSON-Objekt erwartet"}, 400)
                return
            self._guarded(lambda: self._post(body))

        def _get(self) -> None:
            if self.path in ("/", "/index.html"):
                self._send(200, (WEB / "index.html").read_bytes(), "text/html; charset=utf-8")
            elif self.path == "/api/state":
                self._json(engine.state())
            elif self.path == "/api/schema":
                self._json(settings.schema_for_client())
            elif self.path == "/api/config":
                self._json({"config": settings.flat(engine.cfg)})
            elif self.path == "/api/profiles":
                self._json({"profiles": engine.profiles()})
            elif self.path.startswith("/api/sweep"):
                q = self.path.split("?", 1)[1] if "?" in self.path else ""
                horizon = next((int(v) for k, _, v in (kv.partition("=") for kv in q.split("&")) if k == "horizon" and v.isdigit()), 15)
                self._json(engine.sweep(horizon))
            elif self.path == "/api/export/trades.csv":
                rows = engine.store.trades(100000)
                body = _csv(rows, ["id", "position_id", "at", "side", "price", "usd", "frac", "reason"])
                self._send(200, body, "text/csv; charset=utf-8")
            elif self.path == "/api/export/positions.csv":
                rows = engine.store.closed_positions(100000) + engine.store.open_positions()
                body = _csv(rows, ["id", "status", "symbol", "chain", "token", "pair", "opened_at", "closed_at",
                                   "entry_price", "size_usd", "remaining_frac", "peak_price", "realized_usd", "exit_reason"])
                self._send(200, body, "text/csv; charset=utf-8")
            elif self.path == "/api/export/candidates.csv":
                rows = [{**c, "reasons": " | ".join(c["reasons"]), **{"snap_" + k: v for k, v in c["snapshot"].items()
                         if isinstance(v, (int, float, str))}} for c in engine.store.candidates(100000)]
                cols = ["id", "seen_at", "chain", "symbol", "token", "pair", "decision", "score", "price_usd", "reasons",
                        "snap_liquidity_usd", "snap_volume_m5", "snap_buys_m5", "snap_sells_m5", "snap_change_m5", "snap_age_min", "snap_fdv"]
                self._send(200, _csv(rows, cols), "text/csv; charset=utf-8")
            elif self.path.startswith("/api/candidates/"):
                cid = self.path.rsplit("/", 1)[1]
                result = engine.candidate_detail(int(cid)) if cid.isdigit() else {"ok": False, "error": "bad id"}
                self._json(result, 200 if result["ok"] else 404)
            elif self.path.startswith("/api/positions/"):
                tail = self.path.rsplit("/", 1)[-1]
                result = engine.position_detail(int(tail)) if tail.isdigit() else {"ok": False, "error": "not found"}
                self._json(result, 200 if result["ok"] else 404)
            elif self.path == "/api/defaults":
                bundled = json.loads((Path(__file__).parent / "config.json").read_text())
                self._json({"config": settings.flat(bundled)})
            else:
                self._json({"error": "not found"}, 404)

        def _post(self, body: dict) -> None:
            if self.path == "/api/control":
                action = body.get("action")
                if action in ("pause", "resume"):
                    engine.set_paused(action == "pause")
                elif action == "poll":
                    engine.poll_now()
                else:
                    self._json({"error": "unknown action"}, 400)
                    return
                self._json({"ok": True, "paused": engine.paused})
            elif self.path == "/api/config":
                result = engine.apply_config(body.get("patch") or {})
                self._json(result, 200 if result["ok"] else 422)
            elif self.path == "/api/positions/close":
                result = engine.close_position(int(body.get("id") or 0))
                self._json(result, 200 if result["ok"] else 409)
            elif self.path == "/api/ai/key":
                result = store_key(str(body.get("key") or ""), str(body.get("provider") or "anthropic"))
                if result["ok"]:
                    engine.advisor._client = None
                    engine.advisor._client_error = None
                    engine.store.log("info", "dashboard: Anthropic-Schlüssel im Schlüsselbund gespeichert")
                self._json(result, 200 if result["ok"] else 400)
            elif self.path == "/api/ai/login":
                result = start_login()
                if result["ok"]:
                    engine.advisor._client = None
                    engine.advisor._client_error = None
                    engine.store.log("info", "dashboard: Claude-Anmeldung " + ("schon vorhanden" if result.get("already") else "gestartet (ant auth login)"))
                self._json(result, 200 if result["ok"] else 400)
            elif self.path == "/api/profiles":
                result = engine.save_profile(str(body.get("name") or ""), body.get("config"))
                self._json(result, 200 if result["ok"] else 400)
            elif self.path == "/api/profiles/apply":
                result = engine.apply_profile(str(body.get("name") or ""))
                self._json(result, 200 if result["ok"] else (422 if "errors" in result else 404))
            elif self.path == "/api/profiles/delete":
                result = engine.delete_profile(str(body.get("name") or ""))
                self._json(result, 200 if result["ok"] else 404)
            elif self.path == "/api/positions/sell":
                result = engine.sell_position(int(body.get("id") or 0), body.get("frac"))
                self._json(result, 200 if result["ok"] else 409)
            elif self.path == "/api/positions/open":
                result = engine.open_from_candidate(int(body.get("candidate_id") or 0))
                self._json(result, 200 if result["ok"] else 409)
            elif self.path == "/api/update":
                from pathlib import Path as _P
                from . import updater
                result = updater.start_update(_P(__file__).resolve().parent.parent, self.server.server_address[1])
                if result["ok"]:
                    engine.store.log("info", "dashboard: Aktualisierung gestartet – Bot beendet sich für den Neustart")
                    threading.Timer(1.5, engine.stop).start()
                self._json(result, 200 if result["ok"] else 400)
            elif self.path == "/api/quit":
                engine.store.log("info", "dashboard: Bot beendet")
                self._json({"ok": True})
                threading.Timer(0.3, engine.stop).start()      # answer first, then stop the loop; main shuts the server down
            elif self.path == "/api/doctor":
                self._json(engine.doctor())
            elif self.path == "/api/reset":
                result = engine.reset(str(body.get("what") or "positions"), body.get("bankroll"))
                self._json(result, 200 if result["ok"] else 400)
            else:
                self._json({"error": "not found"}, 404)

    return ThreadingHTTPServer((host, port), Handler)
