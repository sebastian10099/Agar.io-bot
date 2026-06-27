#!/bin/bash
chmod +x /root/local_agent/agent_workspace/tools_check.sh
echo 'Checking tools using pip list...'; python3 -m pip list | tee /tmp/pip_list.txt; grep tools /tmp/pip_list.txt >> /root/local_agent/agent_workspace/tools_check.log