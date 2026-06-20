#!/bin/bash

# Performance Monitoring Script

# Datei zum Speichern der Metriken
OUTPUT_FILE="performance_log.txt"

# Funktion zur präzisen Berechnung der CPU-Auslastung
get_cpu_usage() {
    grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print usage}'
}

# Aktuelles Datum und Uhrzeit
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# CPU-Auslastung (präzise)
CPU_USAGE=$(get_cpu_usage)

# RAM-Auslastung
RAM_USAGE=$(free | grep Mem | awk '{printf("%.2f"), $3/$2 * 100.0}')

# Laufzeit des Systems
UPTIME=$(uptime | awk -F'up' '{print $2}' | awk -F',' '{print $1}')

# Metriken in die Datei schreiben
echo "[$TIMESTAMP] CPU: ${CPU_USAGE}%, RAM: ${RAM_USAGE}%, Uptime: $UPTIME" >> $OUTPUT_FILE
