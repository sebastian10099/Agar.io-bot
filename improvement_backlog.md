# Improvement Backlog

Updated: 2026-06-23 19:21:55 UTC

Only one small improvement should be implemented per cycle.

## Done

- [x] P1: Build read_registry.json and per-goal anti-loop guard so agents stop reading the same file repeatedly without a new reason.
- [x] P2: Require one successful lightweight test after write_file/create_tool before marking a goal done.
- [x] P4: Add license_guard notes to every GitHub research item before code reuse.

## Open

- [ ] P3: Use an experiment branch for self-improvement changes and keep live server code protected.
- [ ] P4: Add a safer tool-selection loop: plan, act once, verify, then continue.
- [ ] P5: Improve long-term memory with concise summaries and duplicate detection.
- [ ] P6: Add stronger automatic test/evaluation checks before commit.
