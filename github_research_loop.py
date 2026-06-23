#!/usr/bin/env python3
"""PROMETHEUS self-development research loop.

This script reads a small research queue, looks up public GitHub projects, and
turns findings into safe improvement ideas. It records summaries only; it does
not clone repositories or copy source code.
"""

from __future__ import annotations

import json
import os
import time
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent
QUEUE = ROOT / "research_queue.json"
DIGEST = ROOT / "github_research_digest.md"
BACKLOG = ROOT / "improvement_backlog.md"
STATUS = ROOT / "research_status.json"
LICENSE_GUARD = ROOT / "LICENSE_GUARD.md"

ALLOWED_LICENSES = {
    "mit",
    "apache-2.0",
    "bsd-2-clause",
    "bsd-3-clause",
    "isc",
    "mpl-2.0",
}


STOP_WORDS = {
    "agent",
    "agents",
    "framework",
    "language",
    "python",
    "coding",
    "testing",
    "self",
    "improving",
}


def now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())


def clean_text(value: str, limit: int = 260) -> str:
    value = " ".join(str(value or "").split())
    if len(value) > limit:
        return value[: limit - 3].rstrip() + "..."
    return value


def relevance_terms(query: str) -> set[str]:
    raw = query.replace(":", " ").replace("-", " ").replace("_", " ").split()
    return {x.lower() for x in raw if len(x) > 3 and x.lower() not in STOP_WORDS}


def is_relevant(repo: dict, query: str) -> bool:
    terms = relevance_terms(query)
    if not terms:
        return True
    hay = " ".join([
        str(repo.get("full_name") or ""),
        str(repo.get("description") or ""),
        " ".join(repo.get("topics") or []),
    ]).lower()
    return any(term in hay for term in terms)


def read_queue() -> list[dict]:
    if not QUEUE.exists():
        default = [
            {
                "topic": "OpenClaw autonomous agent",
                "query": "autonomous agent framework language:Python",
                "why": "Find ideas for agent coordination, memory, and safe autonomy.",
            },
            {
                "topic": "AI coding agent anti loop guard",
                "query": "coding agent loop prevention language:Python",
                "why": "Reduce repeated file reads and repeated failed actions.",
            },
            {
                "topic": "agent framework tool testing",
                "query": "AI agent tool testing framework language:Python",
                "why": "Improve the test gate before GitHub push.",
            },
            {
                "topic": "self improving coding agent",
                "query": "self improving coding agent language:Python",
                "why": "Collect safe patterns for plan, experiment, test, and learn loops.",
            },
        ]
        QUEUE.write_text(json.dumps(default, indent=2), encoding="utf-8")
    data = json.loads(QUEUE.read_text(encoding="utf-8"))
    return data if isinstance(data, list) else []


def github_search(query: str, limit: int = 5) -> list[dict]:
    q = urllib.parse.urlencode({
        "q": query,
        "sort": "stars",
        "order": "desc",
        "per_page": str(limit),
    })
    url = f"https://api.github.com/search/repositories?{q}"
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "PROMETHEUS-local-agent-research",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    return payload.get("items", [])[:limit]


def license_status(repo: dict) -> tuple[str, bool]:
    lic = repo.get("license") or {}
    key = str(lic.get("key") or "unknown").lower()
    if key in ALLOWED_LICENSES:
        return key, True
    return key, False


def idea_from_repo(topic: str, repo: dict, license_ok: bool) -> str:
    text = ((repo.get("description") or "") + " " + repo.get("name", "")).lower()
    if "test" in text or "eval" in text:
        return "Add stronger automatic test/evaluation checks before commit."
    if "memory" in text or "rag" in text:
        return "Improve long-term memory with concise summaries and duplicate detection."
    if "agent" in text or "tool" in text:
        return "Add a safer tool-selection loop: plan, act once, verify, then continue."
    if "monitor" in text or "dashboard" in text:
        return "Improve dashboard visibility for progress, blocked states, and resource use."
    if not license_ok:
        return "Use only the high-level concept; do not copy code until license is reviewed."
    return f"Review the project concept for {topic} and extract one small local improvement."


def render_digest(findings: list[dict]) -> str:
    lines = [
        "# GitHub Research Digest",
        "",
        f"Last run: {now()}",
        "",
        "Rule: summarize ideas only. Do not copy external code unless license, source, and attribution are reviewed.",
        "",
    ]
    for item in findings:
        lines.extend([
            f"## {item['topic']}",
            "",
            f"Why: {item['why']}",
            "",
        ])
        if not item["repos"]:
            lines.extend(["No repositories found or GitHub API returned no usable result.", ""])
            continue
        for repo in item["repos"]:
            safe = "OK to study" if repo["license_ok"] else "concept only"
            lines.extend([
                f"### {repo['full_name']}",
                "",
                f"- URL: {repo['html_url']}",
                f"- Stars: {repo['stars']}",
                f"- Updated: {repo['updated_at']}",
                f"- License: {repo['license']} ({safe})",
                f"- Summary: {repo['description'] or 'No description'}",
                f"- Safe takeaway: {repo['idea']}",
                "",
            ])
    return "\n".join(lines).rstrip() + "\n"


