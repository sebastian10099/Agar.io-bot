
#!/bin/bash
curl -v -X GET http://127.0.0.1:8086/status
python3 /root/local_agent/agent_workspace_hermes/flask_app.py &