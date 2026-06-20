#!/bin/bash

# Network Status Checker
# Zeigt aktive Interfaces, offene Ports und Verbindungsstatus

show_active_connections() {
  echo "=== Aktive Netzwerk-Interfaces ==="
  ip -br addr show up

  echo -e "\n=== Offene Ports (Listening) ==="
  ss -tuln

  echo -e "\n=== Aktive Verbindungen ==="
  # Zeige nur wirklich aktive (nicht-Listening) TCP- und UDP-Verbindungen
  ss -tun | grep -v LISTEN

  echo -e "\n=== Aktive Verbindungen mit Prozessen ==="
  ss -tunp | grep -v LISTEN

  echo -e "\n=== Top 5 Verbindungen nach Datenverkehr ==="
  # Zeigt die Top 5 Verbindungen nach Send-Queue
  ss -tun | grep -v LISTEN | head -n 1 && ss -tun | grep -v LISTEN | tail -n +2 | sort -k3 -nr | head -5

  echo -e "\n=== Routing-Tabelle ==="
  ip route show

  echo -e "\n=== DNS-Server ==="
  cat /etc/resolv.conf

  echo -e "\n=== Netzwerkstatistik (Pakete) ==="
  netstat -i

  echo -e "\n=== Netzwerkfehler und Drops ==="
  netstat -i | awk 'NR>2 {if($4>0 || $5>0 || $8>0 || $9>0) print $0}'
  
  echo -e "\n=== Zusammenfassung ==="
  local interfaces=$(ip -br addr show up | wc -l)
  local open_ports=$(ss -tuln | grep LISTEN | wc -l)
  local active_connections=$(ss -tun | grep -v LISTEN | wc -l)
  echo "Anzahl aktiver Interfaces: $interfaces"
  echo "Anzahl offener Ports: $open_ports"
  echo "Anzahl aktiver Verbindungen: $active_connections"
}

# Hauptprogramm
show_active_connections
