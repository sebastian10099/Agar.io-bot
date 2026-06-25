#!/usr/bin/env python3
"""PROMETHEUS self-development research loop.

This script reads a small research queue, looks up public GitHub projects, and
turns findings into safe improvement ideas. External code is allowed when its
source, license, staging, validation, target-side test, and rollback path are
documented by safe_code_intake.py.
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
INTAKE_PLAN = ROOT / "safe_intake_plan.md"
LEARNING_ACTIVITY = ROOT / "github_learning_activity.json"

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
                "topic": "OpenClaw / OpenClout autonomous agent",
                "query": "OpenClaw autonomous agent OR open source autonomous agent language:Python",
                "why": "Find ideas for agent coordination, memory, and safe autonomy.",
            },
            {
                "topic": "OpenClaw core autonomy",
                "query": "openclaw openclaw personal AI assistant autonomous agent",
                "why": "Import useful self-coding, skills, memory, channel, and live-canvas patterns when license allows.",
            },
            {
                "topic": "Paperclip AI orchestration",
                "query": "paperclip ai autonomous agents orchestration github",
                "why": "Find org chart, budgets, governance, task assignment, and multi-agent coordination patterns.",
            },
            {
                "topic": "Antfarm OpenClaw agent team",
                "query": "Antfarm OpenClaw planner developer verifier tester reviewer",
                "why": "Import team-role patterns for planner, coder, verifier, tester, and reviewer agents.",
            },
            {
                "topic": "Awesome OpenClaw agent templates",
                "query": "awesome OpenClaw agents SOUL.md templates",
                "why": "Use permissive templates as candidate personalities, roles, and workflows.",
            },
            {
                "topic": "OpenClaw high privilege safety",
                "query": "OpenClaw security practice guide autonomous AI agents",
                "why": "Keep autonomy powerful without losing rollback, audit, least privilege, and kill-switch controls.",
            },
            {
                "topic": "AI coding agent LoopGuard",
                "query": "coding agent loop guard loop prevention language:Python",
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
            {
                "topic": "safe external code intake",
                "query": "AI coding agent safe code execution sandbox tests language:Python",
                "why": "Improve stage, validate, promote, rollback, and test-before-live workflows.",
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
        return "Use only the high-level concept; code reuse needs explicit license approval first."
    return f"Review the project concept for {topic} and extract one small local improvement."


def adaptation_action(topic: str, repo: dict, license_ok: bool) -> str:
    text = " ".join([
        topic,
        repo.get("full_name", ""),
        repo.get("description", ""),
        " ".join(repo.get("topics") or []),
    ]).lower()
    if not license_ok:
        return "Nur Konzept extrahieren; Code erst nach Lizenzfreigabe stagen."
    if "paperclip" in text or "orchestration" in text:
        return "Orchestrierung/Budget/Task-Zuordnung als Dashboard- und Team-Regel adaptieren."
    if "openclaw" in text:
        return "Autonomie-, Skill-, Memory- oder Kanal-Muster pruefen und als kleinen Patch stagen."
    if "guard" in text or "security" in text or "safety" in text:
        return "Guardrail oder Rollback-Regel als Sicherheits-Patch ueber safe_code_intake testen."
    if "template" in text or "soul" in text:
        return "Agentenrolle oder Workflow-Vorlage als Konfig-/Prompt-Erweiterung pruefen."
    if "test" in text or "eval" in text:
        return "Test-Gate/Eval-Idee als kleinen Validator ergaenzen."
    return "Einen kleinen nutzbaren Teil isolieren, stagen, validieren und erst dann promoten."


def risk_level(repo: dict, license_ok: bool) -> str:
    if not license_ok:
        return "hoch: Lizenz unklar oder nicht direkt erlaubt"
    desc = (repo.get("description") or "").lower()
    if any(word in desc for word in ["shell", "browser", "credential", "security", "autonomous"]):
        return "mittel: Funktion betrifft autonome/privilegierte Aktionen"
    return "niedrig: permissive Lizenz und begrenzter Scope"


def learning_activity(findings: list[dict], errors: list[str]) -> dict:
    events = []
    candidates = []
    for item in findings:
        repos = item.get("repos", [])
        events.append({
            "type": "topic_scan",
            "topic": item.get("topic", ""),
            "query": item.get("query", ""),
            "why": item.get("why", ""),
            "result": f"{len(repos)} passende Repos gefunden",
        })
        for repo in repos:
            mode = "code-intake-allowed" if repo["license_ok"] else "concept-only"
            event = {
                "type": "repo_review",
                "topic": item.get("topic", ""),
                "repo": repo["full_name"],
                "url": repo["html_url"],
                "stars": repo["stars"],
                "updated_at": repo["updated_at"],
                "license": repo["license"],
                "mode": mode,
                "idea": repo["idea"],
                "action": adaptation_action(item.get("topic", ""), repo, repo["license_ok"]),
                "risk": risk_level(repo, repo["license_ok"]),
                "next_step": (
                    "safe_code_intake stage/validate/promote"
                    if repo["license_ok"] else
                    "Konzept notieren; kein Code-Promote"
                ),
            }
            events.append(event)
            candidates.append(event)
    return {
        "checked_at": now(),
        "summary": f"{len(findings)} Themen, {len(candidates)} Repo-Kandidaten, {len(errors)} Fehler",
        "current_focus": candidates[0] if candidates else None,
        "events": events[-80:],
        "candidates": candidates[:24],
        "errors": errors[-5:],
    }


def render_digest(findings: list[dict]) -> str:
    lines = [
        "# GitHub Research Digest",
        "",
        f"Last run: {now()}",
        "",
        "Rule: external code is allowed after license/source/attribution review and safe_code_intake validation.",
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
                f"- Intake: stage with source `{repo['html_url']}` and license `{repo['license']}` before any code reuse.",
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
                mode = "code reuse allowed through safe_code_intake with attribution/review"
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
        "Policy: external code is allowed, but never goes live directly. License, source URL, attribution, fit, validation, target-side test, and rollback must be reviewed before reuse.",
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


def render_intake_plan(findings: list[dict]) -> str:
    lines = [
        "# Safe Intake Plan",
        "",
        f"Updated: {now()}",
        "",
        "Purpose: turn GitHub research into small implementation candidates, including external code, without letting untested code go live.",
        "",
        "## Flow",
        "",
        "1. Pick one backlog item only.",
        "2. Prefer reimplementing the idea locally when simpler; copied code is allowed when license permits.",
        "3. If code is copied, stage it with source URL, license, and target path. Raw GitHub files may use `--from-url`.",
        "4. Run `safe_code_intake.py validate <item_id>`.",
        "5. Promote only if green; promotion runs a target-side test and rolls back on failure.",
        "6. Run the agent Test-Gate and GitHub auto-sync only after the target is clean.",
        "",
        "## Candidate Mapping",
        "",
    ]
    seen = set()
    for item in findings:
        for repo in item["repos"]:
            key = (repo["full_name"], repo["idea"])
            if key in seen:
                continue
            seen.add(key)
            mode = "concept-only" if not repo["license_ok"] else "code-intake-allowed"
            lines.extend([
                f"### {repo['full_name']}",
                "",
                f"- Topic: {item['topic']}",
                f"- Mode: {mode}",
                f"- Safe idea: {repo['idea']}",
                f"- Source: {repo['html_url']}",
                f"- License: {repo['license']}",
                "- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.",
                "",
            ])
    if len(lines) <= 19:
        lines.append("No candidates yet.")
        lines.append("")
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

    ok_to_study = sum(1 for item in findings for repo in item["repos"] if repo["license_ok"])
    concept_only = sum(1 for item in findings for repo in item["repos"] if not repo["license_ok"])
    total_repos = sum(len(x["repos"]) for x in findings)
    if total_repos == 0 and errors:
        previous = {}
        if STATUS.exists():
            try:
                previous = json.loads(STATUS.read_text(encoding="utf-8"))
            except Exception:
                previous = {}
        STATUS.write_text(json.dumps({
            "ok": bool(previous.get("ok", False)),
            "checked_at": now(),
            "topics": len(findings),
            "repos": previous.get("repos", 0),
            "ok_to_study": previous.get("ok_to_study", 0),
            "concept_only": previous.get("concept_only", 0),
            "errors": errors[-5:],
            "warnings": errors[-5:],
            "stale": True,
            "stale_reason": "GitHub API returned no usable results; kept previous digest/backlog/license guard.",
            "digest": str(DIGEST),
            "backlog": str(BACKLOG),
            "license_guard": str(LICENSE_GUARD),
            "intake_plan": str(INTAKE_PLAN),
            "learning_activity": str(LEARNING_ACTIVITY),
        }, indent=2), encoding="utf-8")
        print(f"Research loop kept previous files: 0 repos, {len(errors)} errors")
        return 0 if previous.get("ok", False) else 1
    DIGEST.write_text(render_digest(findings), encoding="utf-8")
    BACKLOG.write_text(render_backlog(findings), encoding="utf-8")
    LICENSE_GUARD.write_text(render_license_guard(findings), encoding="utf-8")
    INTAKE_PLAN.write_text(render_intake_plan(findings), encoding="utf-8")
    LEARNING_ACTIVITY.write_text(json.dumps(learning_activity(findings, errors), indent=2), encoding="utf-8")
    STATUS.write_text(json.dumps({
        "ok": total_repos > 0,
        "checked_at": now(),
        "topics": len(findings),
        "repos": total_repos,
        "ok_to_study": ok_to_study,
        "concept_only": concept_only,
        "errors": errors[-5:],
        "warnings": errors[-5:],
        "digest": str(DIGEST),
        "backlog": str(BACKLOG),
        "license_guard": str(LICENSE_GUARD),
        "intake_plan": str(INTAKE_PLAN),
        "learning_activity": str(LEARNING_ACTIVITY),
    }, indent=2), encoding="utf-8")
    print(f"Research loop complete: {sum(len(x['repos']) for x in findings)} repos, {len(errors)} errors")
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
