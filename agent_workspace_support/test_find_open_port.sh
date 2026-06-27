#!/bin/bash
cp /root/local_agent/agent_workspace_support/find_open_port.sh ./find_open_port
chmod +x ./find_open_port
./find_open_port $@