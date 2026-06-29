#!/usr/bin/env python3
"""Apply the OpenAI-compatible runtime patch to /root/local_agent.

Run from `/root/local_agent/agent_workspace` after pulling this workspace:

    python3 apply_root_runtime_patch.py

The script is idempotent and backs up every root file before changing it.
"""

from __future__ import annotations

import json
import os
import py_compile
import shutil
import subprocess
import time
from pathlib import Path


WORKSPACE = Path(__file__).resolve().parent
ROOT = WORKSPACE.parent
REPORT = WORKSPACE / "root_runtime_patch_report.json"
ROOT_REPORT = ROOT / "root_runtime_patch_report.json"


OPENAI_CHECK_BLOCK = r'''
    def _check_openai_compatible(self):
        base = (
            self.cfg.get("openai_compatible_url")
            or self.cfg.get("openai_base_url")
            or self.cfg.get("llamacpp_url")
            or ""
        ).rstrip("/")
        model = self._model_name
        if not base:
            return False, "OpenAI-kompatibler Endpoint fehlt: openai_compatible_url setzen."
        if not model:
            return False, "OpenAI-kompatibles Modell fehlt: openai_compatible_model setzen."
        if self.cfg.get("openai_compatible_require_key", True):
            key = (
                self.cfg.get("openai_compatible_api_key")
                or self.cfg.get("openai_api_key")
                or self.cfg.get("api_key")
                or os.environ.get("OPENAI_API_KEY", "")
            )
            if not key and "127.0.0.1" not in base and "localhost" not in base:
                return False, "OpenAI-kompatibler API-Key fehlt."
        if self.cfg.get("openai_compatible_check_models", False):
            headers = {}
            key = (
                self.cfg.get("openai_compatible_api_key")
                or self.cfg.get("openai_api_key")
                or self.cfg.get("api_key")
                or os.environ.get("OPENAI_API_KEY", "")
            )
            if key:
                headers["Authorization"] = "Bearer " + key
            url = base + ("/models" if base.endswith("/v1") else "/v1/models")
            try:
                r = requests.get(url, headers=headers, timeout=10)
                r.raise_for_status()
            except Exception as e:
                return False, f"OpenAI-kompatibler Endpoint nicht erreichbar ({base}): {e}"
        return True, f"OpenAI-kompatibel OK. Modell '{model}' ueber {base}."

'''


OPENAI_COMPAT_BLOCK = r'''
    def _openai_compat_request(self, messages, force_json=True, model=None, base_url=None, api_key="", timeout=None):
        base = (
            base_url
            or self.cfg.get("openai_compatible_url")
            or self.cfg.get("openai_base_url")
            or self.cfg.get("llamacpp_url")
            or ""
        ).rstrip("/")
        if not base:
            raise ValueError("openai compatible base_url missing")
        if base.endswith("/v1"):
            url = base + "/chat/completions"
        else:
            url = base + "/v1/chat/completions"
        active_model = (
            model
            or self.cfg.get("openai_compatible_model")
            or self.cfg.get("glm_model")
            or self.cfg.get("llamacpp_model")
            or self.cfg.get("local_fast_model")
            or self._model_name
        )
        payload = {
            "model": active_model,
            "messages": list(messages),
            "stream": False,
            "temperature": self.cfg.get("temperature", 0.5),
        }
        max_tokens = (
            self.cfg.get("openai_compatible_max_tokens")
            or self.cfg.get("ollama_num_predict")
        )
        if max_tokens:
            try:
                payload["max_tokens"] = int(max_tokens)
            except Exception:
                pass
        if force_json:
            payload["response_format"] = {"type": "json_object"}
        headers = {"Content-Type": "application/json"}
        if not api_key:
            api_key = (
                self.cfg.get("openai_compatible_api_key")
                or self.cfg.get("openai_api_key")
                or self.cfg.get("api_key")
                or os.environ.get("OPENAI_API_KEY", "")
            )
        if api_key:
            headers["Authorization"] = "Bearer " + api_key
        timeout = int(timeout or self.cfg.get("openai_compatible_timeout_seconds", self.cfg.get("llamacpp_timeout_seconds", self.cfg.get("ollama_local_timeout_seconds", 30))))
        try:
            r = requests.post(url, json=payload, headers=headers, timeout=timeout)
            if r.status_code >= 400 and force_json:
                payload.pop("response_format", None)
                r = requests.post(url, json=payload, headers=headers, timeout=timeout)
            r.raise_for_status()
            data = r.json()
            choices = data.get("choices") or []
            if choices:
                return ((choices[0].get("message") or {}).get("content") or "").strip()
            return ""
        except Exception:
            if self.cfg.get("local_fallback_to_cloud", False):
                fallback_model = self.cfg.get("cloud_json_fallback_model") if force_json else self.cfg.get("ollama_coder_model")
                return self._ollama_request(
                    messages,
                    force_json=force_json,
                    model=fallback_model or self.cfg.get("ollama_model"),
                    local=False,
                    cloud=True,
                )
            raise

'''


