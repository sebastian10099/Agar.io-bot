import json
import unittest
from types import SimpleNamespace

from bot.ai import ClaudeAdvisor, _estimate_cost


class StubClient:
    """Mimics the SDK surface the advisor touches: client.beta.messages.create / client.messages.create."""
    def __init__(self, reply=None, stop_reason="end_turn", raise_beta=None, raise_all=None):
        self.calls = []
        self.reply, self.stop_reason, self.raise_beta, self.raise_all = reply, stop_reason, raise_beta, raise_all
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._beta_create))
        self.messages = SimpleNamespace(create=self._create)

    def _response(self):
        return SimpleNamespace(
            content=[SimpleNamespace(type="text", text=json.dumps(self.reply) if self.reply is not None else "nope")],
            stop_reason=self.stop_reason, stop_details=SimpleNamespace(category="cyber") if self.stop_reason == "refusal" else None,
            usage=SimpleNamespace(input_tokens=1200, output_tokens=150, cache_read_input_tokens=800, cache_creation_input_tokens=0),
            model="claude-opus-5-5")

    def _beta_create(self, **kw):
        self.calls.append(("beta", kw))
        if self.raise_all: raise self.raise_all
        if self.raise_beta: raise self.raise_beta
        return self._response()

    def _create(self, **kw):
        self.calls.append(("plain", kw))
        if self.raise_all: raise self.raise_all
        return self._response()


CFG = {"ai": {"mode": "advise", "model": "claude-opus-5-5", "effort": "medium", "max_calls_per_hour": 2, "min_confidence": 0.6}}
PAIR = {"symbol": "RUN", "chain": "solana", "age_min": 12, "price_usd": 0.0004, "liquidity_usd": 64000, "volume_m5": 18000,
        "buys_m5": 48, "sells_m5": 19, "change_m5": 22, "has_socials": True}
RULES = {"decision": "buy", "score": 64.4, "reasons": ["liquidity 7"]}


