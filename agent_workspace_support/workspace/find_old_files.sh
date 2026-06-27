#!/bin/bash

# Skript zur Identifikation alter Dateien im Workspace
# Zeigt die 10 Dateien mit dem aeltesten Zugriffszeitpunkt (atime) an

WORKSPACE_PATH="/root/local_agent/agent_workspace_support/workspace"

find "$WORKSPACE_PATH" -type f -exec stat -c "%X %n" {} \; | sort -n | head -10 | while read timestamp filepath; do
  # Konvertiere Unix-Timestamp in lesbares Datum
  accesstime=$(date -d @$timestamp +"%Y-%m-%d %H:%M:%S")
  echo "$accesstime | $filepath"
done
