#!/bin/bash

# Workspace Dashboard - Uebersicht aller wichtigen Informationen
# Generiert am: $(date)

echo "=== Workspace Dashboard ==="
echo "Erstellt am: $(date)"
echo ""

echo "[1] Workspace-Informationen"
echo "------------------------"
SCRIPT_COUNT=$(find /root/local_agent/agent_workspace -name "*.sh" | wc -l)
echo "Anzahl Shell-Skripte: $SCRIPT_COUNT"
echo ""

echo "[2] Backup-Status"
echo "----------------"
WORKSPACE="/root/workspace"
BACKUP_PATTERN="backup*"

# Finde alle Backup-Verzeichnisse
BACKUP_DIRS=$(find "$WORKSPACE" -maxdepth 1 -type d -name "$BACKUP_PATTERN" | sort)

# Anzahl der Backups
BACKUP_COUNT=$(echo "$BACKUP_DIRS" | grep -c .)
echo "Anzahl Backup-Verzeichnisse: $BACKUP_COUNT"

if [ $BACKUP_COUNT -eq 0 ]; then
  echo "Keine Backup-Verzeichnisse gefunden."
else
  # Gesamtgröße berechnen
  TOTAL_SIZE=0
  for dir in $BACKUP_DIRS; do
    SIZE=$(du -sb "$dir" | cut -f1)
    TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
  done
  
  # Größe in menschenlesbarem Format umwandeln
  TOTAL_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B $TOTAL_SIZE)
  echo "Gesamtgröße aller Backups: $TOTAL_SIZE_HUMAN"
  
  # Neuestes Backup finden
  NEWEST_BACKUP=$(echo "$BACKUP_DIRS" | tail -n 1)
  NEWEST_NAME=$(basename "$NEWEST_BACKUP")
  NEWEST_DATE=$(stat -c %y "$NEWEST_BACKUP" | cut -d'.' -f1)
  echo "Neuestes Backup: $NEWEST_NAME (Erstellt: $NEWEST_DATE)"
fi
echo ""