class AdvisorTests(unittest.TestCase):
    def test_structured_verdict_and_request_shape(self):
        client = StubClient(reply={"decision": "watch", "confidence": 0.55, "reasons": ["Kaufdruck lässt nach"], "risk_flags": ["Volumen ohne Liquidität"]})
        adv = ClaudeAdvisor(CFG, client=client)
        v = adv.judge(PAIR, {"score": 120, "danger": [], "warn": []}, RULES)
        self.assertEqual(v["decision"], "watch")
        self.assertAlmostEqual(v["confidence"], 0.55)
        self.assertEqual(v["reasons"], ["Kaufdruck lässt nach"])
        kind, kw = client.calls[0]
        self.assertEqual(kind, "beta")
        self.assertEqual(kw["model"], "claude-opus-5-5")
        self.assertEqual(kw["fallbacks"], "default")
        self.assertEqual(kw["output_config"]["format"]["type"], "json_schema")
        self.assertEqual(kw["output_config"]["effort"], "medium")
        self.assertIn("cache_control", kw["system"][0])
        self.assertIn("RUN", kw["messages"][0]["content"])
        self.assertNotIn("thinking", kw)                 # Opus 5.5: adaptive by default, never disabled
        self.assertGreater(adv.cost_total, 0)
        self.assertAlmostEqual(adv.cost_total, _estimate_cost("claude-opus-5-5", client._response().usage))

    def test_refusal_and_bad_json_return_none(self):
        adv = ClaudeAdvisor(CFG, client=StubClient(reply={"decision": "buy", "confidence": 1, "reasons": [], "risk_flags": []}, stop_reason="refusal"))
        self.assertIsNone(adv.judge(PAIR, None, RULES))
        self.assertIn("abgelehnt", adv.status()["reason"])
        adv = ClaudeAdvisor(CFG, client=StubClient(reply=None))
        self.assertIsNone(adv.judge(PAIR, None, RULES))

    def test_hourly_limit(self):
        client = StubClient(reply={"decision": "skip", "confidence": 0.9, "reasons": [], "risk_flags": []})
        adv = ClaudeAdvisor(CFG, client=client)
        self.assertIsNotNone(adv.judge(PAIR, None, RULES))
        self.assertIsNotNone(adv.judge(PAIR, None, RULES))
        self.assertIsNone(adv.judge(PAIR, None, RULES))
        self.assertEqual(len(client.calls), 2)
        self.assertIn("Stundenlimit", adv.status()["reason"])

    def test_fallback_parameter_rejected_then_plain_endpoint(self):
        err = Exception("fallbacks is not supported"); err.status_code = 400
        client = StubClient(reply={"decision": "buy", "confidence": 0.8, "reasons": ["ok"], "risk_flags": []}, raise_beta=err)
        adv = ClaudeAdvisor(CFG, client=client)
        v = adv.judge(PAIR, None, RULES)
        self.assertEqual(v["decision"], "buy")
        self.assertEqual([k for k, _ in client.calls], ["beta", "plain"])
        adv.judge(PAIR, None, RULES)
        self.assertEqual(client.calls[-1][0], "plain")   # remembered, no second beta attempt

    def test_off_mode_never_calls(self):
        client = StubClient(reply={"decision": "buy", "confidence": 1, "reasons": [], "risk_flags": []})
        adv = ClaudeAdvisor({"ai": {"mode": "off"}}, client=client)
        self.assertIsNone(adv.judge(PAIR, None, RULES))
        self.assertEqual(client.calls, [])

    def test_sdk_errors_are_described(self):
        import anthropic
        import httpx2 as httpx
        logs = []
        resp = httpx.Response(401, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"))
        client = StubClient(raise_all=anthropic.AuthenticationError("bad key", response=resp, body=None))
        adv = ClaudeAdvisor(CFG, log=lambda l, m: logs.append(m), client=client)
        self.assertIsNone(adv.judge(PAIR, None, RULES))
        self.assertIn("401", adv.status()["reason"])
        self.assertTrue(logs and logs[0].startswith("KI:"))


if __name__ == "__main__":
    unittest.main()


class LoginTests(unittest.TestCase):
    def test_profile_detection_and_login_paths(self):
        import os, tempfile
        from unittest import mock
        from bot import ai
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {"ANTHROPIC_CONFIG_DIR": d}, clear=False):
            os.environ.pop("ANTHROPIC_API_KEY", None); os.environ.pop("ANTHROPIC_AUTH_TOKEN", None)
            with mock.patch.object(ai, "keychain_key", return_value=""):
                self.assertFalse(ai.has_profile())
                self.assertEqual(ai.credential_source(), "none")
                with mock.patch.object(ai, "ant_path", return_value=""):
                    r = ai.start_login()
                    self.assertFalse(r["ok"]); self.assertIn("brew install", r["install"])
                calls = []
                with mock.patch.object(ai, "ant_path", return_value="/opt/homebrew/bin/ant"):
                    r = ai.start_login(runner=calls.append)
                    self.assertTrue(r["ok"]); self.assertFalse(r["already"]); self.assertEqual(calls, [["/opt/homebrew/bin/ant", "auth", "login"]])
                os.makedirs(os.path.join(d, "credentials")); open(os.path.join(d, "credentials", "default.json"), "w").write("{}")
                self.assertTrue(ai.has_profile()); self.assertEqual(ai.credential_source(), "profile")
                self.assertTrue(ai.start_login(runner=calls.append)["already"]); self.assertEqual(len(calls), 1)


class AntPathTests(unittest.TestCase):
    def test_ant_in_newtokenbot_bin_is_found(self):
        import os, tempfile
        from unittest import mock
        from bot import ai
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {"HOME": d, "PATH": "/nonexistent"}):
            self.assertEqual(ai.ant_path(), "")
            os.makedirs(os.path.join(d, "NewTokenBot", "bin"))
            exe = os.path.join(d, "NewTokenBot", "bin", "ant")
            open(exe, "w").write("#!/bin/sh\n"); os.chmod(exe, 0o755)
            self.assertEqual(ai.ant_path(), exe)
