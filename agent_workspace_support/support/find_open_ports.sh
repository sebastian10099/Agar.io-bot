```sh
#!/bin/bash
# Find and store open ports in a variable
ports=
while IFS= read -r port; do
    if nc -z $port 0.0.0.0 &>/dev/null; then
        ports+=$'
'"$port":	open"
    else
        ports+=$'
'"$port":	closed"
    fi
done < <(seq 1 65535)
depth=2
mkdir -p /tmp/port_results_$depth
for port in $ports; do
    if [ "${port:0:$depth}" == "$depth" ]; then
        echo $port >> /tmp/port_results_$depth/$port.txt
    fi
done
echo "Open ports:
$ports"
