#!/usr/bin/env bash
cp /root/local_agent/agent_workspace_support/flask_app/app.py /root/local_agent/agent_workspace_support/flask_app/flask_app.py
sed -i 's/PORT=5000/PORT=8085/' /root/local_agent/agent_workspace_support/flask_app/flask_app.py
cp /root/local_agent/agent_workspace_support/flask_dashboard/flask_dashboard.py /root/local_agent/agent_workspace_support/flask_dashboard/flask_dashboard.py
chmod +x /root/local_agent/agent_workspace_support/flask_app/app.py
chmod +x /root/local_agent/agent_workspace_support/flask_dashboard/flask_dashboard.py
systemctl restart gunicorn_flask.service