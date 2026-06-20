#!/bin/bash

echo "=== Disk Usage Report ==="
echo "\n1. Free Disk Space:"
df -h
echo "\n2. Largest Directories (Top 10):"
du -h --max-depth=1 / 2>/dev/null | sort -hr | head -10
echo "\n3. Inode Usage:"
df -i
echo "\n4. Critical Directories Check:"
for dir in /root /home /var /tmp; do
  if [ -d "$dir" ]; then
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    echo "  $dir: $size"
  fi
done
echo "\n5. Summary & Warnings:"
while read -r line; do
  usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
  if [ "$usage" -gt 80 ]; then
    echo "  WARNING: $(echo "$line" | awk '{print $6}') is ${usage}% full"
  fi
done < <(df -h | grep -vE '^Filesystem|tmpfs|cdrom')

inode_warning=$(df -i | awk '$5+0 > 80 {print $6 " inode usage is " $5}')
if [ -n "$inode_warning" ]; then
  echo "  INODE WARNING: $inode_warning"
fi