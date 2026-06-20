#!/bin/bash

# old_files_analysis.sh - Analysiert alte Dateien im System

echo "=== Alte Dateien Analyse (älter als 30 Tage) ==="
echo "Suche gestartet: $(date)"
echo ""

# Finde Dateien älter als 30 Tage
echo "Dateien älter als 30 Tage:"
find /root -type f -mtime +30 -not -path "/root/.cache/*" -not -path "/root/.local/share/Trash/*" 2>/dev/null | head -20

echo ""
echo "Große alte Dateien (älter als 30 Tage, sortiert nach Größe):"
find /root -type f -mtime +30 -exec ls -lh {} \; 2>/dev/null | awk '{print $5, $9}' | sort -hr | head -10

echo ""
echo "Verzeichnisse mit vielen alten Dateien:"
find /root -type d -mtime +30 2>/dev/null | head -10

echo ""
echo "Analyse abgeschlossen: $(date)"