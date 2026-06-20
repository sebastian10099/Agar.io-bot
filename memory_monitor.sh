#!/bin/bash

# Speicherüberwachungsskript

# Schwellenwerte (in Prozent)
RAM_WARN_THRESHOLD=80
RAM_CRITICAL_THRESHOLD=90
SWAP_WARN_THRESHOLD=50
SWAP_CRITICAL_THRESHOLD=75

# Test-Modus erkennen
if [ "$1" == "--test" ]; then
  echo "=== Speicherüberwachung (TEST-MODUS) ==="
  
  # Testfälle definieren
  TEST_CASES=(
    "OK_RAM_OK_SWAP:RAM=40,SWAP=30"
    "WARN_RAM_OK_SWAP:RAM=85,SWAP=30"
    "CRIT_RAM_OK_SWAP:RAM=95,SWAP=30"
    "OK_RAM_WARN_SWAP:RAM=40,SWAP=60"
    "OK_RAM_CRIT_SWAP:RAM=40,SWAP=80"
    "WARN_RAM_WARN_SWAP:RAM=85,SWAP=60"
    "CRIT_RAM_CRIT_SWAP:RAM=95,SWAP=80"
  )
  
  for TEST_CASE in "${TEST_CASES[@]}"; do
    IFS=':' read -r TEST_NAME VALUES <<< "$TEST_CASE"
    IFS=',' read -r RAM_PART SWAP_PART <<< "$VALUES"
    IFS='=' read -r _ RAM_USAGE_PCT <<< "$RAM_PART"
    IFS='=' read -r _ SWAP_USAGE_PCT <<< "$SWAP_PART"
    
    echo "\n--- Testfall: $TEST_NAME ---"
    echo "RAM: ${RAM_USAGE_PCT}%"
    echo "Swap: ${SWAP_USAGE_PCT}%"
    echo ""
    
    # Warnungen prüfen
    if [ "$RAM_USAGE_PCT" -ge "$RAM_CRITICAL_THRESHOLD" ]; then
      echo "[KRITISCH] RAM-Auslastung sehr hoch: $RAM_USAGE_PCT%"
    elif [ "$RAM_USAGE_PCT" -ge "$RAM_WARN_THRESHOLD" ]; then
      echo "[WARNUNG] RAM-Auslastung erhöht: $RAM_USAGE_PCT%"
    else
      echo "[OK] RAM-Auslastung normal: $RAM_USAGE_PCT%"
    fi
    
    if [ "$SWAP_USAGE_PCT" -ge "$SWAP_CRITICAL_THRESHOLD" ]; then
      echo "[KRITISCH] Swap-Auslastung sehr hoch: $SWAP_USAGE_PCT%"
    elif [ "$SWAP_USAGE_PCT" -ge "$SWAP_WARN_THRESHOLD" ]; then
      echo "[WARNUNG] Swap-Auslastung erhöht: $SWAP_USAGE_PCT%"
    else
      echo "[OK] Swap-Auslastung normal: $SWAP_USAGE_PCT%"
    fi
  done
  
  exit 0
fi

# Normale Ausführung

# Speicherdaten abrufen (in KB)
MEM_INFO=$(free | grep -E '^(Mem|Swap):')

# RAM-Werte extrahieren
RAM_TOTAL=$(echo "$MEM_INFO" | grep Mem | awk '{print $2}')
RAM_USED=$(echo "$MEM_INFO" | grep Mem | awk '{print $3}')

# Swap-Werte extrahieren
SWAP_TOTAL=$(echo "$MEM_INFO" | grep Swap | awk '{print $2}')
SWAP_USED=$(echo "$MEM_INFO" | grep Swap | awk '{print $3}')

# Prozentsätze berechnen
if [ "$RAM_TOTAL" -gt 0 ]; then
  RAM_USAGE_PCT=$((RAM_USED * 100 / RAM_TOTAL))
else
  RAM_USAGE_PCT=0
fi

if [ "$SWAP_TOTAL" -gt 0 ]; then
  SWAP_USAGE_PCT=$((SWAP_USED * 100 / SWAP_TOTAL))
else
  SWAP_USAGE_PCT=0
fi

# Ergebnisse ausgeben
echo "=== Speicherüberwachung ==="
echo "RAM: $RAM_USED / $RAM_TOTAL KB ($RAM_USAGE_PCT%)"
echo "Swap: $SWAP_USED / $SWAP_TOTAL KB ($SWAP_USAGE_PCT%)"
echo ""

# Warnungen prüfen
if [ "$RAM_USAGE_PCT" -ge "$RAM_CRITICAL_THRESHOLD" ]; then
  echo "[KRITISCH] RAM-Auslastung sehr hoch: $RAM_USAGE_PCT%"
elif [ "$RAM_USAGE_PCT" -ge "$RAM_WARN_THRESHOLD" ]; then
  echo "[WARNUNG] RAM-Auslastung erhöht: $RAM_USAGE_PCT%"
fi

if [ "$SWAP_USAGE_PCT" -ge "$SWAP_CRITICAL_THRESHOLD" ]; then
  echo "[KRITISCH] Swap-Auslastung sehr hoch: $SWAP_USAGE_PCT%"
elif [ "$SWAP_USAGE_PCT" -ge "$SWAP_WARN_THRESHOLD" ]; then
  echo "[WARNUNG] Swap-Auslastung erhöht: $SWAP_USAGE_PCT%"
fi
