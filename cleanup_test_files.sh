#!/bin/bash

# Skript zum Aufraeumen von Test-Dateien im Workspace

WORKSPACE="/root/local_agent/agent_workspace"

echo "Suche Test-Dateien..."
find "$WORKSPACE" -type f -name "test_*" | head -20

echo "
Gefundene Test-Dateien insgesamt: $(find "$WORKSPACE" -type f -name "test_*" | wc -l)"

echo "
Loesche Test-Dateien..."
find "$WORKSPACE" -type f -name "test_*" -delete
echo "Test-Dateien wurden geloescht."
