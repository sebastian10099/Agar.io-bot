#!/bin/bash

# log_error_check.sh - Durchsucht System-Logs auf Fehler und Warnungen
# Autor: Haupt-Agent
# Zweck: Ergänzt das Monitoring um eine Log-Analyse-Ebene

# Farbdefinitionen für die Ausgabe
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Standard-Log-Dateien
LOG_FILES=(
  "/var/log/syslog"
  "/var/log/kern.log"
  "/var/log/dmesg"
  "/var/log/auth.log"
)

# Suchbegriffe für Fehler und Warnungen
ERROR_PATTERNS=(
  "error"
  "failed"
  "failure"
  "critical"
  "unable"
  "denied"
  "fault"
)

WARNING_PATTERNS=(
  "warning"
  "warn"
  "slow"
  "timeout"
  "retry"
  "restarting"
  "degraded"
)

# Funktion zur Überprüfung, ob eine Datei binär ist
is_binary() {
  local file=$1
  if [[ -f "$file" ]]; then
    # Prüfe die ersten 1024 Bytes der Datei
    if LC_ALL=C grep -q -m 1 '[^[:print:][:space:]\t]' <(dd if="$file" bs=1024 count=1 2>/dev/null); then
      return 0  # Ist binär
    else
      return 1  # Ist nicht binär
    fi
  else
    return 1  # Datei existiert nicht
  fi
}

# Funktion zur Analyse einer Log-Datei
analyze_log() {
  local log_file=$1
  local file_name=$(basename "$log_file")
  
  # Überspringe binäre Dateien
  if is_binary "$log_file"; then
    echo "=== Skipping binary file $file_name ==="
    echo ""
    return
  fi
  
  echo "=== Analyzing $file_name ==="
  
  # Zähle Fehler
  local error_count=0
  for pattern in "${ERROR_PATTERNS[@]}"; do
    local count=$(grep -i "$pattern" "$log_file" 2>/dev/null | wc -l)
    error_count=$((error_count + count))
  done
  
  # Zähle Warnungen
  local warning_count=0
  for pattern in "${WARNING_PATTERNS[@]}"; do
    local count=$(grep -i "$pattern" "$log_file" 2>/dev/null | wc -l)
    warning_count=$((warning_count + count))
  done
  
  # Gib Ergebnisse aus
  if [ $error_count -gt 0 ]; then
    echo -e "${RED}ERRORS: $error_count${NC}"
  else
    echo -e "${GREEN}ERRORS: $error_count${NC}"
  fi
  
  if [ $warning_count -gt 0 ]; then
    echo -e "${YELLOW}WARNINGS: $warning_count${NC}"
  else
    echo -e "${GREEN}WARNINGS: $warning_count${NC}"
  fi
  
  # Zeige einige Beispiele, falls Fehler oder Warnungen gefunden wurden
  if [ $error_count -gt 0 ] || [ $warning_count -gt 0 ]; then
    echo "Sample entries:"
    # Zeige die 3 neuesten Fehler/Warnungen
    grep -i -E "($(IFS='|'; echo "${ERROR_PATTERNS[*]}"))|($(IFS='|'; echo "${WARNING_PATTERNS[*]}"))" "$log_file" 2>/dev/null | tail -3
  fi
  
  echo ""
}

# Hauptfunktion
main() {
  echo "System Log Error and Warning Check"
  echo "==================================="
  
  # Prüfe, ob Log-Dateien existieren
  for log_file in "${LOG_FILES[@]}"; do
    if [ -f "$log_file" ]; then
      analyze_log "$log_file"
    else
      echo "=== Skipping $log_file (not found) ==="
      echo ""
    fi
  done
  
  # Gesamtergebnis
  echo "Summary:"
  echo "========="
  local total_errors=0
  local total_warnings=0
  
  for log_file in "${LOG_FILES[@]}"; do
    if [ -f "$log_file" ]; then
      # Überspringe binäre Dateien
      if is_binary "$log_file"; then
        continue
      fi
      
      for pattern in "${ERROR_PATTERNS[@]}"; do
        local count=$(grep -i "$pattern" "$log_file" 2>/dev/null | wc -l)
        total_errors=$((total_errors + count))
      done
      
      for pattern in "${WARNING_PATTERNS[@]}"; do
        local count=$(grep -i "$pattern" "$log_file" 2>/dev/null | wc -l)
        total_warnings=$((total_warnings + count))
      done
    fi
  done
  
  if [ $total_errors -gt 0 ]; then
    echo -e "${RED}TOTAL ERRORS: $total_errors${NC}"
  else
    echo -e "${GREEN}TOTAL ERRORS: $total_errors${NC}"
  fi
  
  if [ $total_warnings -gt 0 ]; then
    echo -e "${YELLOW}TOTAL WARNINGS: $total_warnings${NC}"
  else
    echo -e "${GREEN}TOTAL WARNINGS: $total_warnings${NC}"
  fi
  
  # Exit-Code basierend auf Ergebnissen
  if [ $total_errors -gt 0 ]; then
    exit 2  # CRITICAL
  elif [ $total_warnings -gt 0 ]; then
    exit 1  # WARNING
  else
    exit 0  # OK
  fi
}

# Skript ausführen
main
