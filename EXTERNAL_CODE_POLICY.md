# External Code Policy

External or copied code may help PROMETHEUS evolve, but it must never go live
directly.

## Required Flow

1. Stage code with source URL, license, and target path.
2. Validate license, target path, denied patterns, and syntax.
3. Fix errors while the item remains staged.
4. Promote only after validation is green; the promoted target is tested again.
5. If the target-side test fails, rollback happens automatically and the item
   stays blocked.
6. Commit/push only after the promoted file has a passing test gate.

Use:

```bash
python safe_code_intake.py stage --name tool-name --source-url https://example --license mit --target tools/new_tool.py --from-file /tmp/snippet.py
python safe_code_intake.py validate <item_id>
python safe_code_intake.py promote <item_id>
python safe_code_intake.py promote <item_id> --test-command "python3 -m py_compile tools/new_tool.py"
```

## Hard Rules

- Do not copy code without source URL and license metadata.
- Unknown, GPL/AGPL, proprietary, or unclear licenses are concept-only until a
  human/reviewer approves reuse.
- Do not write outside the workspace.
- Do not replace existing files without backup.
- Do not integrate code with syntax errors or denied dangerous patterns.
- If validation or the final promote test fails, fix the staged code first; do
  not promote it.
