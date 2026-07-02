#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PROMETHEUS_ROOT:-/root/local_agent}"
CONFIG="$ROOT/config.json"
LOG="$ROOT/prometheus_dashboard_watchdog.log"
STAMP="$ROOT/.prometheus_dashboard_watchdog_restart"
COOLDOWN_SECONDS="${PROMETHEUS_DASHBOARD_WATCHDOG_COOLDOWN:-180}"

ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "[$(ts)] $*" | tee -a "$LOG"
}

read_cfg() {
  python3 - "$CONFIG" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
print(cfg.get("dashboard_user", ""))
print(cfg.get("dashboard_password", ""))
print(cfg.get("dashboard_port", 7860))
PY
}

mapfile -t CFG < <(read_cfg)
USER="${CFG[0]:-}"
PASS="${CFG[1]:-}"
PORT="${CFG[2]:-7860}"
URL="http://127.0.0.1:${PORT}/state"

AUTH_ARGS=()
if [[ -n "$USER" || -n "$PASS" ]]; then
  AUTH_ARGS=(-u "$USER:$PASS")
fi

if curl -fsS --max-time 8 "${AUTH_ARGS[@]}" "$URL" >/dev/null; then
  log "dashboard ok on $URL"
  exit 0
fi

now="$(date +%s)"
last=0
if [[ -f "$STAMP" ]]; then
  last="$(cat "$STAMP" 2>/dev/null || echo 0)"
fi
if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < COOLDOWN_SECONDS )); then
  log "dashboard unhealthy, restart skipped because cooldown is active"
  exit 0
fi

log "dashboard unhealthy on $URL; restarting local-agent.service"
echo "$now" > "$STAMP"
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart local-agent.service
else
  log "systemctl not found; cannot restart service"
  exit 1
fi

sleep 6
if curl -fsS --max-time 8 "${AUTH_ARGS[@]}" "$URL" >/dev/null; then
  log "dashboard recovered after restart"
  exit 0
fi

log "dashboard still unhealthy after restart"
exit 1
