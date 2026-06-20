#!/bin/bash

# health_check.sh - Kombiniert verschiedene Diagnose-Skripte zu einem Gesundheitsbericht

function run_check() {
  local script_name=$1
  local check_name=$2
  local test_mode=$3
  
  echo -e "\n$check_name"
  echo "-------------------"
  
  # Ausfuehrung mit Timeout, um haengende Skripte abzufangen
  # Ausgabe anzeigen, Fehlercode ignorieren
  if [ "$test_mode" = "--test" ]; then
    timeout 30s ./$script_name --test
  else
    timeout 30s ./$script_name
  fi
  local exit_code=$?
  
  if [ $exit_code -eq 124 ]; then
    echo "FEHLER: $script_name hat das Zeitlimit von 30 Sekunden ueberschritten und wurde abgebrochen."
  fi
}

# Test-Modus erkennen
if [ "$1" == "--test" ]; then
  echo "========================================="
  echo "SYSTEM HEALTH CHECK REPORT (TEST MODE)"
  echo "========================================="
  
  run_check "disk_usage_alert.sh" "1. DISK USAGE CHECK" "--test"
  run_check "memory_monitor.sh" "2. MEMORY USAGE CHECK" "--test"
  run_check "cpu_monitor.sh" "3. CPU USAGE CHECK" "--test"
  run_check "process_monitor.sh" "4. PROCESS MONITORING CHECK" "--test"
  run_check "log_error_check.sh" "5. LOG ERROR CHECK" "--test"
  run_check "security_audit.sh" "6. SECURITY AUDIT CHECK" "--test"
  run_check "workspace_backup.sh" "7. WORKSPACE BACKUP CHECK" "--test"
  run_check "backup_cleanup.sh" "8. BACKUP CLEANUP CHECK" "--test"
  run_check "service_status.sh" "9. SERVICE STATUS CHECK" "--test"
  run_check "disk_space_monitor.sh" "10. DISK SPACE MONITOR CHECK" "--test"
  
  echo -e "\n========================================="
  echo "END OF TEST REPORT"
  echo "========================================="
else
  echo "========================================="
  echo "SYSTEM HEALTH CHECK REPORT"
  echo "========================================="
  
  run_check "disk_usage_alert.sh" "1. DISK USAGE CHECK"
  run_check "memory_monitor.sh" "2. MEMORY USAGE CHECK"
  run_check "cpu_monitor.sh" "3. CPU USAGE CHECK"
  run_check "process_monitor.sh" "4. PROCESS MONITORING CHECK"
  run_check "log_error_check.sh" "5. LOG ERROR CHECK"
  run_check "security_audit.sh" "6. SECURITY AUDIT CHECK"
  run_check "workspace_backup.sh" "7. WORKSPACE BACKUP CHECK"
  run_check "backup_cleanup.sh" "8. BACKUP CLEANUP CHECK"
  run_check "service_status.sh" "9. SERVICE STATUS CHECK"
  run_check "disk_space_monitor.sh" "10. DISK SPACE MONITOR CHECK"
  
  echo -e "\n========================================="
  echo "END OF REPORT"
  echo "========================================="
fi