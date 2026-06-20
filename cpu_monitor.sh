#!/bin/bash

# CPU-Überwachungsskript

# Schwellenwerte (in Prozent)
CPU_WARN_THRESHOLD=70
CPU_CRITICAL_THRESHOLD=85

# Test-Modus erkennen
if [ "$1" == "--test" ]; then
  echo "=== CPU-Überwachung (TEST-MODUS) ==="
  
  # Testfälle definieren
  TEST_CASES=(
    "OK:CPU=50"
    "WARN:CPU=75"
    "CRIT:CPU=90"
  )
  
  for TEST_CASE in "${TEST_CASES[@]}"; do
    IFS=':' read -r TEST_NAME VALUES <<< "$TEST_CASE"
    IFS='=' read -r _ CPU_USAGE_PCT <<< "$VALUES"
    
    echo -e "\n--- Testfall: $TEST_NAME ---"
    echo "CPU: ${CPU_USAGE_PCT}%"
    
    # Warnungen prüfen
    if [ "$CPU_USAGE_PCT" -ge "$CPU_CRITICAL_THRESHOLD" ]; then
      echo "[KRITISCH] CPU-Auslastung sehr hoch: $CPU_USAGE_PCT%"
    elif [ "$CPU_USAGE_PCT" -ge "$CPU_WARN_THRESHOLD" ]; then
      echo "[WARNUNG] CPU-Auslastung erhöht: $CPU_USAGE_PCT%"
    else
      echo "[OK] CPU-Auslastung normal: $CPU_USAGE_PCT%"
    fi
  done
  
  exit 0
fi

# Normale Ausführung

# CPU-Auslastung abrufen (in Prozent)
CPU_USAGE_PCT=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//' | cut -d'.' -f1)

# Ergebnis ausgeben
echo "=== CPU-Überwachung ==="
echo "CPU-Auslastung: $CPU_USAGE_PCT%"

# Warnungen prüfen
if [ "$CPU_USAGE_PCT" -ge "$CPU_CRITICAL_THRESHOLD" ]; then
  echo "[KRITISCH] CPU-Auslastung sehr hoch: $CPU_USAGE_PCT%"
elif [ "$CPU_USAGE_PCT" -ge "$CPU_WARN_THRESHOLD" ]; then
  echo "[WARNUNG] CPU-Auslastung erhöht: $CPU_USAGE_PCT%"
fi
