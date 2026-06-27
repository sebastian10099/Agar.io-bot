
#!/bin/bash
# Prüft, ob eine Datei geändert wurde und aktualisiert.
if [ -f "$1" ]; then
    if ! cmp --silent "$1" "$(mktemp)"; then
        mv "$1" "$(mktemp)"
        echo "Datei wurde aktualisiert: $1"
    fi
fi