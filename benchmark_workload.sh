#!/bin/bash

# benchmark_workload.sh - Erzeugt kontrollierte Systemlast fuer Monitoring-Tests
#
# Verwendung:
#   ./benchmark_workload.sh [OPTIONEN]
#
# Optionen:
#   -h, --help          Zeigt diese Hilfe an
#   -c, --cpu NUM       Anzahl CPU-Last-Threads (Standard: 2)
#   -m, --memory SIZE   Speicherblockgroesse (Standard: 512M)
#   -d, --disk SIZE     Schreibgroesse fuer I/O-Test (Standard: 1G)
#   -t, --time SEC      Dauer des Tests in Sekunden (Standard: 60)
#   -f, --file PATH     Pfad fuer I/O-Testdatei (Standard: ./benchmark.tmp)

# Standardwerte
CPU_THREADS=2
MEMORY_SIZE="512M"
DISK_SIZE="1G"
TEST_DURATION=60
TEST_FILE="./benchmark.tmp"

# Hilfe anzeigen
show_help() {
  head -n 15 "$0" | tail -n 13
}

# Parameter parsen
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
      ;;
    -c|--cpu)
      CPU_THREADS="$2"
      shift 2
      ;;
    -m|--memory)
      MEMORY_SIZE="$2"
      shift 2
      ;;
    -d|--disk)
      DISK_SIZE="$2"
      shift 2
      ;;
    -t|--time)
      TEST_DURATION="$2"
      shift 2
      ;;
    -f|--file)
      TEST_FILE="$2"
      shift 2
      ;;
    *)
      echo "Ungueltige Option: $1"
      show_help
      exit 1
      ;;
  esac
done

# CPU-Last erzeugen
run_cpu_load() {
  echo "Starte CPU-Last mit $CPU_THREADS Threads fuer $TEST_DURATION Sekunden..."
  
  # Starte die angegebene Anzahl an stress-ng Prozessen
  stress-ng --cpu $CPU_THREADS --timeout ${TEST_DURATION}s &
  
  # Speichere die PID fuer spaeteres Management
  CPU_PID=$!
  
  # Warte auf Abschluss
  wait $CPU_PID
  
  echo "CPU-Last beendet."
}

# Speicher-Test durchfuehren
run_memory_test() {
  echo "Starte Speicher-Test mit $MEMORY_SIZE fuer $TEST_DURATION Sekunden..."
  
  # Starte den Speicher-Test mit stress-ng
  stress-ng --vm 1 --vm-bytes $MEMORY_SIZE --timeout ${TEST_DURATION}s &
  
  # Speichere die PID fuer spaeteres Management
  MEM_PID=$!
  
  # Warte auf Abschluss
  wait $MEM_PID
  
  echo "Speicher-Test beendet."
}

# Festplatten-I/O-Test durchfuehren
run_disk_test() {
  echo "Starte Festplatten-I/O-Test mit $DISK_SIZE nach $TEST_FILE fuer $TEST_DURATION Sekunden..."
  
  # Erstelle das Testverzeichnis falls es nicht existiert
  mkdir -p "$(dirname "$TEST_FILE")"
  
  # Starte den I/O-Test mit dd
  # Verwende eine Hintergrundschleife fuer kontinuierlichen I/O
  (
    while [ $SECONDS -lt $TEST_DURATION ]; do
      # Schreibe Datenblock in die Testdatei
      dd if=/dev/zero of="$TEST_FILE" bs=1M count=10 oflag=direct 2>/dev/null
      # Lese den Datenblock zurueck
      dd if="$TEST_FILE" of=/dev/null bs=1M count=10 iflag=direct 2>/dev/null
    done
    # Entferne die Testdatei am Ende
    rm -f "$TEST_FILE"
  ) &
  
  # Speichere die PID fuer spaeteres Management
  DISK_PID=$!
  
  # Warte auf Abschluss
  wait $DISK_PID
  
  echo "Festplatten-I/O-Test beendet."
}

echo "Benchmark Workload Konfiguration:"
echo "  CPU Threads:     $CPU_THREADS"
echo "  Memory Size:     $MEMORY_SIZE"
echo "  Disk Size:       $DISK_SIZE"
echo "  Test Duration:   $TEST_DURATION Sekunden"
echo "  Test File:       $TEST_FILE"

echo "\nStarte Benchmark Workload..."

# Fuehre die Workloads aus
run_cpu_load
run_memory_test
run_disk_test

echo "Benchmark Workload abgeschlossen."
