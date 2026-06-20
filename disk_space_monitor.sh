#!/bin/bash

# Disk Space Monitor
# Prueft Speicherplatz auf wichtigen Partitionen und warnt bei kritischen Schwellenwerten

# Konfiguration
WARNING_THRESHOLD=5
CRITICAL_THRESHOLD=7
LOG_FILE="/var/log/disk_space_monitor.log"

# Funktion fuer Logging
debug_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Funktion zur Pruefung des Speicherplatzes
check_disk_space() {
    debug_log "Starte Speicherplatzpruefung"
    
    # Pruefe alle relevanten Partitionen mit df
    df -h | grep -E '^(Filesystem|/dev/)' | while read line; do
        filesystem=$(echo $line | awk '{print $1}')
        usage_percent=$(echo $line | awk '{print $5}' | sed 's/%//')
        mount_point=$(echo $line | awk '{print $6}')
        
        # Nur fortfahren wenn es sich um eine Zahl handelt
        if [[ $usage_percent =~ ^[0-9]+$ ]]; then
            if [ $usage_percent -ge $CRITICAL_THRESHOLD ]; then
                message="KRITISCH: $filesystem ($mount_point) belegt zu $usage_percent%"
                echo "$message"
                debug_log "$message"
            elif [ $usage_percent -ge $WARNING_THRESHOLD ]; then
                message="WARNUNG: $filesystem ($mount_point) belegt zu $usage_percent%"
                echo "$message"
                debug_log "$message"
            else
                debug_log "OK: $filesystem ($mount_point) belegt zu $usage_percent%"
            fi
        fi
    done
    
    debug_log "Speicherplatzpruefung abgeschlossen"
}

# Hauptausfuehrung
check_disk_space
