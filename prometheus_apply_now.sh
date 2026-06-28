#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PROMETHEUS_ROOT:-/root/local_agent}"
REPO="${PROMETHEUS_REPO:-$ROOT/agent_workspace}"
LOG="$ROOT/prometheus_apply_now.log"

ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

run() {
  echo "[$(ts)] $*" | tee -a "$LOG"
  "$@" 2>&1 | tee -a "$LOG"
}

cd "$REPO"
echo "[$(ts)] PROMETHEUS apply-now starts in $REPO" | tee -a "$LOG"

run git fetch origin prometheus
run git pull --ff-only origin prometheus

if [[ -f "$REPO/github_auto_sync.sh" ]]; then
  run cp "$REPO/github_auto_sync.sh" "$ROOT/github_auto_sync.sh"
  run chmod +x "$ROOT/github_auto_sync.sh"
fi

if [[ -f "$REPO/apply_root_runtime_patch.py" ]]; then
  run python3 "$REPO/apply_root_runtime_patch.py"
fi

if [[ -f "$REPO/apply_dashboard_upgrade.py" ]]; then
  run python3 "$REPO/apply_dashboard_upgrade.py"
fi

run python3 -m py_compile \
  "$ROOT/brain.py" \
  "$ROOT/server.py" \
  "$REPO/apply_root_runtime_patch.py" \
  "$REPO/github_adoption_engine.py" \
  "$REPO/selfdev_repair.py"

if command -v systemctl >/dev/null 2>&1; then
  run systemctl restart local-agent.service
fi

if [[ -x "$ROOT/github_auto_sync.sh" ]]; then
  run "$ROOT/github_auto_sync.sh"
fi

echo "[$(ts)] PROMETHEUS apply-now done. See $LOG" | tee -a "$LOG"
