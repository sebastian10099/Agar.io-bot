#!/bin/bash

# Variablen initialisieren
OPEN_PORTS=()

# Funktion, die freie Ports findet und in die Variable einfügt
find_free_ports() {
  for port in {1..65535}; do
    if ! lsof -i :$port > /dev/null; then
      OPEN_PORTS+=($port)
    fi
  done
}

# Aufruf der Funktion
find_free_ports

# Ausgabe der freien Ports in einer Tabelle
printf "Port\tStatus\
"
for port in ${OPEN_PORTS[@]}; do
  if lsof -i :$port > /dev/null; then
    printf "$port\tbusy\
"
  else
    printf "$port\topen\
"
  fi
done