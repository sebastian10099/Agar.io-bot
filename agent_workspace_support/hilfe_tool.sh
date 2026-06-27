#!/bin/bash
# Dieses Skript bietet Hilfe auf Anfrage.
#
# Verwendung:
# 1. Führe das Skript mit -h oder --help, um die Hilfeseite zu sehen.
#
if [ $# -eq 0 ]; then
echo 'Usage: $0 [-h|--help]'
echo
exit 1
fi
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
echo 'Dieses Skript bietet Hilfe auf Anfrage.'
echo
exit 0
fi
# Berechtigungen für -h/--help
chmod a+x ./hilfe_tool.sh
# Neue Berechtigung für --help
chmod a+x ./hilfe_tool.sh --help