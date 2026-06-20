#!/bin/bash

# workspace_analyzer.sh - Analysiert Speicherbedarf und zeigt die 10 groessten Dateien/Verzeichnisse

echo "Analysiere Speicherbedarf im aktuellen Verzeichnis..."
echo ""

# Zeige die 10 groessten Dateien und Verzeichnisse an (maximale Tiefe 1 fuer bessere Performance)
# Begrenze die Laufzeit mit timeout und setze eine harte Grenze fuer die Anzahl der Eintraege
timeout 15s du -h --max-depth=1 . 2>/dev/null | sort -rh | head -n 10

# Falls das du-Kommando fehlschlaegt oder timeout ueberschreitet, zeige eine Meldung
if [ $? -ne 0 ]; then
  echo "Warnung: Analyse wurde abgebrochen oder dauerte zu lange."
fi

echo ""
echo "Analyse abgeschlossen."
