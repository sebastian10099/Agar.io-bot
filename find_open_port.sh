#!/bin/bash
PORT=$(netstat -tuln | grep ':<port>' | cut -d: -f4 | sort -u)
if [ -z "$PORT" ]; then
    echo "No open ports found."
else
    echo "Open port(s): $PORT" | tee /root/local_agent/agent_workspace/open_ports.txt
echo "$PORT" > /root/local_agent/agent_workspace/current_open_port.txt
fi