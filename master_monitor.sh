#!/bin/bash

# master_monitor.sh - Fuehrt alle Monitor-Skripte aus und fasst die Ergebnisse zusammen

# --- Konfiguration ---
SCRIPT_DIR="/root/local_agent/agent_workspace"

# --- Funktionen ---

run_process_monitor() {
  echo "=== Prozess-Monitor ==="
  "$SCRIPT_DIR/process_monitor.sh"
  echo ""
}

run_log_monitor() {
  echo "=== Log-Monitor ==="
  "$SCRIPT_DIR/log_monitor.sh"
  echo ""
}

run_disk_usage_monitor() {
  echo "=== Festplatten-Nutzung-Monitor ==="
  "$SCRIPT_DIR/disk_usage_monitor.sh"
  echo ""
}

# --- Hauptausfuehrung ---

echo "Master-Monitor gestartet"
echo "======================"

run_process_monitor
run_log_monitor
run_disk_usage_monitor

echo "======================"
echo "Master-Monitor beendet"