OLLAMA_LOCAL_ROUTER = '''        local_provider = str(self.cfg.get("local_ai_provider") or self.cfg.get("preferred_local_engine") or "").lower()
        main_provider = str(self.cfg.get("provider") or "").lower()
        openai_providers = {"llamacpp", "llama.cpp", "openai", "openai_compatible", "openai-compatible", "openai_compat", "glm", "zhipu", "kimi", "moonshot"}
        if not cloud and (local_provider in openai_providers and local):
            return self._openai_compat_request(
                messages,
                force_json=force_json,
                model=model or self.cfg.get("openai_compatible_fast_model") or self.cfg.get("kimi_code_model") or self.cfg.get("local_fast_model"),
                base_url=self.cfg.get("openai_compatible_url") or self.cfg.get("llamacpp_url", "http://127.0.0.1:8081/v1"),
                api_key=self.cfg.get("openai_compatible_api_key") or self.cfg.get("llamacpp_api_key", ""),
                timeout=self.cfg.get("openai_compatible_timeout_seconds") or self.cfg.get("llamacpp_timeout_seconds"),
            )
        if not cloud and main_provider in openai_providers:
            return self._openai_compat_request(
                messages,
                force_json=force_json,
                model=model or self.cfg.get("openai_compatible_model") or self.cfg.get("glm_model") or self._model_name,
                base_url=self.cfg.get("openai_compatible_url") or self.cfg.get("llamacpp_url", "http://127.0.0.1:8081/v1"),
                api_key=self.cfg.get("openai_compatible_api_key") or self.cfg.get("llamacpp_api_key", ""),
                timeout=self.cfg.get("openai_compatible_timeout_seconds") or self.cfg.get("llamacpp_timeout_seconds"),
            )
'''


RUN_GOAL_CHECK_OLD = '''    def _run_goal_ollama(self, goal):
        ok, msg = self._check_ollama()
'''


RUN_GOAL_CHECK_OPENAI = '''    def _run_goal_ollama(self, goal):
        if str(self.cfg.get("provider", "")).lower() in {"openai", "openai_compatible", "openai-compatible", "openai_compat", "glm", "zhipu", "kimi", "moonshot"}:
            ok, msg = self._check_openai_compatible()
        else:
            ok, msg = self._check_ollama()
'''


OLLAMA_BUDGET_BLOCK = '''        if self.cfg.get("ollama_budget_mode", False):
            max_chars = int(self.cfg.get("ollama_max_prompt_chars", 12000) or 12000)
            max_msg_chars = int(self.cfg.get("ollama_max_message_chars", 3500) or 3500)
            trimmed = []
            remaining = max_chars
            for msg in reversed(request_messages):
                item = dict(msg)
                content = str(item.get("content", ""))
                if len(content) > max_msg_chars:
                    content = content[:1200] + "\\n...[gekuerzt fuer Ollama-Budget]...\\n" + content[-(max_msg_chars - 1235):]
                if len(content) > remaining and trimmed:
                    continue
                if len(content) > remaining:
                    content = content[-remaining:]
                item["content"] = content
                trimmed.append(item)
                remaining -= len(content)
                if remaining <= 0:
                    break
            request_messages = list(reversed(trimmed)) or request_messages[-2:]
'''


OLLAMA_OPTIONS_OLD = '''        options = {"temperature": self.cfg.get("temperature", 0.5)}
        if self.cfg.get("ollama_num_predict"):
            try:
                options["num_predict"] = int(self.cfg.get("ollama_num_predict"))
            except Exception:
                pass
'''


