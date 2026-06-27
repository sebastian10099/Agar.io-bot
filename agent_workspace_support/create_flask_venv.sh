#!/bin/bash
sudo python3 -m venv /root/local_agent/agent_workspace/support/flask_env
source /root/local_agent/agent_workspace/support/flask_env/bin/activate
cd /root/local_agent/agent_workspace/support && sudo pip install flask