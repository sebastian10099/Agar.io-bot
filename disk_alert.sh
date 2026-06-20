#!/bin/bash

# Disk Usage Alert Script
# Checks disk usage and alerts if any filesystem exceeds 80% usage

echo "=== Disk Usage Report ==="

# Check if any partition exceeds 80% usage
found_issues=0
while IFS= read -r line; do
  if [[ -n "$line" ]]; then
    usage=$(echo "$line" | awk '{ print $1}' | sed 's/%//g')
    partition=$(echo "$line" | awk '{ print $2 }')
    if [ "$usage" -ge 80 ]; then
      echo "WARNING: Partition $partition is ${usage}% full"
      found_issues=1
    else
      echo "OK: Partition $partition is ${usage}% full"
    fi
  fi
done < <(df -h | grep -vE '^Filesystem|tmpfs|cdrom' | awk '{ print $5 " " $1 }')

if [ $found_issues -eq 1 ]; then
  echo "WARNING: At least one partition exceeds 80% usage."
  exit 1
else
  echo "All partitions are below 80% usage."
  exit 0
fi