OLLAMA_OPTIONS_BUDGET = '''        options = {"temperature": self.cfg.get("temperature", 0.5)}
        if self.cfg.get("ollama_num_ctx"):
            try:
                options["num_ctx"] = int(self.cfg.get("ollama_num_ctx"))
            except Exception:
                pass
        predict_key = "ollama_num_predict"
        if force_json and self.cfg.get("ollama_json_num_predict"):
            predict_key = "ollama_json_num_predict"
        elif local and self.cfg.get("ollama_local_num_predict"):
            predict_key = "ollama_local_num_predict"
        elif cloud and self.cfg.get("ollama_cloud_num_predict"):
            predict_key = "ollama_cloud_num_predict"
        if self.cfg.get(predict_key):
            try:
                options["num_predict"] = int(self.cfg.get(predict_key))
            except Exception:
                pass
'''


def utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def backup(path: Path) -> str:
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    target = path.with_suffix(path.suffix + f".bak-runtime-{stamp}")
    shutil.copy2(path, target)
    return str(target)


def patch_brain() -> dict:
    path = ROOT / "brain.py"
    text = path.read_text(encoding="utf-8")
    changed = False
    backups = []
    if "def _check_openai_compatible(" not in text:
        marker = "    def _openai_compat_request("
        if marker not in text:
            marker = "    def _ollama_request(self, messages, force_json=True, model=None, local=False, cloud=False):\n"
            if marker not in text:
                return {"file": str(path), "ok": False, "message": "openai check marker not found"}
            if not backups:
                backups.append(backup(path))
            text = text.replace(marker, OPENAI_CHECK_BLOCK + marker, 1)
        else:
            if not backups:
                backups.append(backup(path))
            text = text.replace(marker, OPENAI_CHECK_BLOCK + marker, 1)
        changed = True
    if "def _openai_compat_request(" not in text:
        marker = "    def _ollama_request(self, messages, force_json=True, model=None, local=False, cloud=False):\n"
        if marker not in text:
            return {"file": str(path), "ok": False, "message": "ollama_request marker not found"}
        if not backups:
            backups.append(backup(path))
        text = text.replace(marker, OPENAI_COMPAT_BLOCK + marker, 1)
        changed = True
    router_marker = "        # local=True -> lokales Ollama; cloud=True -> Ollama-Cloud (Bearer-Key); sonst ollama_url.\n"
    if "local_ai_provider" not in text[text.find("def _ollama_request("):text.find("def _parse_json", text.find("def _ollama_request("))]:
        if router_marker not in text:
            router_marker = "        # local=True -> lokaler Provider; cloud=True -> Ollama-Cloud (Bearer-Key); sonst ollama_url.\n"
        if router_marker not in text:
            return {"file": str(path), "ok": False, "message": "local router marker not found"}
        if not backups:
            backups.append(backup(path))
        text = text.replace(router_marker, router_marker + OLLAMA_LOCAL_ROUTER, 1)
        changed = True
    budget_marker = "        if self.cfg.get(\"ollama_disable_thinking\", False) and str(active_model).startswith(\"qwen3\"):\n"
    section_start = text.find("def _ollama_request(")
    section_end = text.find("def _parse_json", section_start)
    section = text[section_start:section_end]
    if "ollama_budget_mode" not in section:
        if budget_marker not in text:
            return {"file": str(path), "ok": False, "message": "ollama budget marker not found"}
        if not backups:
            backups.append(backup(path))
        text = text.replace(budget_marker, OLLAMA_BUDGET_BLOCK + budget_marker, 1)
        changed = True
    section_start = text.find("def _ollama_request(")
    section_end = text.find("def _parse_json", section_start)
    section = text[section_start:section_end]
    if "ollama_json_num_predict" not in section and OLLAMA_OPTIONS_OLD in text:
        if not backups:
            backups.append(backup(path))
        text = text.replace(OLLAMA_OPTIONS_OLD, OLLAMA_OPTIONS_BUDGET, 1)
        changed = True
    if '"keep_alive"' not in section:
        payload_marker = '''        if force_json:
            payload["format"] = "json"
'''
        keep_alive_block = '''        if self.cfg.get("ollama_keep_alive"):
            payload["keep_alive"] = str(self.cfg.get("ollama_keep_alive"))
'''
        if payload_marker in text:
            if not backups:
                backups.append(backup(path))
            text = text.replace(payload_marker, keep_alive_block + payload_marker, 1)
            changed = True
    if RUN_GOAL_CHECK_OLD in text:
        if not backups:
            backups.append(backup(path))
        text = text.replace(RUN_GOAL_CHECK_OLD, RUN_GOAL_CHECK_OPENAI, 1)
        changed = True
    if changed:
        path.write_text(text, encoding="utf-8")
        py_compile.compile(str(path), doraise=True)
    return {"file": str(path), "ok": True, "changed": changed, "backups": backups}


