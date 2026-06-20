#!/bin/bash

# System Health Monitoring Script
# Provides an overview of system resources and health status

echo "=== System Health Report ==="
echo
echo "Available disk space:"
df -h
echo
echo "Memory status:"
free -h
echo
echo "Top 5 processes by memory usage:"
ps aux --sort=-%mem | head -n 6
echo
echo "CPU load:"
top -bn1 | grep "Cpu(s)"
echo
echo "Network interfaces:"
ip -br addr show
echo
echo "System uptime:"
uptime
echo
echo "=== Health Summary ==="
# Simple health checks
disk_usage=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
mem_usage=$(free | grep Mem | awk '{printf("%.0f", $3/$2 * 100.0)}')
cpu_idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d'.' -f1)

if [ $disk_usage -gt 90 ]; then
  echo "WARNING: Disk usage is at ${disk_usage}%"
elif [ $disk_usage -gt 75 ]; then
  echo "NOTICE: Disk usage is at ${disk_usage}%"
else
  echo "OK: Disk usage is at ${disk_usage}%"
fi

if [ $mem_usage -gt 90 ]; then
  echo "WARNING: Memory usage is at ${mem_usage}%"
elif [ $mem_usage -gt 75 ]; then
  echo "NOTICE: Memory usage is at ${mem_usage}%"
else
  echo "OK: Memory usage is at ${mem_usage}%"
fi

if [ $cpu_idle -lt 10 ]; then
  echo "WARNING: High CPU load detected"
elif [ $cpu_idle -lt 25 ]; then
  echo "NOTICE: Moderate CPU load detected"
else
  echo "OK: CPU load is normal"
fi