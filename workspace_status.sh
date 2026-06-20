#!/bin/bash

# Workspace Status Script
# Provides an overview of the current workspace including file counts and sizes

echo "=== Workspace Status Report ==="
echo
echo "Current directory: $(pwd)"
echo
echo "Directory listing with sizes:"
du -sh ./* 2>/dev/null | sort -hr
echo
echo "Total number of files (including hidden):"
find . -type f | wc -l
echo
echo "Largest files in workspace:"
find . -type f -exec du -h {} + 2>/dev/null | sort -hr | head -n 10
echo
echo "=== Workspace Summary ==="
total_size=$(du -sh . 2>/dev/null | cut -f1)
echo "Total workspace size: $total_size"
file_count=$(find . -type f | wc -l)
echo "Total file count: $file_count"