def patch_config() -> dict:
    path = ROOT / "config.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    before = json.dumps(data, sort_keys=True)
    data["provider"] = "openai_compatible"
    data["openai_compatible_url"] = data.get("openai_compatible_url") or os.environ.get("OPENAI_COMPATIBLE_BASE_URL", "") or os.environ.get("OPENAI_BASE_URL", "")
    data["openai_compatible_base_url_env"] = data.get("openai_compatible_base_url_env") or "OPENAI_COMPATIBLE_BASE_URL"
    data["openai_compatible_api_key_env"] = data.get("openai_compatible_api_key_env") or "OPENAI_API_KEY"
    data["openai_compatible_model"] = "glm-5.2"
    data["openai_compatible_fast_model"] = "kimi-2.7-code"
    data["openai_compatible_coder_model"] = "kimi-2.7-code"
    data["openai_compatible_reviewer_model"] = "glm-5.2"
    data["openai_compatible_planner_model"] = "glm-5.2"
    data["openai_compatible_timeout_seconds"] = int(data.get("openai_compatible_timeout_seconds") or 90)
    data["openai_compatible_max_tokens"] = int(data.get("openai_compatible_max_tokens") or 900)
    data["openai_compatible_check_models"] = bool(data.get("openai_compatible_check_models", False))
    data["openai_compatible_require_key"] = bool(data.get("openai_compatible_require_key", True))
    data["glm_model"] = "glm-5.2"
    data["kimi_code_model"] = "kimi-2.7-code"
    data["local_ai_provider"] = "openai_compatible"
    data["preferred_local_engine"] = "openai_compatible"
    data["use_local_fast"] = True
    data["llamacpp_url"] = "http://127.0.0.1:8081/v1"
    data["llamacpp_model"] = data.get("llamacpp_model") or "Qwen2.5-7B-Instruct-Q4_K_M.gguf"
    data["llamacpp_timeout_seconds"] = int(data.get("llamacpp_timeout_seconds") or 25)
    data["local_fast_model"] = "kimi-2.7-code"
    data["ollama_budget_mode"] = True
    data["ollama_budget_profile"] = "sparsam"
    data["ollama_num_ctx"] = int(data.get("ollama_num_ctx") or 2048)
    data["ollama_num_predict"] = min(int(data.get("ollama_num_predict") or 256), 256)
    data["ollama_json_num_predict"] = int(data.get("ollama_json_num_predict") or 220)
    data["ollama_cloud_num_predict"] = int(data.get("ollama_cloud_num_predict") or 320)
    data["ollama_local_num_predict"] = int(data.get("ollama_local_num_predict") or 160)
    data["ollama_max_prompt_chars"] = int(data.get("ollama_max_prompt_chars") or 12000)
    data["ollama_max_message_chars"] = int(data.get("ollama_max_message_chars") or 3500)
    data["ollama_keep_alive"] = data.get("ollama_keep_alive") or "2m"
    data["ollama_model"] = "glm-5.2"
    data["ollama_strategist_model"] = "glm-5.2"
    data["ollama_coder_model"] = "kimi-2.7-code"
    data["ollama_reviewer_model"] = "glm-5.2"
    data["ollama_fast_coder_model"] = "kimi-2.7-code"
    data["ollama_strong_coder_model"] = "kimi-2.7-code"
    data["ollama_cloud_coder_model"] = "kimi-2.7-code"
    data["ollama_coder_models"] = ["kimi-2.7-code", "glm-5.2"]
    data["ollama_reviewer_models"] = ["glm-5.2", "kimi-2.7-code"]
    routing = data.setdefault("model_routing", {})
    routing["main_agent"] = "glm-5.2"
    routing["strategist"] = "glm-5.2"
    routing["fast_coder"] = "kimi-2.7-code"
    routing["backup_coder"] = "glm-5.2"
    routing["cloud_coder"] = "kimi-2.7-code"
    routing["reviewer"] = "glm-5.2"
    routing["hermes_meta"] = "glm-5.2"
    data["strategy_mode"] = "balanced"
    data["allow_external_code_reuse"] = True
    data["external_code_policy"] = "allowed_with_source_license_stage_validate_promote_test_rollback"
    data.setdefault("external_code_priority_sources", [
        "openclaw/openclaw",
        "paperclipai/paperclip",
        "agencyenterprise/paperclip-ai",
        "snarktank/antfarm",
        "mergisi/awesome-openclaw-agents",
        "slowmist/openclaw-security-practice-guide",
    ])
    after = json.dumps(data, sort_keys=True)
    backups = []
    if before != after:
        backups.append(backup(path))
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        json.loads(path.read_text(encoding="utf-8"))
    return {"file": str(path), "ok": True, "changed": before != after, "backups": backups}


