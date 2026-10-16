"""Local dashboard: static page + JSON state, bound to localhost only."""
from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from . import settings

WEB = Path(__file__).parent / "web"


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
            elif self.path == "/api/reset":
                result = engine.reset(str(body.get("what") or "positions"))
                self._json(result, 200 if result["ok"] else 400)
            else:
                self._json({"error": "not found"}, 404)

    return ThreadingHTTPServer((host, port), Handler)
