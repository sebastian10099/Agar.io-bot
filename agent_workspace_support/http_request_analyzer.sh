#!/bin/bash
# Ein einfaches Script zum Ausführen einer HTTP-Request und zu lesen der Antwort

REQUEST_URL=$1
RESPONSE=$(curl -s $REQUEST_URL)
echo "HTTP Request Response:
$RESPONSE"
chmod +x /root/local_agent/agent_workspace_support/http_request_analyzer.sh