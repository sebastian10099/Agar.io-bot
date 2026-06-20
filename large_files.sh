#!/bin/bash

# Skript zur Auflistung von Dateien größer als 1MB im aktuellen Verzeichnis
# Ausgabe inklusive Dateigröße in menschenlesbarem Format (KB/MB)

echo "Suche Dateien größer als 1MB..."

declare -A size_counter
file_count=0

while IFS= read -r -d '' file; do
    # Dateigröße ermitteln
    size=$(stat -c %s "$file")
    # In menschenlesbares Format umwandeln
    human_readable=$(numfmt --to=iec-i --suffix=B $size)
    # Verzeichnis extrahieren
    dir=$(dirname "$file")
    # Zähler für das Verzeichnis erhöhen
    ((size_counter["$dir"]++))
    # Gesamtzähler erhöhen
    ((file_count++))
    # Ausgabe
    echo -e "$human_readable\t$file"
done < <(find . -type f -size +1M -print0)

echo -e "\nZusammenfassung:"
for dir in "${!size_counter[@]}"; do
    echo "${size_counter[$dir]} große Datei(en) in: $dir"
done

echo -e "\nInsgesamt $file_count Datei(en) größer als 1MB gefunden."
