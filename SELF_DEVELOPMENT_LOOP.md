# PROMETHEUS Self-Development Loop

Goal: improve the agent system in small, tested steps without blindly copying
external code.

## Loop

1. Research public GitHub projects from `research_queue.json`.
2. Summarize useful ideas in `github_research_digest.md`.
3. Convert the best ideas into `improvement_backlog.md`.
4. Implement exactly one small improvement per cycle.
5. Run a lightweight test or syntax check.
6. Commit and push only when the result is useful and safe.

## Safety Rules

- Do not clone or copy external code automatically.
- Check license before any code reuse.
- Prefer high-level concepts over source-code reuse.
- Keep live server code protected; experiments belong in the workspace first.
- Stop repeated reads/actions and write a short diagnosis instead.

## Current Priorities

- Add a read registry to reduce repeated file reads.
- Improve test gates after file writes.
- Keep GitHub status understandable on the dashboard.
- Keep the hybrid cloud/local model routing visible and stable.
