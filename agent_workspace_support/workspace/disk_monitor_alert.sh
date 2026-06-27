#!/bin/bash
# disk_monitor_alert.sh - Leichtgewichtiges Disk-Monitoring mit Fruehwarnung
# Erstellt als vorbeugende Massnahme nach der 94%-Speicherkrise.
# Prueft df -h, warnt bei >80% Auslastung und listet Top-5 Speicherfresser.

set -euo pipefail

# Konfiguration
THRESHOLD=80
WORKSPACE_DIR="${WORKSPACE_DIR:-/root/local_agent/agent_workspace_support/workspace}"
LOG_FILE="${LOG_FILE:-/root/local_agent/agent_workspace_support/workspace/disk_monitor.log}"

# --- Hilfsfunktion: Logging ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# --- 1. Disk-Auslastung pruefen ---
log "=== Disk Monitor Alert - Start ==="

disk_info=$(df -h / 2>/dev/null | tail -1)
disk_percent_raw=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')
disk_used=$(echo "$disk_info" | awk '{print $3}')
disk_total=$(echo "$disk_info" | awk '{print $2}')
disk_avail=$(echo "$disk_info" | awk '{print $4}')

log "Disk: ${disk_used} used / ${disk_total} total / ${disk_avail} avail / ${disk_percent_raw}%"

if [ -z "$disk_percent_raw" ] || ! [[ "$disk_percent_raw" =~ ^[0-9]+$ ]]; then
    log "FEHLER: Konnte Disk-Prozent nicht ermitteln. df-Ausgabe: $disk_info"
    exit 1
fi

# --- 2. Warnung bei Ueberschreitung des Schwellwerts ---
if [ "$disk_percent_raw" -ge "$THRESHOLD" ]; then
    log "WARNUNG: Speicherauslastung ${disk_percent_raw}% >= ${THRESHOLD}% Schwellwert!"
    log "--- Top-5 groesste Dateien/Verzeichnisse im Workspace ---"

    # Top-5 groesste Einzeldateien (schnell, kein Timeout-Risiko)
    log "[Top-5 Dateien nach Groesse]:"
    find "$WORKSPACE_DIR" -type f -exec ls -lhS {} + 2>/dev/null \
        | sort -k5 -rh \
        | head -5 \
        | awk '{printf "  %s  %s\n", $5, $9}' \
        | tee -a "$LOG_FILE" || log "  (Keine Dateien gefunden oder Fehler)"

    # Top-5 groesste Verzeichnisse (mit Timeout-Schutz)
    log "[Top-5 Verzeichnisse nach Groesse]:"
    timeout 30 du -sh "$WORKSPACE_DIR"/*/ 2>/dev/null \
        | sort -rh \
        | head -5 \
        | tee -a "$LOG_FILE" || log "  (Verzeichnis-Scan abgebrochen/leer)"

    log "WARNUNG: Bitte Speicher bereinigen! Siehe disk_monitor.log fuer Details."
else
    log "OK: Speicherauslastung ${disk_percent_raw}% unter Schwellwert ${THRESHOLD}%."
fi

log "=== Disk Monitor Alert - Ende ==="
exit 0
