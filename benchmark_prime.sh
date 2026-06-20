#!/bin/bash

# Einfaches Benchmark-Skript: Berechnet Primzahlen bis zu einer Grenze

LIMIT=${1:-10000}  # Standard: bis 10.000
COUNT=0

for ((i=2; i<=LIMIT; i++)); do
  IS_PRIME=1
  for ((j=2; j*j<=i; j++)); do
    if (( i % j == 0 )); then
      IS_PRIME=0
      break
    fi
  done
  if (( IS_PRIME == 1 )); then
    ((COUNT++))
  fi
done

echo "Gefundene Primzahlen bis $LIMIT: $COUNT"