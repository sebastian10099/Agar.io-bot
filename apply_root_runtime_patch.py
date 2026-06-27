#!/usr/bin/env python3
"""Apply the non-Ollama local runtime patch to /root/local_agent.

Run from `/root/local_agent/agent_workspace` after pulling this workspace:

    python3 apply_root_runtime_patch.py

The script is idempotent and backs up every root file before changing it.
"""

from __future__ import annotations

import json
import py_compile
import shutil
import subprocess
import time
from pathlib import Path


WORKSPACE = Path(__file__).resolve().parent
ROOT = WORKSPACE.parent
REPORT = WORKSPACE / "root_runtime_patch_report.json"


OPENAI_COMPAT_BLOCK = r'''
    def _openai_compat_request(self, messages, force_json=True, model=None, base_url=None, api_key="", timeout=None):
        base = (base_url or self.cfg.get("openai_compatible_url") or self.cfg.get("llamacpp_url") or "").rstrip("/")
        if not base:
            raise ValueError("openai compatible base_url missing")
        if base.endswith("/v1"):
            url = base + "/chat/completions"
        else:
            url = base + "/v1/chat/completions"
        active_model = model or self.cfg.get("llamacpp_model") or self.cfg.get("local_fast_model") or self._model_name
        payload = {
            "model": active_model,
            "messages": list(messages),
            "stream": False,
            "temperature": self.cfg.get("temperature", 0.5),
        }
        if self.cfg.get("ollama_num_predict"):
            try:
                payload["max_tokens"] = int(self.cfg.get("ollama_num_predict"))
            except Exception:
                pass
        if force_json:
            payload["response_format"] = {"type": "json_object"}
        headers = {"Content-Type": "application/json"}
        if api_key:
            headers["Authorization"] = "Bearer " + api_key
        timeout = int(timeout or self.cfg.get("llamacpp_timeout_seconds", self.cfg.get("ollama_local_timeout_seconds", 30)))
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
            if self.cfg.get("local_fallback_to_cloud", True):
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
        if not cloud and (local_provider in {"llamacpp", "llama.cpp", "openai_compatible"} and local):
            return self._openai_compat_request(
                messages,
                force_json=force_json,
                model=model or self.cfg.get("llamacpp_model") or self.cfg.get("local_fast_model"),
                base_url=self.cfg.get("llamacpp_url", "http://127.0.0.1:8081/v1"),
                api_key=self.cfg.get("llamacpp_api_key", ""),
                timeout=self.cfg.get("llamacpp_timeout_seconds"),
            )
        if not cloud and main_provider in {"llamacpp", "llama.cpp", "openai_compatible"}:
            return self._openai_compat_request(
                messages,
                force_json=force_json,
                model=model or self.cfg.get("llamacpp_model") or self._model_name,
                base_url=self.cfg.get("llamacpp_url", "http://127.0.0.1:8081/v1"),
                api_key=self.cfg.get("llamacpp_api_key", ""),
                timeout=self.cfg.get("llamacpp_timeout_seconds"),
            )
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
    if "def _openai_compat_request(" not in text:
        marker = "    def _ollama_request(self, messages, force_json=True, model=None, local=False, cloud=False):\n"
        if marker not in text:
            return {"file": str(path), "ok": False, "message": "ollama_request marker not found"}
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
    if changed:
        path.write_text(text, encoding="utf-8")
        py_compile.compile(str(path), doraise=True)
    return {"file": str(path), "ok": True, "changed": changed, "backups": backups}


def patch_config() -> dict:
    path = ROOT / "config.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    before = json.dumps(data, sort_keys=True)
    data["local_ai_provider"] = "llamacpp"
    data["preferred_local_engine"] = "llamacpp"
    data["llamacpp_url"] = "http://127.0.0.1:8081/v1"
    data["llamacpp_model"] = data.get("llamacpp_model") or "Qwen2.5-7B-Instruct-Q4_K_M.gguf"
    data["llamacpp_timeout_seconds"] = int(data.get("llamacpp_timeout_seconds") or 25)
    data["local_fast_model"] = data["llamacpp_model"]
    data["ollama_fast_coder_model"] = data["llamacpp_model"]
    data["ollama_coder_models"] = ["qwen3-coder-next", "deepseek-v4-pro", data["llamacpp_model"]]
    routing = data.setdefault("model_routing", {})
    routing["fast_coder"] = data["llamacpp_model"]
    routing["backup_coder"] = data["llamacpp_model"]
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
        "ollama_unload": stop_ollama_model(),
        "selfdev_repair": run_selfdev_repair(),
        "github_adoption": run_github_adoption(),
    }
    REPORT.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(results, indent=2, ensure_ascii=False))
    return 0 if all(v.get("ok", False) for k, v in results.items() if isinstance(v, dict)) else 2


if __name__ == "__main__":
    raise SystemExit(main())
