#!/bin/bash

# security_audit.sh - Analyse fehlgeschlagener SSH-Login-Versuche
# Teil des System-Monitoring-Stacks

# Log-Datei fuer Auth-Logs
AUTH_LOG="/var/log/auth.log"

# Funktion zur Analyse fehlgeschlagener SSH-Logins
analyze_ssh_failures() {
    if [ ! -f "$AUTH_LOG" ]; then
        echo "ERROR: Auth-Log-Datei $AUTH_LOG nicht gefunden"
        exit 2
    fi
    
    # Suche nach fehlgeschlagenen SSH-Login-Versuchen
    # Zaehle verschiedene Arten von fehlgeschlagenen SSH-Logins
    local failed_password=$(grep "Failed password" "$AUTH_LOG" | wc -l)
    local invalid_user=$(grep "Invalid user" "$AUTH_LOG" | wc -l)
    local failed_publickey=$(grep "Failed publickey" "$AUTH_LOG" | wc -l)
    local refused_connect=$(grep "Connection refused" "$AUTH_LOG" | wc -l)
    
    # Gesamtzahl der fehlgeschlagenen SSH-Logins
    local total_failures=$((failed_password + invalid_user + failed_publickey + refused_connect))
    
    # Ausgabe der Ergebnisse
    echo "=== SECURITY AUDIT: SSH Login Failures ==="
    echo "Total SSH Login Failures: $total_failures"
    echo "Failed Password Attempts: $failed_password"
    echo "Invalid User Attempts: $invalid_user"
    echo "Failed Public Key Attempts: $failed_publickey"
    echo "Connection Refused: $refused_connect"
    
    # Bewertung der Sicherheitslage
    if [ $total_failures -gt 100 ]; then
        echo "SECURITY RISK LEVEL: HIGH"
        echo "RECOMMENDATION: Consider implementing fail2ban or similar intrusion prevention system"
        exit 2
    elif [ $total_failures -gt 10 ]; then
        echo "SECURITY RISK LEVEL: MEDIUM"
        echo "RECOMMENDATION: Monitor SSH logs regularly and consider strengthening authentication"
        exit 1
    else
        echo "SECURITY RISK LEVEL: LOW"
        echo "RECOMMENDATION: Continue monitoring, current security posture appears adequate"
        exit 0
    fi
}

# Hauptfunktion
main() {
    analyze_ssh_failures
}

# Skript ausfuehren
main
