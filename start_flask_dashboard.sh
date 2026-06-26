#!/bin/bash
cp /root/local_agent/agent_workspace/find_open_port.sh /root/local_agent/agent_workspace/port
PORT=$(cat /root/local_agent/agent_workspace/port)
python3 -m flask run --port=$PORT