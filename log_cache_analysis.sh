#!/bin/bash

# Skript zur Analyse grosser Log-Dateien und Cache-Verzeichnisse

HOME_DIR="/root"
CACHE_DIRS=("$HOME_DIR/.cache" "$HOME_DIR/.local/share")
LOG_DIRS=("/var/log" "$HOME_DIR/logs")

# Funktion zur Ausgabe der groessten Dateien und Verzeichnisse
print_largest_files() {
    echo "Suche nach grossen Dateien in: $1"
    find "$1" -type f -exec du -h {} + 2>/dev/null | sort -rh | head -n 10
}

# Funktion zur Ausgabe der groessten Verzeichnisse
print_largest_dirs() {
    echo "Suche nach grossen Verzeichnissen in: $1"
    du -h --max-depth=1 "$1" 2>/dev/null | sort -rh | head -n 10
}

# Hauptprogramm
main() {
    echo "Analyse der Log- und Cache-Verzeichnisse"
    echo "====================================="
    
    # Ueberpruefe Cache-Verzeichnisse
    for dir in "${CACHE_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            echo "Analyse von Cache-Verzeichnis: $dir"
            print_largest_dirs "$dir"
            print_largest_files "$dir"
        else
            echo "Verzeichnis nicht gefunden: $dir"
        fi
    done
    
    # Ueberpruefe Log-Verzeichnisse
    for dir in "${LOG_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            echo "Analyse von Log-Verzeichnis: $dir"
            print_largest_dirs "$dir"
            print_largest_files "$dir"
        else
            echo "Verzeichnis nicht gefunden: $dir"
        fi
    done
}

main
