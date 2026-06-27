#!/bin/bash

# Backup-Skript fuer Workspace-Dateien
# Erstellt ein datiertes Backup wichtiger Dateien

# Variablen
BACKUP_DIR="/root/local_agent/agent_workspace_support/workspace/backups/$(date +%Y%m%d_%H%M%S)"
WORKSPACE_DIR="/root/local_agent/agent_workspace_support/workspace"

# Erstelle Backup-Verzeichnis
mkdir -p "$BACKUP_DIR"

echo "Erstelle Backup in: $BACKUP_DIR"

# Kopiere Shell-Skripte (ausser aus dem Backup-Verzeichnis)
find "$WORKSPACE_DIR" -path "$WORKSPACE_DIR/backups" -prune -o -name "*.sh" -type f -exec cp {} "$BACKUP_DIR" \;

# Kopiere Log-Dateien (ausser aus dem Backup-Verzeichnis)
find "$WORKSPACE_DIR" -path "$WORKSPACE_DIR/backups" -prune -o -name "*.log" -type f -exec cp {} "$BACKUP_DIR" \;

# Kopiere Markdown-Dokumentation (ausser aus dem Backup-Verzeichnis)
find "$WORKSPACE_DIR" -path "$WORKSPACE_DIR/backups" -prune -o -name "*.md" -type f -exec cp {} "$BACKUP_DIR" \;

# Kopiere Python-Skripte (ausser aus dem Backup-Verzeichnis)
find "$WORKSPACE_DIR" -path "$WORKSPACE_DIR/backups" -prune -o -name "*.py" -type f -exec cp {} "$BACKUP_DIR" \;

echo "Backup abgeschlossen."
