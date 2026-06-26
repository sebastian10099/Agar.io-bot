# Improvement Backlog

Updated: 2026-06-26 07:30:06 UTC

Only one small improvement should be implemented per cycle.

## Done

- [x] P1: Build read_registry.json and per-goal anti-loop guard so agents stop reading the same file repeatedly without a new reason.
- [x] P2: Require one successful lightweight test after write_file/create_tool before marking a goal done.
- [x] P3: Use an experiment branch for self-improvement changes and keep live server code protected.
- [x] P4: Add license_guard notes to every GitHub research item before code reuse.

## Open

- [ ] P5: Add a safer tool-selection loop: plan, act once, verify, then continue.
- [ ] P6: Improve long-term memory with concise summaries and duplicate detection.
- [ ] P7: Review the project concept for OpenClaw core autonomy and extract one small local improvement.
- [ ] P8: Add stronger automatic test/evaluation checks before commit.
