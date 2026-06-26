#!/bin/bash

# Variablen initialisieren
OPEN_PORTS=()

timeouts=$((SECONDS+90)) # Timeout nach 1 Minute

while [[ $SECONDS -lt $timeouts ]]; do
    PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind("") ; s.listen(); c, addr = s.accept(); OPEN_PORTS+=([addr[0]])' | tr -d "[]" && echo $OPEN_PORTS)
    if [ ${#PORT[@]} -gt 0 ]; then
        break
    fi
    sleep 1
done

echo 'Open Ports: ${OPEN_PORTS[*]}'