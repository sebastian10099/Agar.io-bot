#!/bin/bash

# Skript zur Überwachung der Festplattenbelegung
# Warnung bei Belegung über 80% (Warnung) und 90% (kritisch)

# Schwellenwerte definieren
WARN_THRESHOLD=80
CRITICAL_THRESHOLD=90

# Exit-Codes
EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

# Status-Variable
exit_code=$EXIT_OK

# Funktion zum Testen mit simulierten Werten
function test_df_simulation() {
  echo "Testmodus: Simulierte Partitionen"
  echo "/dev/test1       100G   95G   5G  95% /test/critical"
  echo "/dev/test2       100G   85G  15G  85% /test/warning"
  echo "/dev/test3       100G   70G  30G  70% /test/normal"
}

# Prüfen, ob Testmodus aktiviert ist
if [[ "$1" == "--test" ]]; then
  # Testdaten verwenden
  while read line; do
    # Prozentwert extrahieren (ohne %-Zeichen)
    usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
    partition=$(echo "$line" | awk '{print $1}')
    mountpoint=$(echo "$line" | awk '{print $6}')
    
    # Überprüfen, ob usage eine Zahl ist
    if [[ $usage =~ ^[0-9]+$ ]]; then
      # Prüfung auf kritische Werte
      if [ "$usage" -ge "$CRITICAL_THRESHOLD" ]; then
        echo "KRITISCH: Partition $partition ($mountpoint) ist zu $usage% belegt"
        exit_code=$EXIT_CRITICAL
      elif [ "$usage" -ge "$WARN_THRESHOLD" ]; then
        echo "WARNUNG: Partition $partition ($mountpoint) ist zu $usage% belegt"
        # Nur auf WARNING setzen, wenn nicht bereits CRITICAL
        if [ $exit_code -lt $EXIT_CRITICAL ]; then
          exit_code=$EXIT_WARNING
        fi
      else
        echo "OK: Partition $partition ($mountpoint) ist zu $usage% belegt"
      fi
    fi
  done < <(test_df_simulation)
else
  # Normale Ausführung mit echten df-Daten
  while read line; do
    # Prozentwert extrahieren (ohne %-Zeichen)
    usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
    partition=$(echo "$line" | awk '{print $1}')
    mountpoint=$(echo "$line" | awk '{print $6}')
    
    # Überprüfen, ob usage eine Zahl ist
    if [[ $usage =~ ^[0-9]+$ ]]; then
      # Prüfung auf kritische Werte
      if [ "$usage" -ge "$CRITICAL_THRESHOLD" ]; then
        echo "KRITISCH: Partition $partition ($mountpoint) ist zu $usage% belegt"
        exit_code=$EXIT_CRITICAL
      elif [ "$usage" -ge "$WARN_THRESHOLD" ]; then
        echo "WARNUNG: Partition $partition ($mountpoint) ist zu $usage% belegt"
        # Nur auf WARNING setzen, wenn nicht bereits CRITICAL
        if [ $exit_code -lt $EXIT_CRITICAL ]; then
          exit_code=$EXIT_WARNING
        fi
      fi
    fi
  done < <(df -h | grep '^/dev/')
fi

# Exit mit entsprechendem Code
exit $exit_code
