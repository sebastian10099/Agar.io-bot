#!/bin/bash

# Workspace Backup Script
# Sichert wichtige Dateien in ein Zeitstempel-Verzeichnis

# Variablen
WORKSPACE_DIR="/root/local_agent/agent_workspace"
BACKUP_DIR="$WORKSPACE_DIR/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_TARGET="$BACKUP_DIR/backup_$TIMESTAMP"

# Erstelle Backup-Verzeichnis
mkdir -p "$BACKUP_TARGET"

# Kopiere alle .sh Dateien und README.md
cp $WORKSPACE_DIR/*.sh "$BACKUP_TARGET/" 2>/dev/null
cp $WORKSPACE_DIR/README.md "$BACKUP_TARGET/" 2>/dev/null

# Prüfe ob Dateien kopiert wurden
if [ -n "$(ls -A $BACKUP_TARGET)" ]; then
    echo "Backup erfolgreich erstellt in: $BACKUP_TARGET"
    exit 0
else
    echo "Keine Dateien zum Sichern gefunden"
    exit 1
fi