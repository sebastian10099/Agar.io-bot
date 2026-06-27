#!/bin/bash

# Cleanup-Skript fuer alte Backups
# Loescht Backups aelter als 7 Tage

# Variablen
BACKUP_BASE_DIR="/root/local_agent/agent_workspace_support/workspace/backups"

# Loesche Backup-Verzeichnisse aelter als 7 Tage
find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +

echo "Alte Backups bereinigt."
