"""Dashboard-Server: laesst den Bot im Hintergrund laufen und liefert Chart + JSON."""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .bot import GeckoMiningBot

log = logging.getLogger("gecko_mining")
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")


class BotRunner:
    def __init__(self, bot: GeckoMiningBot):
        self.bot = bot
        self.lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def start(self) -> None:
        with self.lock:
            self.bot.seed_history()
            self.bot.step()
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _loop(self) -> None:
        while not self._stop.wait(self.bot.cfg.poll_seconds):
            with self.lock:
                try:
                    self.bot.step()
                except Exception:  # Bot darf das Dashboard nicht mitreissen
                    log.exception("Bot-Durchlauf fehlgeschlagen")

    def snapshot(self) -> dict:
        with self.lock:
            return self.bot.snapshot()


def make_handler(runner: BotRunner):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _static(self, name: str, content_type: str) -> None:
            with open(os.path.join(STATIC_DIR, name), "rb") as fh:
                self._send(200, fh.read(), content_type)

        def do_GET(self):  # noqa: N802 (http.server API)
            path = self.path.split("?", 1)[0]
            if path == "/api/state":
                self._send(200, json.dumps(runner.snapshot()).encode(), "application/json")
            elif path in ("/", "/index.html"):
                self._static("index.html", "text/html; charset=utf-8")
            elif path == "/candle-chart.js":
                self._static("candle-chart.js", "text/javascript; charset=utf-8")
            else:
                self._send(404, b"not found", "text/plain")

        def log_message(self, fmt, *args):
            log.debug("http: " + fmt, *args)

    return Handler


def serve(bot: GeckoMiningBot, host: str = "127.0.0.1", port: int = 8050) -> None:
    runner = BotRunner(bot)
    runner.start()
    httpd = ThreadingHTTPServer((host, port), make_handler(runner))
    log.info("Dashboard laeuft auf http://%s:%d", host, port)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        runner.stop()
        httpd.server_close()
