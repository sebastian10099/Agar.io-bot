#!/bin/bash
# Find a free port and save it in PORT variable
PORT=$(netstat -tuln | grep :80/tcp | awk '{print $4}' | cut -d: -f2)
if [ -z "$PORT" ]; then
    PORT=81
else
    if ! (netcat -zv localhost $PORT 5 &>/dev/null); then
        PORT=$PORT
    else
        PORT=$(shuf -i 49153-65535 -n 1)
    fi
echo "PORT=$PORT" >> /root/local_agent/agent_workspace/port_vars.txt
fi