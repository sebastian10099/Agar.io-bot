"""Tests fuer die BeamNet-Werkstatt: Aufgaben, Aenderungsbloecke und ein ganzer Durchlauf mit nachgebauter KI.

Aufruf: python3 BeamNet/werkstatt/test_werkstatt.py
"""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import werkstatt as W  # noqa: E402


class FakeOllama(http.server.BaseHTTPRequestHandler):
    answers = []          # Antworten der Reihe nach
    requests = []

    def log_message(self, *a):
        pass

    def _send(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/tags":
            self._send({"models": [{"name": "llama3:8b"}, {"name": "qwen3-coder:30b"}]})
        else:
            self.send_error(404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeOllama.requests.append(body)
        answer = FakeOllama.answers.pop(0) if FakeOllama.answers else "nichts"
        self._send({"message": {"role": "assistant", "content": answer}})


def sh(*cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True, encoding="utf-8").stdout


class Edits(unittest.TestCase):
    def test_parse_task(self):
        t = W.parse_task("Branch: lokal/x\nDateien: a.lua b.lua\nTest: bash -n a\n---\nMach was.\n")
        self.assertEqual(t["branch"], "lokal/x")
        self.assertEqual(t["files"], ["a.lua", "b.lua"])
        self.assertEqual(t["test"], "bash -n a")
        self.assertEqual(t["body"], "Mach was.")
        self.assertIsNone(W.valid_task(t))

    def test_unsafe_task(self):
        self.assertIn("Branch", W.valid_task(W.parse_task("Branch: main\nDateien: a\n---\nx")))
        self.assertIn("unsicher", W.valid_task(W.parse_task("Branch: lokal/x\nDateien: ../etc/passwd\n---\nx")))
        self.assertIn("unsicher", W.valid_task(W.parse_task("Branch: lokal/x\nDateien: /etc/passwd\n---\nx")))

    def test_parse_edits_with_fences(self):
        answer = ("Hier:\n\nsrc/a.lua\n```lua\n<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 2\n>>>>>>> REPLACE\n```\n\n"
                  "**src/b.lua**\n<<<<<<< SEARCH\n=======\nneu\n>>>>>>> REPLACE\n")
        e = W.parse_edits(answer)
        self.assertEqual([p for p, _, _ in e], ["src/a.lua", "src/b.lua"])
        self.assertEqual(e[0][1], "local x = 1\n")
        self.assertEqual(e[1][1], "")

    def test_apply_edit(self):
        self.assertEqual(W.apply_edit("a\nb\nc\n", "b\n", "B\n"), "a\nB\nc\n")
        self.assertEqual(W.apply_edit("a  \nb\n", "a\nb\n", "x\n"), "x\n")          # Leerzeichen am Zeilenende
        self.assertIsNone(W.apply_edit("a\nb\n", "zz\n", "x\n"))
        self.assertEqual(W.apply_edit("", "", "neu\n"), "neu\n")

    def test_only_allowed_files(self):
        with tempfile.TemporaryDirectory() as d:
            task = {"files": ["a.txt"]}
            probs = W.apply_edits(d, task, [("../b.txt", "", "x")])
            self.assertTrue(probs and "nicht geändert" in probs[0])
            self.assertFalse(os.path.exists(os.path.join(os.path.dirname(d), "b.txt")))

    def test_builtin_plugin_tests(self):
        import locale
        before = locale.setlocale(locale.LC_CTYPE)
        repo = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        ok, out = W.run_test(repo, "python3 BeamNet/tests/run_lua_tests.py")
        self.assertTrue(ok, out[-2000:])
        self.assertIn("ALLES GRÜN", out)
        # Die Spracheinstellung ist danach wieder wie vorher (sonst scheitern Git-Ausgaben mit Umlauten).
        self.assertEqual(locale.setlocale(locale.LC_CTYPE), before)

    def test_pick_model(self):
        self.assertEqual(W.pick_model(["llama3:8b", "qwen3-coder:30b"]), "qwen3-coder:30b")
        self.assertEqual(W.pick_model(["llama3:8b"]), "llama3:8b")
        self.assertEqual(W.pick_model(["x"], "mein:modell"), "mein:modell")


class FullRun(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        W.HOME = os.path.join(t, "home")
        W.CONFIG, W.STATE, W.LOG = (os.path.join(W.HOME, n) for n in ("einstellungen.json", "erledigt.json", "w.log"))
        # Ursprungs-Projekt mit einer Aufgabe und einer Datei.
        self.origin = os.path.join(t, "origin.git")
        sh("git", "init", "-q", "--bare", self.origin)
        work = os.path.join(t, "work")
        sh("git", "init", "-q", "-b", W.BASE, work)
        sh("git", "config", "user.email", "t@t", cwd=work)
        sh("git", "config", "user.name", "t", cwd=work)
        os.makedirs(os.path.join(work, W.TASK_DIR))
        with open(os.path.join(work, "zahl.txt"), "w") as f:
            f.write("wert = 1\n")
        with open(os.path.join(work, W.TASK_DIR, "01-zahl.md"), "w") as f:
            f.write("Branch: lokal/zahl\nDateien: zahl.txt\nTest: grep -q 'wert = 2' zahl.txt\n---\nSetze den Wert auf 2.\n")
        sh("git", "add", "-A", cwd=work)
        sh("git", "commit", "-q", "-m", "start", cwd=work)
        sh("git", "remote", "add", "origin", self.origin, cwd=work)
        sh("git", "push", "-q", "origin", W.BASE, cwd=work)
        self.clone = os.path.join(t, "clone")
        sh("git", "clone", "-q", "--branch", W.BASE, self.origin, self.clone)
        # Nachgebaute KI.
        self.server = http.server.HTTPServer(("127.0.0.1", 0), FakeOllama)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        FakeOllama.requests = []

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def run_once(self):
        return W.main(["--url", self.url, "--projekt", self.clone, "--einmal"])

    def test_retry_then_green_and_push(self):
        FakeOllama.answers = [
            "zahl.txt\n<<<<<<< SEARCH\nwert = 9\n=======\nwert = 2\n>>>>>>> REPLACE\n",      # passt nicht
            "zahl.txt\n<<<<<<< SEARCH\nwert = 1\n=======\nwert = 3\n>>>>>>> REPLACE\n",      # Test rot
            "zahl.txt\n<<<<<<< SEARCH\nwert = 1\n=======\nwert = 2\n>>>>>>> REPLACE\n",      # gruen
        ]
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(len(FakeOllama.requests), 3)
        self.assertEqual(FakeOllama.requests[0]["model"], "qwen3-coder:30b")
        self.assertEqual(FakeOllama.requests[0]["options"]["num_ctx"], 65536)
        self.assertIn("SEARCH-Block nicht gefunden", FakeOllama.requests[1]["messages"][-1]["content"])
        content = sh("git", "--git-dir", self.origin, "show", "lokal/zahl:zahl.txt")
        self.assertEqual(content, "wert = 2\n")
        msg = sh("git", "--git-dir", self.origin, "log", "-1", "--format=%B", "lokal/zahl")
        self.assertIn("Schnelltest grün", msg)
        # Zweiter Durchlauf: Aufgabe ist erledigt, die KI wird nicht erneut gefragt.
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(len(FakeOllama.requests), 3)

    def test_red_is_pushed_and_marked(self):
        FakeOllama.answers = ["zahl.txt\n<<<<<<< SEARCH\nwert = 1\n=======\nwert = 7\n>>>>>>> REPLACE\n"] * 3
        self.assertEqual(self.run_once(), 0)
        msg = sh("git", "--git-dir", self.origin, "log", "-1", "--format=%B", "lokal/zahl")
        self.assertIn("Schnelltest ROT nach 3 Versuchen", msg)

    def test_no_backend(self):
        self.assertEqual(W.main(["--url", "http://127.0.0.1:9", "--projekt", self.clone, "--einmal"]), 3)


if __name__ == "__main__":
    unittest.main(verbosity=1)
