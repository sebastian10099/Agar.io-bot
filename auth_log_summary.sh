#!/bin/bash

# Auth Log Summary Script
# Analysiert wiederkehrende Fehlermuster in /var/log/auth.log

AUTH_LOG="/var/log/auth.log"

# Funktion zur Identifizierung fehlgeschlagener SSH-Anmeldeversuche
analyze_failed_ssh_attempts() {
  echo "=== Fehlgeschlagene SSH-Anmeldeversuche ==="
  grep "Failed password" $AUTH_LOG | awk '{print $9}' | sort | uniq -c | sort -nr | head -10
  echo ""
}

# Funktion zur Identifizierung ungültiger Benutzer
analyze_invalid_users() {
  echo "=== Ungültige Benutzer (Invalid Users) ==="
  grep "Invalid user" $AUTH_LOG | awk '{print $8}' | sort | uniq -c | sort -nr | head -10
  echo ""
}

# Funktion zur Identifizierung von IP-Adressen mit vielen Fehlversuchen
analyze_ip_attempts() {
  echo "=== IP-Adressen mit den meisten Fehlversuchen ==="
  grep "Failed password" $AUTH_LOG | awk '{print $11}' | sort | uniq -c | sort -nr | head -10
  echo ""
}

# Funktion zur Identifizierung von Verbindungsabbrüchen
analyze_connection_drops() {
  echo "=== Verbindungsabbrüche (Connection closed/dropped) ==="
  grep -E "Connection closed|Connection reset" $AUTH_LOG | wc -l
  echo ""
}

# Hauptausführung
main() {
  echo "Auth Log Summary Report"
  echo "======================"
  echo "Analyzing: $AUTH_LOG"
  echo ""
  
  analyze_failed_ssh_attempts
  analyze_invalid_users
  analyze_ip_attempts
  analyze_connection_drops
  
  echo "Analyse abgeschlossen."
}

main
