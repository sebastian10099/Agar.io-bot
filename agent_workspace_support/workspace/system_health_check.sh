#!/bin/bash
# system_health_check.sh - Lightweight system diagnostics
# Checks: Disk, Memory, CPU-Load, Workspace-Integrity, Top-3 Processes
# Status: OK / WARN / CRIT per category
# Created by Support-Agent GLM

set -euo pipefail

LOG="/root/local_agent/agent_workspace_support/workspace/system_health.log"
TS="$(date '+%Y-%m-%d %H:%M:%S')"

# --- Helper functions ---
print_status() {
  local category="$1" status="$2" detail="$3"
  printf "[%-18s] %-6s %s\n" "$category" "$status" "$detail"
}

log_line() {
  echo "$1" >> "$LOG"
}

# --- Start ---
echo "=============================================="
echo " SYSTEM HEALTH CHECK - $TS"
echo "=============================================="
log_line "=== $TS ==="

# --- 1) Disk Usage ---
DISK_PCT=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')
if [ "$DISK_PCT" -ge 90 ]; then
  DISK_STATUS="CRIT"
elif [ "$DISK_PCT" -ge 80 ]; then
  DISK_STATUS="WARN"
else
  DISK_STATUS="OK"
fi
DISK_DETAIL="Disk / at ${DISK_PCT}% used"
print_status "Disk Usage" "$DISK_STATUS" "$DISK_DETAIL"
log_line "[Disk] $DISK_STATUS - $DISK_DETAIL"

# --- 2) Memory ---
MEM_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
MEM_USED=$(free -m | awk '/^Mem:/ {print $3}')
if [ "$MEM_TOTAL" -gt 0 ]; then
  MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
else
  MEM_PCT=0
fi
if [ "$MEM_PCT" -ge 90 ]; then
  MEM_STATUS="CRIT"
elif [ "$MEM_PCT" -ge 80 ]; then
  MEM_STATUS="WARN"
else
  MEM_STATUS="OK"
fi
MEM_DETAIL="Memory: ${MEM_USED}M/${MEM_TOTAL}M (${MEM_PCT}%)"
print_status "Memory" "$MEM_STATUS" "$MEM_DETAIL"
log_line "[Memory] $MEM_STATUS - $MEM_DETAIL"

# --- 3) CPU Load ---
# Extract 1-minute load average
LOAD_1M=$(awk '{print $1}' /proc/loadavg)
# Get CPU count
CPU_COUNT=$(nproc 2>/dev/null || echo 1)
# Compare load to CPU count (bash float-safe via awk)
LOAD_RATIO=$(awk -v l="$LOAD_1M" -v c="$CPU_COUNT" 'BEGIN { printf "%.2f", l/c }')
LOAD_PCT_INT=$(awk -v l="$LOAD_1M" -v c="$CPU_COUNT" 'BEGIN { printf "%d", (l/c)*100 }')
if [ "$LOAD_PCT_INT" -ge 200 ]; then
  CPU_STATUS="CRIT"
elif [ "$LOAD_PCT_INT" -ge 100 ]; then
  CPU_STATUS="WARN"
else
  CPU_STATUS="OK"
fi
CPU_DETAIL="Load(1m): ${LOAD_1M} on ${CPU_COUNT} CPUs (ratio ${LOAD_RATIO})"
print_status "CPU Load" "$CPU_STATUS" "$CPU_DETAIL"
log_line "[CPU] $CPU_STATUS - $CPU_DETAIL"

# --- 4) Workspace Integrity ---
WORKSPACE_STATUS="OK"
WORKSPACE_MISSING=""
for dir in /root/workspace /root/.ollama /usr/bin; do
  if [ ! -d "$dir" ]; then
    WORKSPACE_MISSING="${WORKSPACE_MISSING} ${dir}"
    WORKSPACE_STATUS="CRIT"
  fi
done
if [ -z "$WORKSPACE_MISSING" ]; then
  WORKSPACE_DETAIL="All critical dirs present: /root/workspace, /root/.ollama, /usr/bin"
else
  WORKSPACE_DETAIL="MISSING:${WORKSPACE_MISSING}"
fi
print_status "Workspace Integrity" "$WORKSPACE_STATUS" "$WORKSPACE_DETAIL"
log_line "[Workspace] $WORKSPACE_STATUS - $WORKSPACE_DETAIL"

# --- 5) Top-3 Memory-consuming processes ---
echo ""
echo "--- Top-3 Memory Consumers ---"
# Use ps with --sort to get top 3 by RSS
ps -eo pid,rss,comm --sort=-rss | head -4 | while read pid rss comm; do
  if [ "$pid" = "PID" ]; then
    printf "%-8s %-10s %s\n" "PID" "RSS(KB)" "COMMAND"
    continue
  fi
  printf "%-8s %-10s %s\n" "$pid" "$rss" "$comm"
done
# Also log top 3
ps -eo pid,rss,comm --sort=-rss | head -4 | tail -3 | while read pid rss comm; do
  log_line "[TopProc] PID=$pid RSS=${rss}KB CMD=$comm"
done

# --- Summary ---
echo ""
OVERALL="OK"
[ "$DISK_STATUS" = "CRIT" ] && OVERALL="CRIT"
[ "$MEM_STATUS" = "CRIT" ] && OVERALL="CRIT"
[ "$CPU_STATUS" = "CRIT" ] && OVERALL="CRIT"
[ "$WORKSPACE_STATUS" = "CRIT" ] && OVERALL="CRIT"
[ "$DISK_STATUS" = "WARN" -o "$MEM_STATUS" = "WARN" -o "$CPU_STATUS" = "WARN" ] && [ "$OVERALL" != "CRIT" ] && OVERALL="WARN"

echo "=============================================="
echo " OVERALL STATUS: $OVERALL"
echo "=============================================="
log_line "[OVERALL] $OVERALL"
log_line ""

exit 0
