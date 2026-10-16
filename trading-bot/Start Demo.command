#!/bin/bash
# Offline-Demo: simulierter Markt, 60x Zeitraffer, kein Netz noetig.
cd "$(dirname "$0")" || exit 1
exec bash ./launch.sh --demo "$@"
