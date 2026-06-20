#!/bin/bash

# Skript zur effizienten Analyse der Speicherbelegung im Home-Verzeichnis

HOME_DIR="/root"

echo "=== Home-Verzeichnis: $HOME_DIR ==="

# Größte Verzeichnisse im Home-Verzeichnis anzeigen (Top 10, max-depth=1)
echo "=== Top 10 größte Verzeichnisse im Home-Bereich ==="
du -h --max-depth=1 "$HOME_DIR" 2>/dev/null | sort -hr | head -n 10

echo ""

# Größte einzelne Dateien im Home-Bereich anzeigen (nur Dateien > 10M)
echo "=== Große Dateien (>10MB) im Home-Bereich ==="
find "$HOME_DIR" -type f -size +10M -exec du -h {} + 2>/dev/null | sort -hr

echo ""

# Gesamtgröße des Home-Verzeichnisses
echo "=== Gesamtgröße des Home-Verzeichnisses ==="
du -sh "$HOME_DIR" 2>/dev/null

echo ""

echo "=== Debug: Anzahl aller Dateien im Home-Bereich ==="
find "$HOME_DIR" -type f 2>/dev/null | wc -l
