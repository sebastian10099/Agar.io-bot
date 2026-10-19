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


class InstallerAntTests(unittest.TestCase):
    def test_installer_ignores_apache_ant_and_downloads_the_cli(self):
        """Apache Ant on PATH must not count as the Anthropic CLI (seen on the macOS CI image)."""
        import os, tempfile, zipfile
        from pathlib import Path
        root = Path(__file__).parent.parent
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "home"; (home / "Desktop").mkdir(parents=True)
            bindir = Path(d) / "bin"; bindir.mkdir()
            (bindir / "ant").write_text("#!/bin/sh\necho 'Apache Ant(TM) version 1.10.15 compiled on August 25 2024'\n"); (bindir / "ant").chmod(0o755)
            (bindir / "open").write_text("#!/bin/sh\nexit 0\n"); (bindir / "open").chmod(0o755)
            z = Path(d) / "ant.zip"
            with zipfile.ZipFile(z, "w") as zf:
                zf.writestr("ant", "#!/bin/sh\necho 'ant version 1.42.0'\n")
            env = dict(os.environ, HOME=str(home), PATH=f"{bindir}:/usr/bin:/bin", NEW_TOKEN_BOT_ANT_ZIP=f"file://{z}")
            r = subprocess.run(["bash", str(root / "install-app.sh")], capture_output=True, text=True, timeout=120, env=env, stdin=subprocess.DEVNULL)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertNotIn("ist da", r.stdout)                          # Apache Ant did not count
            installed = home / "NewTokenBot" / "bin" / "ant"
            self.assertTrue(installed.is_file(), r.stdout)
            r2 = subprocess.run(["bash", str(root / "install-app.sh")], capture_output=True, text=True, timeout=120, env=env, stdin=subprocess.DEVNULL)
            self.assertIn(f"ist da: {installed}", r2.stdout)              # second run finds our own download


class LauncherScriptTests(unittest.TestCase):
    """launch.sh runs under set -u; with no arguments it must still get past the argument checks."""

    def run_sh(self, *args, home):
        import os
        from pathlib import Path
        root = Path(__file__).parent.parent
        env = dict(os.environ, NEW_TOKEN_BOT_HOME=home)
        # a dead proxy makes the HTTPS check fail the same way online and offline, so the
        # no-argument run stops after the argument handling instead of starting the real bot
        for k in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy"):
            env.pop(k, None)
        env["HTTPS_PROXY"] = env["https_proxy"] = "http://127.0.0.1:9"
        return subprocess.run(["bash", str(root / "launch.sh"), *args], capture_output=True, text=True, timeout=180, env=env, stdin=subprocess.DEVNULL)

    def test_with_and_without_arguments(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            r = self.run_sh("--demo", "--once", home=d)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('"seen"', r.stdout)
            r = self.run_sh(home=d)                     # what a double-click on "Start Trading Bot.command" does
            self.assertNotIn("unbound variable", r.stderr)
            self.assertIn("preflight", r.stdout)        # reached the Python check (offline here, so it may stop there)

    def test_scripts_use_the_bash32_safe_forms(self):
        from pathlib import Path
        root = Path(__file__).parent.parent
        for name in ("launch.sh", "Start Trading Bot.command", "Start Demo.command", "get.sh"):
            text = (root / name).read_text()
            code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
            self.assertNotIn('"$@"', code.replace('${1+"$@"}', ""), name)
            self.assertNotIn(" $* ", code, name)


if __name__ == "__main__":
    unittest.main()
