#!/bin/bash

# memory_check.sh - Ueberwacht die Speicherauslastung und gibt Warnungen bei hoher Nutzung aus.

# Speicherinformationen abrufen (in KB)
mem_info=$(free | grep Mem)
total_mem=$(echo $mem_info | awk '{print $2}')
used_mem=$(echo $mem_info | awk '{print $3}')

# Auslastung in Prozent berechnen
mem_usage_percent=$((used_mem * 100 / total_mem))

# Warnung bei hoher Auslastung (> 80%)
echo "Arbeitsspeicherstatus:"
echo "Gesamt: $total_mem KB"
echo "Genutzt: $used_mem KB"
echo "Auslastung: $mem_usage_percent%"

if [ $mem_usage_percent -gt 80 ]; then
  echo "WARNUNG: Hohe Speicherauslastung! ($mem_usage_percent%)"
else
  echo "Speicherauslastung ist normal."
fi
