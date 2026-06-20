#!/bin/bash

# health_summary.sh - Zentrales Werkzeug fuer schnelle System-Ueberpruefung
# Fuehrt alle vorhandenen Monitoring-Skripte nacheinander aus und zeigt einen kompakten Gesamtbericht

echo "========================================="
echo "         SYSTEM HEALTH SUMMARY           "
echo "========================================="
echo

# System Health Check
echo "=== System Health ==="
if [ -f "system_health.sh" ] && [ -x "system_health.sh" ]; then
  ./system_health.sh
else
  echo "System Health Check nicht verfuegbar"
fi
echo

# Log Check
echo "=== Log Check ==="
if [ -f "log_checker.sh" ] && [ -x "log_checker.sh" ]; then
  ./log_checker.sh
else
  echo "Log Check nicht verfuegbar"
fi
echo

# Process Monitor
echo "=== Process Monitor ==="
if [ -f "process_monitor.sh" ] && [ -x "process_monitor.sh" ]; then
  ./process_monitor.sh
else
  echo "Process Monitor nicht verfuegbar"
fi
echo

# Disk Usage Monitor
echo "=== Disk Usage Monitor ==="
if [ -f "disk_usage_monitor.sh" ] && [ -x "disk_usage_monitor.sh" ]; then
  ./disk_usage_monitor.sh
else
  echo "Disk Usage Monitor nicht verfuegbar"
fi
echo

echo "========================================="
echo "       Ueberpruefung abgeschlossen       "
echo "========================================="
