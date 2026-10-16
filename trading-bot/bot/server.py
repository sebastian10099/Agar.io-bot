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


def _csv(rows: list, columns: list) -> bytes:
    out = io.StringIO()
    w = csv.writer(out, delimiter=";")
    w.writerow(columns)
    for r in rows:
        w.writerow(["" if r.get(c) is None else
                    (datetime.fromtimestamp(r[c]).isoformat(timespec="seconds") if c.endswith("_at") or c == "at" else r[c])
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

        def do_GET(self) -> None:  # noqa: N802 - http.server API
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

        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length") or 0)
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                self._json({"error": "bad json"}, 400)
                return
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