def render_backlog(findings: list[dict]) -> str:
    ideas: list[str] = []
    for item in findings:
        for repo in item["repos"]:
            idea = repo["idea"]
            if idea not in ideas:
                ideas.append(idea)
    priority = [
        "Add a safer tool-selection loop: plan, act once, verify, then continue.",
    ]
    for idea in ideas:
        if idea not in priority:
            priority.append(idea)
    lines = [
        "# Improvement Backlog",
        "",
        f"Updated: {now()}",
        "",
        "Only one small improvement should be implemented per cycle.",
        "",
        "## Done",
        "",
        "- [x] P1: Build read_registry.json and per-goal anti-loop guard so agents stop reading the same file repeatedly without a new reason.",
        "- [x] P2: Require one successful lightweight test after write_file/create_tool before marking a goal done.",
        "- [x] P3: Use an experiment branch for self-improvement changes and keep live server code protected.",
        "- [x] P4: Add license_guard notes to every GitHub research item before code reuse.",
        "",
        "## Open",
        "",
    ]
    for idx, idea in enumerate(priority[:12], start=1):
        lines.append(f"- [ ] P{idx + 4}: {idea}")
    lines.append("")
    return "\n".join(lines)


def render_license_guard(findings: list[dict]) -> str:
    rows = []
    allowed = 0
    concept_only = 0
    for item in findings:
        for repo in item["repos"]:
            if repo["license_ok"]:
                allowed += 1
                mode = "study concepts; snippets only with attribution/review"
            else:
                concept_only += 1
                mode = "concept only; no code reuse"
            rows.append(
                "| {topic} | {repo} | {license} | {mode} |".format(
                    topic=item["topic"].replace("|", "/"),
                    repo=repo["full_name"].replace("|", "/"),
                    license=repo["license"].replace("|", "/"),
                    mode=mode,
                )
            )
    lines = [
        "# License Guard",
        "",
        f"Updated: {now()}",
        "",
        "Policy: external code is never copied automatically. License, source URL, attribution, and fit must be reviewed before reuse.",
        "",
        f"- OK-to-study repositories: {allowed}",
        f"- Concept-only repositories: {concept_only}",
        "",
        "| Topic | Repository | License | Allowed use |",
        "|---|---|---|---|",
        *rows,
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    findings = []
    errors = []
    for entry in read_queue():
        topic = str(entry.get("topic") or entry.get("query") or "untitled")
        query = str(entry.get("query") or topic)
        why = str(entry.get("why") or "Explore useful agent improvement ideas.")
        repos = []
        try:
            for repo in github_search(query, limit=8):
                if not is_relevant(repo, query):
                    continue
                lic, ok = license_status(repo)
                repos.append({
                    "full_name": repo.get("full_name", ""),
                    "html_url": repo.get("html_url", ""),
                    "description": clean_text(repo.get("description", "")),
                    "stars": repo.get("stargazers_count", 0),
                    "updated_at": repo.get("updated_at", ""),
                    "license": lic,
                    "license_ok": ok,
                    "idea": idea_from_repo(topic, repo, ok),
                })
                if len(repos) >= 5:
                    break
        except Exception as exc:
            errors.append(f"{topic}: {exc}")
        findings.append({"topic": topic, "query": query, "why": why, "repos": repos})

    DIGEST.write_text(render_digest(findings), encoding="utf-8")
    BACKLOG.write_text(render_backlog(findings), encoding="utf-8")
    LICENSE_GUARD.write_text(render_license_guard(findings), encoding="utf-8")
    ok_to_study = sum(1 for item in findings for repo in item["repos"] if repo["license_ok"])
    concept_only = sum(1 for item in findings for repo in item["repos"] if not repo["license_ok"])
    STATUS.write_text(json.dumps({
        "ok": not errors,
        "checked_at": now(),
        "topics": len(findings),
        "repos": sum(len(x["repos"]) for x in findings),
        "ok_to_study": ok_to_study,
        "concept_only": concept_only,
        "errors": errors[-5:],
        "digest": str(DIGEST),
        "backlog": str(BACKLOG),
        "license_guard": str(LICENSE_GUARD),
    }, indent=2), encoding="utf-8")
    print(f"Research loop complete: {sum(len(x['repos']) for x in findings)} repos, {len(errors)} errors")
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
