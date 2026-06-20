#!/bin/bash

# service_status.sh - Prüft den Status wichtiger Systemdienste

SERVICES=("ssh" "cron" "systemd-journald")

for service in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$service"; then
    echo "[OK] $service is running"
  else
    echo "[ERROR] $service is not running"
    exit 1
  fi
done

exit 0