#!/bin/bash

# Backup Cleanup Script
# Löscht Backup-Verzeichnisse älter als 7 Tage

# Variablen
WORKSPACE_DIR="/root/local_agent/agent_workspace"
BACKUP_DIR="$WORKSPACE_DIR/backups"

# Prüfe ob Backup-Verzeichnis existiert
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Backup-Verzeichnis nicht gefunden: $BACKUP_DIR"
    exit 1
fi

# Finde und lösche Backup-Verzeichnisse älter als 7 Tage
echo "Suche nach Backup-Verzeichnissen älter als 7 Tage..."
OLD_BACKUPS=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name "backup_*" -mtime +7)

if [ -z "$OLD_BACKUPS" ]; then
    echo "Keine alten Backup-Verzeichnisse gefunden"
    exit 0
fi

# Zähle die zu löschenden Verzeichnisse
COUNT=$(echo "$OLD_BACKUPS" | wc -l)
echo "$COUNT alte Backup-Verzeichnisse gefunden"

# Lösche die alten Backup-Verzeichnisse
for dir in $OLD_BACKUPS; do
    echo "Lösche: $dir"
    rm -rf "$dir"
done

echo "Bereinigung abgeschlossen"
exit 0