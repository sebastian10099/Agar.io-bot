# External Code Policy

External or copied code may help PROMETHEUS evolve, but it must never go live
directly.

## Required Flow

1. Stage code with source URL, license, and target path.
2. Validate license, target path, denied patterns, and syntax.
3. Fix errors while the item remains staged.
4. Promote only after validation is green.
5. Commit/push only after the promoted file has a passing test gate.

Use:

```bash
python safe_code_intake.py stage --name tool-name --source-url https://example --license mit --target tools/new_tool.py --from-file /tmp/snippet.py
python safe_code_intake.py validate <item_id>
python safe_code_intake.py promote <item_id>
```

## Hard Rules

- Do not copy code without source URL and license metadata.
- Unknown, GPL/AGPL, proprietary, or unclear licenses are concept-only until a
  human/reviewer approves reuse.
- Do not write outside the workspace.
- Do not replace existing files without backup.
- Do not integrate code with syntax errors or denied dangerous patterns.
- If validation fails, fix the staged code first; do not promote it.
