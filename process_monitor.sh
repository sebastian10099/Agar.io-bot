#!/bin/bash

# process_monitor.sh - Ueberwacht CPU- und RAM-Auslastung von Prozessen
# Ausgabe erfolgt nur bei Ueberschreitung der Schwellenwerte

# --- Konfiguration ---
CPU_THRESHOLD=80     # Warnung bei CPU-Auslastung ueber X Prozent pro Prozess
RAM_THRESHOLD=80     # Warnung bei RAM-Auslastung ueber X Prozent des Systems durch einen Prozess

# --- Funktionen ---

check_cpu_processes() {
  echo "[CPU] Pruefe Prozesse mit hoher CPU-Auslastung..."
  ps -eo pid,ppid,cmd,pcpu --sort=-pcpu | awk -v threshold=$CPU_THRESHOLD 'NR>1 && $4>threshold { printf "[WARN] Hohe CPU-Auslastung: PID=%s PPID=%s CMD=%s CPU=%s%%\n", $1, $2, $3, $4 }'
}

check_ram_processes() {
  echo "[RAM] Pruefe Prozesse mit hoher RAM-Auslastung..."
  ps -eo pid,ppid,cmd,pmem --sort=-pmem | awk -v threshold=$RAM_THRESHOLD 'NR>1 && $4>threshold { printf "[WARN] Hohe RAM-Auslastung: PID=%s PPID=%s CMD=%s RAM=%s%%\n", $1, $2, $3, $4 }'
}

# --- Hauptausfuehrung ---

echo "Prozess-Monitor gestartet"
check_cpu_processes
check_ram_processes
echo "Prozess-Monitor beendet"
