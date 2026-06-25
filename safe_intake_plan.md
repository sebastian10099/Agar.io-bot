# Safe Intake Plan

Updated: 2026-06-25 20:00:05 UTC

Purpose: turn GitHub research into small implementation candidates, including external code, without letting untested code go live.

## Flow

1. Pick one backlog item only.
2. Prefer reimplementing the idea locally when simpler; copied code is allowed when license permits.
3. If code is copied, stage it with source URL, license, and target path. Raw GitHub files may use `--from-url`.
4. Run `safe_code_intake.py validate <item_id>`.
5. Promote only if green; promotion runs a target-side test and rolls back on failure.
6. Run the agent Test-Gate and GitHub auto-sync only after the target is clean.

## Candidate Mapping

### openclaw-token-optimizer/openclaw-token-optimizer

- Topic: OpenClaw / OpenClout autonomous agent
- Mode: code-intake-allowed
- Safe idea: Add a safer tool-selection loop: plan, act once, verify, then continue.
- Source: https://github.com/openclaw-token-optimizer/openclaw-token-optimizer
- License: apache-2.0
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.

### AuroraKON6/xianyu-agent

- Topic: OpenClaw / OpenClout autonomous agent
- Mode: concept-only
- Safe idea: Add a safer tool-selection loop: plan, act once, verify, then continue.
- Source: https://github.com/AuroraKON6/xianyu-agent
- License: unknown
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.

### satawarlock-a11y/agent-memory-core

- Topic: OpenClaw / OpenClout autonomous agent
- Mode: code-intake-allowed
- Safe idea: Improve long-term memory with concise summaries and duplicate detection.
- Source: https://github.com/satawarlock-a11y/agent-memory-core
- License: mit
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.

### MABAIStrategies/agent-guardrails-v0.1

- Topic: OpenClaw / OpenClout autonomous agent
- Mode: code-intake-allowed
- Safe idea: Add a safer tool-selection loop: plan, act once, verify, then continue.
- Source: https://github.com/MABAIStrategies/agent-guardrails-v0.1
- License: mit
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.

### yahweh12025-dev/human-ai

- Topic: OpenClaw / OpenClout autonomous agent
- Mode: concept-only
- Safe idea: Add a safer tool-selection loop: plan, act once, verify, then continue.
- Source: https://github.com/yahweh12025-dev/human-ai
- License: unknown
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.

### zeroclaw-labs/zeroclaw

- Topic: OpenClaw core autonomy
- Mode: code-intake-allowed
- Safe idea: Review the project concept for OpenClaw core autonomy and extract one small local improvement.
- Source: https://github.com/zeroclaw-labs/zeroclaw
- License: apache-2.0
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.

### beancookie/xiaoclaw

- Topic: OpenClaw core autonomy
- Mode: code-intake-allowed
- Safe idea: Improve long-term memory with concise summaries and duplicate detection.
- Source: https://github.com/beancookie/xiaoclaw
- License: mit
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.

### Agnuxo1/OpenCLAW-Autonomous-Multi-Agent-Scientific-Research-Platform

- Topic: OpenClaw core autonomy
- Mode: concept-only
- Safe idea: Add a safer tool-selection loop: plan, act once, verify, then continue.
- Source: https://github.com/Agnuxo1/OpenCLAW-Autonomous-Multi-Agent-Scientific-Research-Platform
- License: unknown
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.

### shaoxiang/awesome-openclaw

- Topic: OpenClaw core autonomy
- Mode: concept-only
- Safe idea: Add a safer tool-selection loop: plan, act once, verify, then continue.
- Source: https://github.com/shaoxiang/awesome-openclaw
- License: unknown
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.

### jonathanprocter/openclaw-config

- Topic: OpenClaw core autonomy
- Mode: concept-only
- Safe idea: Improve long-term memory with concise summaries and duplicate detection.
- Source: https://github.com/jonathanprocter/openclaw-config
- License: unknown
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.

### mergisi/awesome-openclaw-agents

- Topic: Awesome OpenClaw agent templates
- Mode: code-intake-allowed
- Safe idea: Add a safer tool-selection loop: plan, act once, verify, then continue.
- Source: https://github.com/mergisi/awesome-openclaw-agents
- License: mit
- Integration rule: implement or copy one small local patch, validate, then promote/test before replacing anything.
