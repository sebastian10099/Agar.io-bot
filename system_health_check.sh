#!/bin/bash

# System Health Check Skript

# Warnschwellen (in Prozent)
RAM_WARN=80
DISK_WARN=85
CPU_WARN=80

# Farben fuer die Ausgabe
green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
nc='\033[0m' # No Color

# Funktion zur Pruefung der RAM-Auslastung
check_ram() {
  echo "Pruefe RAM-Auslastung..."
  ram_usage=$(free | grep Mem | awk '{printf("%.0f", $3/$2 * 100.0)}')
  echo "RAM-Auslastung: $ram_usage%"
  if [ $ram_usage -gt $RAM_WARN ]; then
    echo -e "${red}WARNUNG: RAM-Auslastung hoeher als $RAM_WARN% - Ueberlege einen Neustart oder das Beenden von Prozessen${nc}"
  else
    echo -e "${green}RAM-Auslastung ist in Ordnung${nc}"
  fi
}

# Funktion zur Pruefung der Festplattenauslastung
check_disk() {
  echo "Pruefe Festplattenauslastung..."
  disk_usage=$(df -h / | grep -vE '^Filesystem|tmpfs|cdrom' | awk '{ print $5 }' | sed 's/%//g')
  echo "Festplattenauslastung: $disk_usage%"
  if [ $disk_usage -gt $DISK_WARN ]; then
    echo -e "${red}WARNUNG: Festplattenauslastung hoeher als $DISK_WARN% - Loesche unnoetige Dateien oder erweitere den Speicher${nc}"
  elif [ $disk_usage -gt $(($DISK_WARN - 10)) ]; then
    echo -e "${yellow}Achtung: Festplattenauslastung ist hoch ($disk_usage%)${nc}"
  else
    echo -e "${green}Festplattenauslastung ist in Ordnung${nc}"
  fi
}

# Funktion zur Pruefung der CPU-Auslastung
check_cpu() {
  echo "Pruefe CPU-Auslastung..."
  # Pruefen ob bc installiert ist
  if ! command -v bc &> /dev/null; then
    echo -e "${yellow}Hinweis: 'bc' nicht gefunden, installiere es fuer genauere CPU-Pruefung${nc}"
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//g' | cut -d'.' -f1)
    echo "CPU-Auslastung (ungefaehr): $cpu_usage%"
    if [ $cpu_usage -gt $CPU_WARN ]; then
      echo -e "${red}WARNUNG: CPU-Auslastung moeglicherweise hoeher als $CPU_WARN%${nc}"
    else
      echo -e "${green}CPU-Auslastung scheint in Ordnung zu sein${nc}"
    fi
  else
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//g')
    echo "CPU-Auslastung: $cpu_usage%"
    if (( $(echo "$cpu_usage > $CPU_WARN" | bc -l) )); then
      echo -e "${red}WARNUNG: CPU-Auslastung hoeher als $CPU_WARN% - Pruefe laufende Prozesse${nc}"
    else
      echo -e "${green}CPU-Auslastung ist in Ordnung${nc}"
    fi
  fi
}

# Hauptprogramm
echo "=== System Health Check ==="
check_ram
check_disk
check_cpu
echo "=== Check abgeschlossen ==="
