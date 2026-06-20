#!/bin/bash

# Skript zum Aufraeumen von temporaeren und Test-Dateien im Workspace

WORKSPACE="/root/local_agent/agent_workspace"

echo "Suche temporaere und Test-Dateien..."
find "$WORKSPACE" -type f \( -name "*.tmp" -o -name "*.bak" -o -name "*.log" -o -name "test_*" -o -name "*_test" \) | head -20

echo "
Gefundene Dateien insgesamt: $(find "$WORKSPACE" -type f \( -name "*.tmp" -o -name "*.bak" -o -name "*.log" -o -name "test_*" -o -name "*_test" \) | wc -l)"

echo "
Loesche Dateien..."
find "$WORKSPACE" -type f \( -name "*.tmp" -o -name "*.bak" -o -name "*.log" -o -name "test_*" -o -name "*_test" \) -delete
echo "Temporaere und Test-Dateien wurden geloescht."
