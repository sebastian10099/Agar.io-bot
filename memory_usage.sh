#!/bin/bash

# memory_usage.sh - Ueberwachung der Speicher-/RAM-Auslastung
# Zeigt verwendeten/freien Speicher, Swap-Nutzung und Top-Prozesse nach Speicherverbrauch

show_memory_usage() {
  echo "=== RAM-Auslastung ==="
  free -h | grep -E '^(Mem|Speicher)'
  echo
}

show_swap_usage() {
  echo "=== Swap-Nutzung ==="
  free -h | grep -E '^(Swap|Auslagerungsdatei)'
  echo
}

show_top_processes() {
  echo "=== Top 5 Prozesse nach Speicherverbrauch ==="
  ps aux --sort=-%mem | head -n 6
  echo
}

show_summary() {
  echo "=== Zusammenfassung ==="
  mem_used=$(free | grep -E '^(Mem|Speicher)' | awk '{print $3/$2 * 100.0}')
  swap_used=$(free | grep -E '^(Swap|Auslagerungsdatei)' | awk '{print $3/$2 * 100.0}')
  echo "RAM-Auslastung: ${mem_used}%"
  echo "Swap-Nutzung: ${swap_used}%"
  echo
}

echo "=== Speicheruebersicht ==="
echo
show_memory_usage
show_swap_usage
show_top_processes
show_summary