def stop_ollama_model() -> dict:
    # Best effort: this unloads the CPU-burning model process without disabling the service.
    proc = subprocess.run(["bash", "-lc", "command -v ollama >/dev/null && ollama stop qwen2.5:3b || true"], capture_output=True, text=True, timeout=30)
    return {
        "ok": proc.returncode == 0,
        "stdout": proc.stdout.strip()[-500:],
        "stderr": proc.stderr.strip()[-500:],
    }


def install_root_auto_sync() -> dict:
    src = WORKSPACE / "github_auto_sync.sh"
    dst = ROOT / "github_auto_sync.sh"
    if not src.exists():
        return {"ok": False, "message": "github_auto_sync.sh missing"}
    backups = []
    changed = True
    if dst.exists():
        try:
            changed = src.read_text(encoding="utf-8") != dst.read_text(encoding="utf-8")
        except Exception:
            changed = True
    if changed:
        if dst.exists():
            backups.append(backup(dst))
        shutil.copy2(src, dst)
        dst.chmod(0o755)
    return {"ok": True, "changed": changed, "file": str(dst), "backups": backups}


def run_selfdev_repair() -> dict:
    tool = WORKSPACE / "selfdev_repair.py"
    if not tool.exists():
        return {"ok": False, "message": "selfdev_repair.py missing"}
    proc = subprocess.run(["python3", str(tool)], cwd=str(WORKSPACE), capture_output=True, text=True, timeout=60)
    return {"ok": proc.returncode == 0, "returncode": proc.returncode, "stdout": proc.stdout[-2000:], "stderr": proc.stderr[-1000:]}


def run_github_adoption() -> dict:
    tool = WORKSPACE / "github_adoption_engine.py"
    if not tool.exists():
        return {"ok": False, "message": "github_adoption_engine.py missing"}
    proc = subprocess.run(
        ["python3", str(tool), "--limit", "2"],
        cwd=str(WORKSPACE),
        capture_output=True,
        text=True,
        timeout=180,
    )
    report = WORKSPACE / "github_adoption_report.json"
    summary = {}
    if report.exists():
        try:
            data = json.loads(report.read_text(encoding="utf-8"))
            summary = {
                "count": data.get("count", 0),
                "errors": data.get("errors", [])[:3],
                "repos": [
                    {
                        "repo": row.get("repo"),
                        "license": row.get("license"),
                        "files": len(row.get("files", [])),
                        "ready": sum(1 for f in row.get("files", []) if f.get("safe_code_intake_command")),
                    }
                    for row in data.get("results", [])[:5]
                ],
            }
        except Exception as exc:
            summary = {"report_error": str(exc)[:300]}
    return {
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
        "summary": summary,
        "stdout": proc.stdout[-2000:],
        "stderr": proc.stderr[-1000:],
    }


def main() -> int:
    results = {
        "checked_at": utc(),
        "brain": patch_brain(),
        "config": patch_config(),
        "root_auto_sync": install_root_auto_sync(),
        "ollama_unload": stop_ollama_model(),
        "selfdev_repair": run_selfdev_repair(),
        "github_adoption": run_github_adoption(),
    }
    REPORT.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
    ROOT_REPORT.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(results, indent=2, ensure_ascii=False))
    return 0 if all(v.get("ok", False) for k, v in results.items() if isinstance(v, dict)) else 2


if __name__ == "__main__":
    raise SystemExit(main())
