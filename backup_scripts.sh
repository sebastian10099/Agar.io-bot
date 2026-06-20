#!/bin/bash

# backup_scripts.sh - Sichert alle .sh und .md Dateien im Workspace in ein Zeitstempel-Archiv

# Arbeitsverzeichnis setzen
WORKSPACE_DIR="/root/local_agent/agent_workspace"
BACKUP_DIR="$WORKSPACE_DIR/backups"

# Erstelle Backup-Verzeichnis falls nicht vorhanden
mkdir -p "$BACKUP_DIR"

# Erstelle Zeitstempel
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ARCHIVE_NAME="scripts_backup_$TIMESTAMP.tar.gz"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"

# Wechsel ins Workspace-Verzeichnis
cd "$WORKSPACE_DIR"

# Suche rekursiv alle .sh und .md Dateien und packe sie ins Archiv
find . -type f \( -name "*.sh" -o -name "*.md" \) | tar -czf "$ARCHIVE_PATH" -T -

# Prüfe ob Archiv erstellt wurde
if [ -f "$ARCHIVE_PATH" ]; then
  echo "Backup erfolgreich erstellt: $ARCHIVE_PATH"
  ls -lh "$ARCHIVE_PATH"
else
  echo "Fehler: Backup konnte nicht erstellt werden"
  exit 1
fi
