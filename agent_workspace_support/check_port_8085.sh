
#!/bin/bash
# Prüfen Sie den freien Port 8085 und schreiben Sie die Ergebnisse in README.
if ! lsof -i :8085; then
echo "Port 8085 ist offen." >> /root/local_agent/agent_workspace_support/README.md
else
echo "Port 8085 ist nicht offen." >> /root/local_agent/agent_workspace_support/README.md
fi