#!/bin/bash
cd /root/local_agent/agent_workspace_support
python3 flask_app.py --port=8085 &
python3 flask_app.py --port=8086 &