#!/bin/bash
# Find open ports and save count to PORT_COUNT variable
PORT_COUNT=$(netstat -tuln | grep -v ':0.0.0.0' | awk '{print $4}' | wc -l)