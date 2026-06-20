#!/bin/bash

# Log-Analyse-Skript
# Zaehlt die Anzahl der Eintraege pro Tag in den Log-Dateien im 'logs'-Verzeichnis

echo "Analysiere Log-Dateien im 'logs'-Verzeichnis..."

# Pruefe, ob das logs-Verzeichnis existiert
if [ ! -d "logs" ]; then
  echo "Fehler: Das Verzeichnis 'logs' existiert nicht."
  exit 1
fi

# Zaehle die Eintraege pro Tag in allen Log-Dateien
for logfile in logs/*.log; do
  if [ -f "$logfile" ]; then
    echo "Analyse von $logfile:"
    # Verwende awk, um das Datum aus dem ersten Feld jeder Zeile zu extrahieren und zu zaehlen
    awk '{print $1}' "$logfile" | sort | uniq -c | sort -nr
    echo ""
  fi
done

echo "Analyse abgeschlossen."
