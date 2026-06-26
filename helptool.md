#!/bin/bash
# Einen Test-Befehl hinzufügen zum Demonstrieren der Funktionalität
echo 'Test: $(./helptool.sh)' >> /root/local_agent/agent_workspace/output.txt
exec "$@"