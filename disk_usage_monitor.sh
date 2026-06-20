#!/bin/bash

# disk_usage_monitor.sh - Ueberwacht die Festplattenbelegung aller Partitionen
# Ausgabe erfolgt nur bei Ueberschreitung der Schwellenwerte

# --- Konfiguration ---
DISK_USAGE_THRESHOLD=80     # Warnung bei Belegung ueber X Prozent

# --- Funktionen ---

check_disk_usage() {
  echo "[DISK] Pruefe Partitionen mit hoher Belegung..."
  df -h | awk -v threshold=$DISK_USAGE_THRESHOLD 'NR>1 && !/^none$/ && !/^tmpfs$/ {
    usage=$5; gsub(/%/, "", usage);
    if (usage > threshold) {
      printf "[WARN] Hohe Festplattenbelegung: Filesystem=%s Size=%s Used=%s Avail=%s Usage=%s%% Mounted=%s\n", $1, $2, $3, $4, $5, $6
    }
  }'
}

# --- Hauptausfuehrung ---

echo "Disk-Monitor gestartet"
check_disk_usage
echo "Disk-Monitor beendet"
