import ssl
import subprocess
import unittest

from bot import preflight


class FakeRun:
    def __init__(self, rc=0, stderr=""):
        self.calls, self.rc, self.stderr = [], rc, stderr
    def __call__(self, cmd, **kw):
        self.calls.append(cmd)
        return subprocess.CompletedProcess(cmd, self.rc, stdout="", stderr=self.stderr)


class PreflightTests(unittest.TestCase):
    def test_https_ok_needs_no_pip(self):
        run = FakeRun()
        ok, why = preflight.ensure_https(fetch=lambda: {"ok": 1}, run=run)
        self.assertTrue(ok); self.assertEqual(run.calls, [])

    def test_tls_failure_installs_certifi_then_reprobes(self):
        state = {"n": 0}
        def fetch():
            state["n"] += 1
            if state["n"] == 1:
                raise ssl.SSLCertVerificationError("CERTIFICATE_VERIFY_FAILED")
            return {"ok": 1}
        run = FakeRun()
        ok, why = preflight.ensure_https(fetch=fetch, run=run)
        self.assertTrue(ok, why)
        self.assertEqual(len(run.calls), 1); self.assertIn("certifi", run.calls[0]); self.assertIn("--user", run.calls[0])
        self.assertEqual(state["n"], 2)

    def test_offline_is_not_a_certificate_problem(self):
        run = FakeRun()
        ok, why = preflight.ensure_https(fetch=lambda: (_ for _ in ()).throw(OSError("Tunnel connection failed: 403")), run=run)
        self.assertFalse(ok); self.assertIn("403", why); self.assertEqual(run.calls, [])

    def test_failed_pip_is_reported_not_raised(self):
        run = FakeRun(rc=1, stderr="No matching distribution")
        ok, why = preflight.ensure_https(fetch=lambda: (_ for _ in ()).throw(ssl.SSLError("CERTIFICATE_VERIFY_FAILED")), run=run)
        self.assertFalse(ok); self.assertIn("certifi-Installation fehlgeschlagen", why)
        run2 = FakeRun()
        def boom(cmd, **kw): raise subprocess.TimeoutExpired(cmd, 1)
        ok, why = preflight.ensure_https(fetch=lambda: (_ for _ in ()).throw(ssl.SSLError("x")), run=boom)
        self.assertFalse(ok)

    def test_sdk_install_path(self):
        seen = {"installed": False}
        def importer(name):
            if seen["installed"]:
                return type("M", (), {"__version__": "9.9.9"})
            raise ImportError(name)
        def run(cmd, **kw):
            seen["installed"] = True
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
        ok, why = preflight.ensure_sdk(importer=importer, run=run)
        self.assertTrue(ok); self.assertIn("9.9.9", why); self.assertIn("installiert", why)
        ok, why = preflight.ensure_sdk(importer=lambda n: type("M", (), {"__version__": "1.2.3"}), run=FakeRun())
        self.assertTrue(ok); self.assertIn("1.2.3", why)
        ok, why = preflight.ensure_sdk(importer=lambda n: (_ for _ in ()).throw(ImportError(n)), run=FakeRun(rc=1))
        self.assertFalse(ok); self.assertIn("KI-Modus bleibt aus", why)

    def test_main_demo_and_old_python(self):
        self.assertEqual(preflight.main(["--demo"]), 0)


if __name__ == "__main__":
    unittest.main()
