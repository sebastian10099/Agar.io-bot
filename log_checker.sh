#!/bin/bash

# Definiere Suchbegriffe
SEARCH_TERMS=("error" "warning" "failed")

# Funktion zur sicheren Ausgabe von Log-Einträgen
print_log_entries() {
  local term=$1
  echo "=== Suchergebnisse für: $term ==="
  # Verwende Text-Only Modus, ignoriere Binärdatei-Warnungen
  grep -h -i --binary-files=text "$term" /var/log/syslog | \
    head -n 5 | \
    while IFS= read -r line; do
      # Extrahiere nur die wichtigsten Teile (Datum, Service, Nachricht)
      echo "$line" | cut -d' ' -f1-6 | tr -s ' '
    done
  echo ""
}

# Initialisiere Gesamtzähler
TOTAL_COUNTS=()

# Suche in /var/log/syslog und zähle Treffer
for term in "${SEARCH_TERMS[@]}"
do
  count=$(grep -i --binary-files=text "$term" /var/log/syslog | wc -l)
  TOTAL_COUNTS+=("$term:$count")
  echo "Anzahl '$term'-Einträge: $count"
  print_log_entries "$term"
done

# Abschließende Zusammenfassung
echo "=== ZUSAMMENFASSUNG ==="
for entry in "${TOTAL_COUNTS[@]}"
do
  term=${entry%%:*}
  count=${entry#*:}
  echo "'$term': $count Treffer"
done

# Einfache Empfehlungen zur weiteren Analyse
echo "\n=== EMPFEHLUNGEN ==="
echo "1. Prüfen Sie die vollständigen Log-Einträge mit: grep -i 'error\|warning\|failed' /var/log/syslog"
echo "2. Für detaillierte Fehleranalyse: tail -f /var/log/syslog"
echo "3. Systematische Fehlersuche: journalctl -f"
echo "4. Bei wiederkehrenden Fehlern: Erwägen Sie die Einrichtung eines Monitoring-Tools"
