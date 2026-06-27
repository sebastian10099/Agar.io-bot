#!/bin/bash
python3 -m venv /root/local_agent/agent_workspace/flask_env
source /root/local_agent/agent_workspace/flask_env/bin/activate
cd /root/local_agent/agent_workspace && pip install flask