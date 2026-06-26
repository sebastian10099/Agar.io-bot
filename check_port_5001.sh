#!/bin/bash
# Check if port 5001 is open
if lsof -i :5001 | grep -q LISTEN; then
echo "Port 5001 ist offen."
else
echo "Port 5001 ist nicht offen."
fi