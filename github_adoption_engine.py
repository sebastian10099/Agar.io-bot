#!/usr/bin/env python3
"""Turn GitHub learning into actionable adoption candidates.

PROMETHEUS already researches GitHub projects. This worker makes that research
useful: it downloads metadata and small candidate files into a controlled
staging area, scores what can be adopted, and writes concrete safe_code_intake
commands. It does not promote code by itself.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent
ACTIVITY = ROOT / "github_learning_activity.json"
QUEUE = ROOT / "research_queue.json"
STAGING = ROOT / "github_adoption_staging"
REPORT = ROOT / "github_adoption_report.json"
MARKDOWN = ROOT / "github_adoption_report.md"

ALLOWED_LICENSES = {"mit", "apache-2.0", "bsd-2-clause", "bsd-3-clause", "isc", "mpl-2.0"}
INTERESTING_SUFFIXES = {".py", ".sh", ".md", ".json", ".yaml", ".yml", ".toml"}
MAX_FILE_BYTES = 60_000
MAX_FILES_PER_REPO = 8


def utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def slug(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_.-]+", "-", value).strip("-").lower()[:90] or "repo"


def request_json(url: str) -> dict | list:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "PROMETHEUS-github-adoption-engine",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=25) as resp:
        return json.loads(resp.read().decode("utf-8"))


def request_text(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "PROMETHEUS-github-adoption-engine"})
    with urllib.request.urlopen(req, timeout=25) as resp:
        raw = resp.read(MAX_FILE_BYTES + 1)
    return raw[:MAX_FILE_BYTES].decode("utf-8", errors="replace")


def load_candidates(limit: int) -> list[dict]:
    data = json.loads(ACTIVITY.read_text(encoding="utf-8")) if ACTIVITY.exists() else {}
    candidates = data.get("candidates") or []
    usable = [
        c for c in candidates
        if c.get("repo") and c.get("url") and c.get("mode") == "code-intake-allowed"
    ]
    if usable:
        return usable[:limit]
    return search_candidates(limit)


def search_candidates(limit: int) -> list[dict]:
    queries = [
        {
            "topic": "self improving coding agent",
            "query": "self improving coding agent language:Python",
            "why": "Find small self-development patterns to adopt.",
        },
        {
            "topic": "agent framework tool testing",
            "query": "AI agent tool testing framework language:Python",
            "why": "Find test-gate and validator ideas.",
        },
        {
            "topic": "OpenClaw core autonomy",
            "query": "OpenClaw autonomous agent language:Python",
            "why": "Find autonomy and skill ideas.",
        },
    ]
    if QUEUE.exists():
        try:
            loaded = json.loads(QUEUE.read_text(encoding="utf-8"))
            if isinstance(loaded, list) and loaded:
                queries = loaded
        except Exception:
            pass
    out = []
    for entry in queries:
        query = str(entry.get("query") or entry.get("topic") or "")
        if not query:
            continue
        q = urllib.parse.urlencode({
            "q": query,
            "sort": "stars",
            "order": "desc",
            "per_page": "8",
        })
        try:
            payload = request_json(f"https://api.github.com/search/repositories?{q}")
        except Exception:
            continue
        for repo in (payload.get("items") if isinstance(payload, dict) else []) or []:
            lic = ((repo.get("license") or {}).get("key") or "unknown").lower()
            if lic not in ALLOWED_LICENSES:
                continue
            out.append({
                "type": "repo_review",
                "topic": entry.get("topic") or query,
                "repo": repo.get("full_name"),
                "url": repo.get("html_url"),
                "stars": repo.get("stargazers_count", 0),
                "updated_at": repo.get("updated_at", ""),
                "license": lic,
                "mode": "code-intake-allowed",
                "idea": "Extract one small, tested agent-improvement component.",
                "action": "Download metadata and small files, then stage useful code through safe_code_intake.",
                "risk": "review required before promote",
                "next_step": "safe_code_intake stage/validate/promote",
            })
            if len(out) >= limit:
                return out
    return out[:limit]


def score_path(path: str) -> int:
    lower = path.lower()
    score = 0
    if any(term in lower for term in ("agent", "tool", "memory", "guard", "eval", "test", "workflow", "skill")):
        score += 8
    if lower.endswith(".py"):
        score += 5
    if lower.endswith((".md", ".json", ".yaml", ".yml", ".toml", ".sh")):
        score += 2
    if any(term in lower for term in ("setup", "install", "deploy", "docker", "vendor", "node_modules", ".venv")):
        score -= 8
    if lower.startswith(("tests/", "test/")):
        score += 2
    return score


def repo_api_base(full_name: str) -> str:
    return "https://api.github.com/repos/" + full_name


def collect_tree(full_name: str, branch: str) -> list[dict]:
    url = f"{repo_api_base(full_name)}/git/trees/{urllib.parse.quote(branch)}?recursive=1"
    payload = request_json(url)
    if not isinstance(payload, dict):
        return []
    rows = payload.get("tree") or []
    files = [
        row for row in rows
        if row.get("type") == "blob"
        and Path(str(row.get("path", ""))).suffix.lower() in INTERESTING_SUFFIXES
        and int(row.get("size") or 0) <= MAX_FILE_BYTES
    ]
    files.sort(key=lambda r: score_path(str(r.get("path", ""))), reverse=True)
    return files[:MAX_FILES_PER_REPO]


def raw_url(full_name: str, branch: str, path: str) -> str:
    return f"https://raw.githubusercontent.com/{full_name}/{urllib.parse.quote(branch)}/{urllib.parse.quote(path)}"


def syntax_check(path: Path) -> tuple[bool, str]:
    suffix = path.suffix.lower()
    if suffix == ".py":
        proc = subprocess.run(["python3", "-m", "py_compile", str(path)], capture_output=True, text=True, timeout=20)
        return proc.returncode == 0, (proc.stderr or "python syntax ok").strip()[:500]
    if suffix == ".sh":
        proc = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True, timeout=20)
        return proc.returncode == 0, (proc.stderr or "shell syntax ok").strip()[:500]
    if suffix == ".json":
        try:
            json.loads(path.read_text(encoding="utf-8"))
            return True, "json parse ok"
        except Exception as exc:
            return False, str(exc)[:500]
    return True, "content staged"


def adopt_repo(candidate: dict) -> dict:
    full_name = candidate["repo"]
    repo = request_json(repo_api_base(full_name))
    if not isinstance(repo, dict):
        raise RuntimeError("invalid repo payload")
    branch = repo.get("default_branch") or "main"
    license_key = ((repo.get("license") or {}).get("key") or candidate.get("license") or "unknown").lower()
    repo_dir = STAGING / slug(full_name)
    files_dir = repo_dir / "files"
    files_dir.mkdir(parents=True, exist_ok=True)
    meta = {
        "repo": full_name,
        "url": repo.get("html_url") or candidate.get("url"),
        "default_branch": branch,
        "license": license_key,
        "license_ok": license_key in ALLOWED_LICENSES,
        "topic": candidate.get("topic", ""),
        "idea": candidate.get("idea", ""),
        "action": candidate.get("action", ""),
        "risk": candidate.get("risk", ""),
        "checked_at": utc(),
    }
    try:
        readme = request_text(raw_url(full_name, branch, "README.md"))
        (repo_dir / "README.md").write_text(readme, encoding="utf-8")
    except Exception as exc:
        meta["readme_error"] = str(exc)[:300]
    try:
        lic = request_text(raw_url(full_name, branch, "LICENSE"))
        (repo_dir / "LICENSE").write_text(lic, encoding="utf-8")
    except Exception as exc:
        meta["license_file_error"] = str(exc)[:300]
    staged_files = []
    for item in collect_tree(full_name, branch):
        rel = str(item.get("path") or "")
        if not rel:
            continue
        try:
            text = request_text(raw_url(full_name, branch, rel))
            local = files_dir / rel.replace("/", "__")
            local.write_text(text, encoding="utf-8")
            ok, check = syntax_check(local)
            suggested_target = "external_adoptions/" + slug(full_name) + "/" + Path(rel).name
            command = (
                "python safe_code_intake.py stage "
                f"--name {json.dumps(slug(full_name)+'-'+Path(rel).name)} "
                f"--source-url {json.dumps(raw_url(full_name, branch, rel))} "
                f"--license {json.dumps(license_key)} "
                f"--target {json.dumps(suggested_target)} "
                f"--from-file {json.dumps(str(local))}"
            )
            staged_files.append({
                "path": rel,
                "local": str(local),
                "size": item.get("size", 0),
                "score": score_path(rel),
                "syntax_ok": ok,
                "syntax_check": check,
                "suggested_target": suggested_target,
                "safe_code_intake_command": command if meta["license_ok"] and ok else "",
            })
        except Exception as exc:
            staged_files.append({"path": rel, "error": str(exc)[:300]})
    meta["files"] = staged_files
    (repo_dir / "adoption.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    return meta


def render_markdown(results: list[dict], errors: list[str]) -> str:
    lines = ["# GitHub Adoption Report", "", f"Updated: {utc()}", ""]
    for item in results:
        lines.extend([
            f"## {item['repo']}",
            "",
            f"- URL: {item.get('url', '')}",
            f"- License: {item.get('license', 'unknown')} ({'allowed' if item.get('license_ok') else 'blocked'})",
            f"- Idea: {item.get('idea', '')}",
            f"- Action: {item.get('action', '')}",
            f"- Risk: {item.get('risk', '')}",
            "",
            "| File | Score | Syntax | Intake |",
            "|---|---:|---|---|",
        ])
        for file in item.get("files", [])[:MAX_FILES_PER_REPO]:
            intake = "ready" if file.get("safe_code_intake_command") else "review/fix"
            lines.append(f"| {file.get('path', '')} | {file.get('score', '')} | {file.get('syntax_ok', '')} | {intake} |")
        lines.append("")
    if errors:
        lines.extend(["## Errors", "", *[f"- {e}" for e in errors], ""])
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Download and stage GitHub adoption candidates")
    parser.add_argument("--limit", type=int, default=3)
    args = parser.parse_args()
    STAGING.mkdir(parents=True, exist_ok=True)
    results = []
    errors = []
    for candidate in load_candidates(args.limit):
        try:
            results.append(adopt_repo(candidate))
        except Exception as exc:
            errors.append(f"{candidate.get('repo', '?')}: {exc}")
    payload = {
        "checked_at": utc(),
        "ok": bool(results),
        "count": len(results),
        "staging": str(STAGING),
        "results": results,
        "errors": errors,
    }
    REPORT.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    MARKDOWN.write_text(render_markdown(results, errors), encoding="utf-8")
    sys.stdout.buffer.write((json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
    return 0 if results else 1


if __name__ == "__main__":
    raise SystemExit(main())
