#!/bin/bash

# Log Monitor Script
# Ueberwacht System-Logs auf Fehler und Warnungen

# Konfiguration
LOG_FILES=("/var/log/syslog" "/var/log/kern.log" "/var/log/auth.log" "/var/log/dmesg")
KEYWORDS=("error" "warning" "fail" "crit" "alert" "emerg")
ERROR_THRESHOLD=10
WARNING_THRESHOLD=50

# Funktion zur Analyse der Logs
analyze_logs() {
  local error_count=0
  local warning_count=0

  for log_file in "${LOG_FILES[@]}"; do
    if [[ -f "$log_file" ]]; then
      for keyword in "${KEYWORDS[@]}"; do
        # Zaehle Vorkommen des Schluesselworts (case-insensitive), ignoriere binaere Dateien
        count=$(grep -i "$keyword" "$log_file" 2>/dev/null | grep -v "binary file matches" | wc -l)
        if [[ $count -gt 0 ]]; then
          echo "[INFO] $count Vorkommen von '$keyword' in $log_file"
          if [[ "$keyword" == "error" || "$keyword" == "crit" || "$keyword" == "alert" || "$keyword" == "emerg" ]]; then
            ((error_count+=count))
          else
            ((warning_count+=count))
          fi
        fi
      done
    else
      echo "[WARN] Log-Datei nicht gefunden: $log_file"
    fi
  done

  echo ""
  echo "Zusammenfassung:"
  echo "Fehler: $error_count"
  echo "Warnungen: $warning_count"

  # Ueberpruefe Schwellenwerte
  if [[ $error_count -gt $ERROR_THRESHOLD ]]; then
    echo "[CRIT] Kritische Fehler gefunden! ($error_count > $ERROR_THRESHOLD)"
    exit 2
  elif [[ $warning_count -gt $WARNING_THRESHOLD ]]; then
    echo "[WARN] Viele Warnungen gefunden! ($warning_count > $WARNING_THRESHOLD)"
    exit 1
  elif [[ $error_count -gt 0 ]]; then
    echo "[OK] Fehler gefunden, aber unterhalb des kritischen Schwellenwerts."
    exit 0
  elif [[ $warning_count -gt 0 ]]; then
    echo "[OK] Warnungen gefunden, aber unterhalb des Warnschwellenwerts."
    exit 0
  else
    echo "[OK] Keine Fehler oder Warnungen gefunden."
    exit 0
  fi
}

# Hauptfunktion
main() {
  echo "Starte Log-Analyse..."
  analyze_logs
}

# Skript ausfuehren
main
