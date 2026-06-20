#!/bin/bash

# cleanup_report.sh - Identifiziert alte temporäre Dateien und potenzielle Aufräum-Kandidaten
# Ohne tatsächliche Löschung - nur zur Information

# Konfiguration
AGE_THRESHOLD=7
LARGE_FILE_THRESHOLD=100M

# Workspace-Pfad (aktuelles Verzeichnis)
WORKSPACE=$(pwd)

# Funktion zur Ausgabe von Informationen
echo "=== Cleanup Report for Workspace: $WORKSPACE ==="
echo "Date: $(date)"
echo "Age threshold: $AGE_THRESHOLD days"
echo "Large file threshold: $LARGE_FILE_THRESHOLD"
echo ""

echo "=== Temporary files older than $AGE_THRESHOLD days ==="
find "$WORKSPACE" \( -name "*.tmp" -o -name "*.temp" -o -name "~*" -o -name "*.bak" -o -name "*.log" \) -type f -mtime +$AGE_THRESHOLD 2>/dev/null | head -20

echo ""
echo "=== Large files (potential cleanup candidates) ==="
find "$WORKSPACE" -type f -size +$LARGE_FILE_THRESHOLD 2>/dev/null | head -20

echo ""
echo "=== Duplicate files (potential cleanup candidates) ==="
# Verwende fdupes falls verfügbar, ansonsten Hinweis
if command -v fdupes &> /dev/null; then
    fdupes -r "$WORKSPACE" 2>/dev/null | head -50
else
    echo "fdupes not installed - skipping duplicate check"
fi

echo ""
echo "=== Empty directories ==="
find "$WORKSPACE" -type d -empty 2>/dev/null | head -20

echo ""
echo "=== End of Report ==="