# PROMETHEUS Autonomous Agent Architecture

PROMETHEUS is designed as a controlled autonomous development agent, not as an
unbounded shell bot. Every improvement cycle must be visible, testable, and
reversible.

## Loop

1. Plan one small improvement.
2. Create a backup or staging item.
3. Implement the smallest useful change.
4. Run syntax, unit, health, or target-side tests.
5. Promote only if the gate is green.
6. Document the result in memory, logs, and the dashboard.
7. Queue the next improvement.

## Roles

- Planner: chooses the next safe, useful task.
- Researcher: finds repositories, docs, issues, and patterns.
- Coder: writes focused changes.
- Reviewer: checks risk, maintainability, and fit.
- Tester: runs gates and records evidence.
- Integrator: moves staged code through safe_code_intake.
- Security: blocks unsafe commands, secrets exposure, and destructive changes.
- Dashboard-Agent: keeps status, progress, and evidence visible.
- Memory-Agent: stores learnings, failed attempts, and repo judgments.

## GitHub Learning

The agent must not copy random repositories into live code. The required path is:

1. Search or consume `github_learning_activity.json`.
2. Check license, stars, recency, README, and code layout.
3. Download only small relevant files into `github_adoption_staging/`.
4. Write `github_adoption_report.json` and `.md`.
5. Stage useful files through `safe_code_intake.py`.
6. Validate, promote, and test.
7. Document source URL, license, reason, and rollback path.

## Bug Fixing

Bug work starts from logs, tests, crashes, or dashboard gates. A bug fix is not
complete until there is:

- a short bug report,
- a suspected cause,
- a minimal patch,
- a test or health check,
- a documented result,
- rollback or repair notes if the first fix fails.

## Resource Policy

The server should be busy only when useful work is running. Target active load is
80-90%, but safety wins:

- local Ollama uses budget mode,
- context and output tokens are capped,
- local model timeouts stay short,
- cloud fallback is used for heavy review/coding,
- tasks pause or shrink when CPU, RAM, disk, or gate status is unhealthy.

## Dashboard Evidence

The dashboard should show:

- live agent status and current goal,
- CPU/RAM/storage and top processes,
- GitHub sync status,
- GitHub adoption candidates,
- runtime maintenance status,
- test-gate state,
- bugs and fixes,
- next improvements,
- safety warnings,
- recent code activity and changed files.

## Safety Rules

- No secret tokens in dashboard or logs.
- No account creation without explicit permission.
- No attacks, spam, or unauthorized external automation.
- No destructive actions without backup and clear scope.
- External code requires source, license, validation, and rollback.
