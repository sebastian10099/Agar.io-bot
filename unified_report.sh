#!/bin/bash

# unified_report.sh - Fuehrt alle Monitor-Skripte aus und generiert einen kombinierten Gesamtbericht
# Erstellt am: $(date)

REPORT_FILE="/root/local_agent/agent_workspace/unified_report_$(date +%Y%m%d_%H%M%S).txt"

{
    echo "==========================================="
    echo "UNIFIED SYSTEM REPORT"
    echo "Erstellt am: $(date)"
    echo "==========================================="
    echo ""
    
    echo "--- HEALTH CHECK ---"
    /root/local_agent/agent_workspace/health_check.sh
    echo "Exit Code: $?"
    echo ""
    
    echo "--- SECURITY AUDIT ---"
    /root/local_agent/agent_workspace/security_audit.sh
    echo "Exit Code: $?"
    echo ""
    
    echo "--- SERVICE STATUS ---"
    /root/local_agent/agent_workspace/service_status.sh
    echo "Exit Code: $?"
    echo ""
    
    echo "==========================================="
    echo "ENDE DES BERICHTS"
    echo "==========================================="
} > "$REPORT_FILE"

echo "Unified Report wurde erstellt: $REPORT_FILE"