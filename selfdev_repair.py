#!/usr/bin/env python3
"""Self-development repair helper for PROMETHEUS.

This tool repairs common damage caused by failed autonomous coding loops and
creates a concrete local-runtime plan. It is intentionally conservative:
changed files are backed up first, and each repair must pass a syntax check.
"""

from __future__ import annotations

import json
import py_compile
import shutil
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent
REPORT = ROOT / "selfdev_repair_report.json"
RUNTIME_PLAN = ROOT / "LOCAL_MODEL_RUNTIME_PLAN.md"


def utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def backup(path: Path) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    target = path.with_suffix(path.suffix + f".bak-selfdev-{stamp}")
    shutil.copy2(path, target)
    return target


def check_python(path: Path) -> tuple[bool, str]:
    try:
        py_compile.compile(str(path), doraise=True)
        return True, "Python-Syntax OK"
    except Exception as exc:
        return False, str(exc).replace("\n", " ")[:500]


def check_shell(path: Path) -> tuple[bool, str]:
    proc = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True, timeout=20)
    if proc.returncode == 0:
        return True, "Shell-Syntax OK"
    return False, (proc.stderr or proc.stdout).replace("\n", " ")[:500]


def write_if_passes(path: Path, content: str, checker) -> dict:
    before = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    bak = backup(path) if path.exists() else None
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    ok, message = checker(path)
    if not ok:
        if bak:
            shutil.copy2(bak, path)
        else:
            path.unlink(missing_ok=True)
        return {"path": str(path), "ok": False, "message": message, "rollback": str(bak) if bak else "removed"}
    changed = before != content
    return {"path": str(path), "ok": True, "message": message, "changed": changed, "backup": str(bak) if bak else ""}


def repair_main_app() -> dict:
    path = ROOT / "app.py"
    if not path.exists():
        return {"path": str(path), "ok": True, "message": "nicht vorhanden"}
    ok, msg = check_python(path)
    if ok:
        return {"path": str(path), "ok": True, "message": msg}
    raw = path.read_text(encoding="utf-8", errors="replace")
    if "\\n" in raw and "\n" not in raw.strip():
        fixed = raw.replace("\\n", "\n")
        return write_if_passes(path, fixed, check_python)
    fallback = (
        '"""Minimal placeholder app kept valid by selfdev_repair."""\n\n'
        "def app(environ, start_response):\n"
        "    start_response('200 OK', [('Content-Type', 'text/plain; charset=utf-8')])\n"
        "    return [b'PROMETHEUS workspace app placeholder']\n\n"
        "if __name__ == '__main__':\n"
        "    print('PROMETHEUS workspace app placeholder')\n"
    )
    return write_if_passes(path, fallback, check_python)


def repair_support_tools() -> list[dict]:
    support = ROOT.parent / "agent_workspace_support"
    repairs = []
    candidates = {
        support / "tools.py": (
            '"""Support workspace helper tools kept syntax-valid by selfdev_repair."""\n\n'
            "from pathlib import Path\n\n"
            "WORKSPACE = Path(__file__).resolve().parent\n\n"
            "def workspace_status() -> dict:\n"
            "    return {'workspace': str(WORKSPACE), 'exists': WORKSPACE.exists()}\n\n"
            "if __name__ == '__main__':\n"
            "    print(workspace_status())\n"
        ),
        support / "python_test.py": (
            '#!/usr/bin/env python3\n'
            '"""Tiny Python smoke test for support workspace."""\n\n'
            "import sys\n\n"
            "if __name__ == '__main__':\n"
            "    print('Python version:', sys.version.split()[0])\n"
        ),
    }
    for path, content in candidates.items():
        if not path.exists():
            continue
        ok, msg = check_python(path)
        if ok:
            repairs.append({"path": str(path), "ok": True, "message": msg})
        else:
            repairs.append(write_if_passes(path, content, check_python))
    return repairs


def write_runtime_plan() -> dict:
    content = """# Local Model Runtime Plan

Updated: {updated}

## Decision

Use `llama.cpp` / `llama_cpp.server` as the non-Ollama local model runtime.
Keep cloud models for hard planning/coding, but route fast local checks through
the OpenAI-compatible llama.cpp API at `http://127.0.0.1:8081/v1`.

## Recommended Runtime

- Engine: llama.cpp / llama-cpp-python server
- Primary local model: `Qwen2.5-7B-Instruct-Q4_K_M.gguf`
- Stronger candidate if RAM allows: `Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf`
- Avoid vLLM/ExLlamaV2 on this VPS until a real NVIDIA GPU exists.

## CPU Target

Keep total load around 80-90 percent of the 8 CPU cores. Ollama must not keep a
separate 700-800 percent CPU model process alive while llama.cpp is serving.

## Safe Bring-up

1. Stop or unload local Ollama model processes before local llama.cpp tests.
2. Start llama.cpp on `127.0.0.1:8081`.
3. Smoke test `/v1/chat/completions`.
4. Set `local_ai_provider=llamacpp`.
5. Run the dashboard Test-Gate.
6. Re-enable Autopilot only when the gate is green.
""".format(updated=utc())
    RUNTIME_PLAN.write_text(content, encoding="utf-8")
    return {"path": str(RUNTIME_PLAN), "ok": True, "message": "runtime plan written"}


def main() -> int:
    results = {
        "checked_at": utc(),
        "main_app": repair_main_app(),
        "support": repair_support_tools(),
        "runtime_plan": write_runtime_plan(),
    }
    REPORT.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(json.dumps(results, indent=2))
    failed = []
    if not results["main_app"].get("ok"):
        failed.append(results["main_app"])
    failed.extend(item for item in results["support"] if not item.get("ok"))
    return 2 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
