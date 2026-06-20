#!/bin/bash

# Komplexeres Benchmark-Skript: Erzeugt höhere Systembelastung

TIME_LIMIT=${1:-30}  # Laufzeit in Sekunden

stress() {
  local duration=$1
  local end_time=$(($(date +%s) + duration))
  
  echo "Starte Stress-Test für $duration Sekunden..."
  
  # Starte mehrere Prozesse, die rechenintensive Aufgaben durchführen
  for i in {1..4}; do
    (
      while [ $(date +%s) -lt $end_time ]; do
        # Rechenintensive Schleife
        echo "scale=10; 4*a(1)" | bc -l > /dev/null
      done
    ) &
  done
  
  # Warte bis alle Prozesse beendet sind
  wait
  
  echo "Stress-Test abgeschlossen."
}

stress $TIME_LIMIT
