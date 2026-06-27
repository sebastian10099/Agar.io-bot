#!/bin/bash
# Cleanup-Skript: Reduziert Backups auf max. 3 Einträge
# Priorisiert: Entferne größte Einträge zuerst

BACKUP_DIR="/root/local_agent/agent_workspace/backups"
cd "$BACKUP_DIR" || exit 1

# Liste nach Größe sortiert (größte zuerst)
entries=$(ls -1tS)

count=0
for entry in $entries; do
  count=$((count + 1))
  if [ "$count" -gt 3 ]; then
    echo "Entferne: $entry"
    rm -rf "$entry"
  fi
done

echo "Cleanup abgeschlossen. Aktuelle Anzahl Backups:"
ls -1 "$BACKUP_DIR" | wc -l
