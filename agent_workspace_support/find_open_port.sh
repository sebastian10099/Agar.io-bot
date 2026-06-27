#!/bin/bash
# Variablen setzen
PORTS_TO_CHECK=(21 80 443)
OPEN_PORTS=()
# Parameter übernehmen
if [ -z "$1" ]; then
echo "Bitte einen Portnummer als Argument angeben." >&2
echo "Beispiel: ./find_open_port.sh 445"
exit 1
fi
current_port=$1
PORTS_TO_CHECK+=($current_port)
# Iteriere über die Ports
for PORT in ${PORTS_TO_CHECK[@]}; do
    if [ $PORT -eq $current_port ]; then
        OPEN_PORTS+=($PORT)
    fi
done
# Zeige die freien Ports aus
echo "Die folgenden Ports sind offen:"
echo ${OPEN_PORTS[*]}
current_port=$1
# Iteriere über die zu prüfenden Ports
for PORT in ${PORTS_TO_CHECK[@]}; do
    if [ $PORT -eq $current_port ]; then continue; fi
tcping -p $PORT -z localhost &>/dev/null
if [ $? -ne 0 ]; then
    OPEN_PORTS=()
fi
# Zeige die freien Ports aus
echo "Die folgenden Ports sind offen:"
echo ${OPEN_PORTS[*]}
rm -f tcping
