#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/root/local_agent"
REPO="$ROOT/agent_workspace"
LOG="$ROOT/github_auto_sync.log"
STATUS="$ROOT/github_sync_status.json"
BASE_BRANCH="prometheus"
BRANCH="prometheus"
REMOTE="origin"
SSH_KEY="/root/.ssh/github_prometheus"

ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'
}

write_status() {
  local state="$1"
  local message="$2"
  local head commit_subject dirty
  head="$(git rev-parse --short HEAD 2>/dev/null || true)"
  commit_subject="$(git log -1 --pretty=%s 2>/dev/null || true)"
  dirty="$(git status --short 2>/dev/null | wc -l | tr -d " ")"
  cat > "$STATUS" <<EOF
{"checked_at":"$(ts)","state":$(printf "%s" "$state" | json_escape),"message":$(printf "%s" "$message" | json_escape),"repo":"$REPO","branch":"$BRANCH","head":"$head","commit_subject":$(printf "%s" "$commit_subject" | json_escape),"dirty_files":$dirty}
EOF
}

commit_local_changes() {
  local label="${1:-pre-pull}"
  if [[ -n "$(git status --short)" ]]; then
    git add -A
    git commit -m "PROMETHEUS: Auto-Sync ${label} $(date -u +'%Y-%m-%d %H:%M:%S UTC')" || true
  fi
}

run_post_pull_maintenance() {
  local head marker last status_file
  head="$(git rev-parse --short HEAD 2>/dev/null || true)"
  marker="$ROOT/.last_prometheus_runtime_maintenance_head"
  status_file="$ROOT/runtime_maintenance_status.json"
  last="$(cat "$marker" 2>/dev/null || true)"
  if [[ -z "$head" || "$head" == "$last" ]]; then
    return 0
  fi

  echo "[$(ts)] Runtime-Maintenance fuer HEAD $head startet."
  local ok="true"
  local messages=()

  if [[ -f "$REPO/apply_root_runtime_patch.py" ]]; then
    if python3 "$REPO/apply_root_runtime_patch.py" >> "$LOG" 2>&1; then
      messages+=("apply_root_runtime_patch ok")
    else
      ok="false"
      messages+=("apply_root_runtime_patch failed")
    fi
  else
    messages+=("apply_root_runtime_patch missing")
  fi

  if [[ -f "$REPO/apply_dashboard_upgrade.py" ]]; then
    if python3 "$REPO/apply_dashboard_upgrade.py" >> "$LOG" 2>&1; then
      messages+=("apply_dashboard_upgrade ok")
    else
      ok="false"
      messages+=("apply_dashboard_upgrade failed")
    fi
  fi

  if [[ -f "$REPO/github_adoption_engine.py" ]]; then
    if python3 "$REPO/github_adoption_engine.py" --limit 2 >> "$LOG" 2>&1; then
      messages+=("github_adoption_engine ok")
    else
      ok="false"
      messages+=("github_adoption_engine failed")
    fi
  fi

  python3 - "$status_file" "$head" "$ok" "${messages[@]}" <<'PY'
import json, sys, time
path, head, ok, *messages = sys.argv[1:]
payload = {
    "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "head": head,
    "ok": ok == "true",
    "messages": messages,
}
open(path, "w", encoding="utf-8").write(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
PY

  if [[ "$ok" == "true" ]]; then
    printf "%s" "$head" > "$marker"
  fi
}

cd "$REPO"

if [[ -f "$SSH_KEY" ]]; then
  export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
fi

echo "[$(ts)] GitHub Auto-Sync startet fuer $REPO"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$BASE_BRANCH")"
if [[ "$CURRENT_BRANCH" == experiment/* ]]; then
  BRANCH="$CURRENT_BRANCH"
else
  BRANCH="$BASE_BRANCH"
fi

git fetch "$REMOTE" "$BRANCH" || git fetch "$REMOTE" "$BASE_BRANCH" || true

commit_local_changes "pre-pull"

if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
  behind="$(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0)"
  if [[ "$behind" != "0" ]]; then
    if git pull --ff-only; then
      echo "[$(ts)] Fast-forward von GitHub geholt."
      run_post_pull_maintenance
    else
      echo "[$(ts)] Fast-forward nicht moeglich; versuche rebase auf Remote."
      git pull --rebase
      echo "[$(ts)] Rebase von GitHub geholt."
      run_post_pull_maintenance
    fi
  fi
fi

run_post_pull_maintenance

commit_local_changes "post-maintenance"
if [[ -z "$(git status --short)" ]]; then
  echo "[$(ts)] Keine lokalen Aenderungen zum Committen."
fi

ahead="$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo 0)"
if [[ "$ahead" != "0" ]]; then
  git push "$REMOTE" "HEAD:$BRANCH"
  write_status "pushed" "Aenderungen auf GitHub hochgeladen (${BRANCH})."
  echo "[$(ts)] Push abgeschlossen."
else
  write_status "clean" "GitHub ist aktuell; nichts zu pushen."
  echo "[$(ts)] GitHub ist aktuell."
fi
