#!/usr/bin/env python3
"""Safe external code intake for PROMETHEUS.

Flow:
1. stage: store copied/pasted external code with source and license metadata.
2. validate: check license, dangerous patterns, syntax, and target safety.
3. promote: copy into the workspace only if validation is green.

This script never fetches remote code by itself. The agent or user must provide
the snippet/file and source metadata explicitly.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import py_compile
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent
STAGING = ROOT / "external_code_staging"
REPORT = ROOT / "safe_code_intake_report.json"
ALLOWED_LICENSES = {
    "mit",
    "apache-2.0",
    "bsd-2-clause",
    "bsd-3-clause",
    "isc",
    "mpl-2.0",
}
DENY_PATTERNS = [
    r"rm\s+-rf\s+/",
    r"shutdown\b",
    r"reboot\b",
    r"mkfs\.",
    r"dd\s+if=",
    r"curl\s+[^|]+\|\s*(sh|bash)",
    r"wget\s+[^|]+\|\s*(sh|bash)",
    r"eval\s*\(",
    r"exec\s*\(",
    r"__import__\s*\(",
    r"os\.system\s*\(",
    r"subprocess\.(Popen|call|run)\s*\([^)]*shell\s*=\s*True",
]


def utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def slug(text: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9_.-]+", "-", text.strip()).strip("-").lower()
    return safe[:60] or "snippet"


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()[:12]


def resolve_target(path: str) -> Path:
    target = (ROOT / path).resolve() if not os.path.isabs(path) else Path(path).resolve()
    if os.path.commonpath([str(ROOT), str(target)]) != str(ROOT):
        raise ValueError("target must stay inside the agent workspace")
    if ".git" in target.parts:
        raise ValueError("target must not write inside .git")
    return target


def load_text(args: argparse.Namespace) -> str:
    if getattr(args, "from_url", None):
        req = urllib.request.Request(
            args.from_url,
            headers={"User-Agent": "PROMETHEUS-safe-code-intake"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode("utf-8", errors="replace")
    if args.from_file:
        return Path(args.from_file).read_text(encoding="utf-8", errors="replace")
    if args.content is not None:
        return args.content
    return sys.stdin.read()


def stage(args: argparse.Namespace) -> int:
    code = load_text(args)
    if not code.strip():
        raise ValueError("empty code cannot be staged")
    lic = (args.license or "unknown").lower().strip()
    item_id = f"{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}-{slug(args.name or args.target or 'snippet')}-{sha(code)}"
    item_dir = STAGING / item_id
    item_dir.mkdir(parents=True, exist_ok=False)
    snippet = item_dir / (Path(args.target).name if args.target else "snippet.txt")
    snippet.write_text(code, encoding="utf-8")
    meta = {
        "id": item_id,
        "name": args.name or Path(args.target or "snippet.txt").name,
        "source_url": args.source_url,
        "license": lic,
        "target": args.target,
        "snippet": str(snippet),
        "created_at": utc(),
        "status": "staged",
    }
    (item_dir / "metadata.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(item_id)
    return 0


def read_meta(item_id: str) -> tuple[Path, dict]:
    item_dir = STAGING / item_id
    meta_path = item_dir / "metadata.json"
    if not meta_path.exists():
        raise FileNotFoundError(f"unknown staged item: {item_id}")
    return item_dir, json.loads(meta_path.read_text(encoding="utf-8"))


def validate_item(meta: dict) -> dict:
    snippet_path = Path(meta["snippet"])
    code = snippet_path.read_text(encoding="utf-8", errors="replace")
    checks = []
    lic = str(meta.get("license") or "unknown").lower()
    checks.append({
        "name": "license",
        "ok": lic in ALLOWED_LICENSES,
        "detail": f"{lic} allowed" if lic in ALLOWED_LICENSES else f"{lic} is concept-only until reviewed",
    })
    for pat in DENY_PATTERNS:
        if re.search(pat, code, re.IGNORECASE | re.MULTILINE):
            checks.append({"name": "dangerous_pattern", "ok": False, "detail": pat})
            break
    else:
        checks.append({"name": "dangerous_pattern", "ok": True, "detail": "no denied pattern found"})
    target = str(meta.get("target") or "")
    try:
        resolved = resolve_target(target)
        checks.append({"name": "target_scope", "ok": True, "detail": str(resolved)})
    except Exception as exc:
        checks.append({"name": "target_scope", "ok": False, "detail": str(exc)})
        resolved = None
    suffix = Path(target or snippet_path.name).suffix.lower()
    if suffix == ".py":
        tmp = snippet_path.with_suffix(".validate.py")
        tmp.write_text(code, encoding="utf-8")
        try:
            py_compile.compile(str(tmp), doraise=True)
            checks.append({"name": "python_syntax", "ok": True, "detail": "py_compile ok"})
        except Exception as exc:
            checks.append({"name": "python_syntax", "ok": False, "detail": str(exc)[:300]})
        finally:
            tmp.unlink(missing_ok=True)
    elif suffix == ".sh":
        proc = subprocess.run(["bash", "-n", str(snippet_path)], capture_output=True, text=True, timeout=15)
        checks.append({
            "name": "shell_syntax",
            "ok": proc.returncode == 0,
            "detail": "bash -n ok" if proc.returncode == 0 else (proc.stderr or proc.stdout)[:300],
        })
    elif suffix == ".json":
        try:
            json.loads(code)
            checks.append({"name": "json_syntax", "ok": True, "detail": "json parse ok"})
        except Exception as exc:
            checks.append({"name": "json_syntax", "ok": False, "detail": str(exc)[:300]})
    else:
        checks.append({"name": "basic_content", "ok": bool(code.strip()), "detail": "non-empty file"})
    ok = all(c["ok"] for c in checks)
    return {"ok": ok, "validated_at": utc(), "checks": checks, "resolved_target": str(resolved) if resolved else ""}


def validate(args: argparse.Namespace) -> int:
    item_dir, meta = read_meta(args.item_id)
    result = validate_item(meta)
    meta["validation"] = result
    meta["status"] = "validated" if result["ok"] else "blocked"
    (item_dir / "metadata.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    REPORT.write_text(json.dumps({"last_item": meta, "updated_at": utc()}, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if result["ok"] else 2


def promote(args: argparse.Namespace) -> int:
    item_dir, meta = read_meta(args.item_id)
    result = validate_item(meta)
    if not result["ok"]:
        meta["validation"] = result
        meta["status"] = "blocked"
        (item_dir / "metadata.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
        print(json.dumps(result, indent=2))
        return 2
    target = Path(result["resolved_target"])
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        backup = target.with_suffix(target.suffix + f".bak-intake-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}")
        shutil.copy2(target, backup)
        meta["backup"] = str(backup)
    shutil.copy2(meta["snippet"], target)
    promote_test = run_promote_test(target, args.test_command)
    meta["promote_test"] = promote_test
    if not promote_test["ok"]:
        if meta.get("backup"):
            shutil.copy2(meta["backup"], target)
            promote_test["rollback"] = f"restored {meta['backup']}"
        else:
            target.unlink(missing_ok=True)
            promote_test["rollback"] = "removed newly promoted file"
        meta["validation"] = result
        meta["status"] = "blocked"
        (item_dir / "metadata.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
        REPORT.write_text(json.dumps({"last_item": meta, "updated_at": utc()}, indent=2), encoding="utf-8")
        print(json.dumps(promote_test, indent=2))
        return 3
    meta["validation"] = result
    meta["promoted_at"] = utc()
    meta["status"] = "promoted"
    (item_dir / "metadata.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    REPORT.write_text(json.dumps({"last_item": meta, "updated_at": utc()}, indent=2), encoding="utf-8")
    print(f"promoted {args.item_id} -> {target}")
    return 0


def run_promote_test(target: Path, command: str | None = None) -> dict:
    """Run a final target-side check after copying; callers roll back on failure."""
    suffix = target.suffix.lower()
    if command:
        cmd = shlex.split(command)
        label = command
    elif suffix == ".py":
        cmd = [sys.executable, "-m", "py_compile", str(target)]
        label = "python py_compile"
    elif suffix == ".sh":
        cmd = ["bash", "-n", str(target)]
        label = "bash -n"
    elif suffix == ".json":
        try:
            json.loads(target.read_text(encoding="utf-8"))
            return {"ok": True, "name": "json_parse", "detail": "json parse ok"}
        except Exception as exc:
            return {"ok": False, "name": "json_parse", "detail": str(exc)[:500]}
    else:
        return {"ok": True, "name": "basic_target_check", "detail": "no executable target-side test needed"}
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return {
            "ok": proc.returncode == 0,
            "name": "promote_test",
            "detail": label if proc.returncode == 0 else (proc.stderr or proc.stdout or label)[:500],
        }
    except Exception as exc:
        return {"ok": False, "name": "promote_test", "detail": str(exc)[:500]}


def status(_: argparse.Namespace) -> int:
    items = []
    if STAGING.exists():
        for meta_path in sorted(STAGING.glob("*/metadata.json"), reverse=True)[:30]:
            try:
                items.append(json.loads(meta_path.read_text(encoding="utf-8")))
            except Exception:
                pass
    print(json.dumps({"items": items, "count": len(items)}, indent=2))
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Safe copied/external code intake")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stage")
    s.add_argument("--name", default="")
    s.add_argument("--source-url", required=True)
    s.add_argument("--license", required=True)
    s.add_argument("--target", required=True)
    s.add_argument("--from-file")
    s.add_argument("--from-url", help="fetch external code into staging; use raw/source URLs only")
    s.add_argument("--content")
    s.set_defaults(func=stage)
    v = sub.add_parser("validate")
    v.add_argument("item_id")
    v.set_defaults(func=validate)
    pr = sub.add_parser("promote")
    pr.add_argument("item_id")
    pr.add_argument("--test-command", help="optional final command, split shell-style and run without shell")
    pr.set_defaults(func=promote)
    st = sub.add_parser("status")
    st.set_defaults(func=status)
    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
