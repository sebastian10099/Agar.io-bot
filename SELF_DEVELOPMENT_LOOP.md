# PROMETHEUS Self-Development Loop

Goal: improve the agent system in small, tested steps without blindly copying
external code.

## Loop

1. Research public GitHub projects from `research_queue.json`.
2. Summarize useful ideas in `github_research_digest.md`.
3. Convert the best ideas into `improvement_backlog.md`.
4. Implement exactly one small improvement per cycle.
5. If external code is used, run stage -> validate -> promote; promotion runs
   a target-side test and rolls back automatically on failure.
6. Run a lightweight test or syntax check.
7. Commit and push only when the result is useful and safe.

## Safety Rules

- Do not clone or copy external code automatically.
- Check license before any code reuse.
- Copied/pasted code must go through `safe_code_intake.py`: stage with source
  URL/license, validate, fix while staged, then promote only after green checks
  and the final target-side promote test.
- Prefer high-level concepts over source-code reuse.
- Keep live server code protected; experiments belong in the workspace first.
- For risky self-improvement work, run `./experiment_branch_flow.sh` and work on
  the created `experiment/selfdev-*` branch. Auto-sync preserves experiment
  branches instead of pushing them into `prometheus`.
- Stop repeated reads/actions and write a short diagnosis instead.

## Current Priorities

- Add a read registry to reduce repeated file reads.
- Improve test gates after file writes.
- Keep GitHub status understandable on the dashboard.
- Keep the hybrid cloud/local model routing visible and stable.
- Keep `safe_intake_plan.md` updated so GitHub research turns into concrete,
  testable implementation candidates.
