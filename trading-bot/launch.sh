#!/bin/bash
# Gemeinsamer Starter. Waehlt den ersten Python >= 3.9, der HTTPS kann.
set -u
cd "$(dirname "$0")" || exit 1

PROBE='import ssl, sys, urllib.request
assert sys.version_info >= (3, 9), "zu alt"
urllib.request.urlopen("https://api.dexscreener.com/token-profiles/latest/v1", timeout=10)'

CANDIDATES=(
  "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"
  "/opt/homebrew/bin/python3"
  "/usr/local/bin/python3"
  "/usr/bin/python3"
)

PY=""
for candidate in "${CANDIDATES[@]}"; do
  [ -x "$candidate" ] || continue
  if [[ " $* " == *" --demo "* ]]; then
    "$candidate" -c 'import sys; assert sys.version_info >= (3, 9)' 2>/dev/null && { PY="$candidate"; break; }
  else
    "$candidate" -c "$PROBE" 2>/dev/null && { PY="$candidate"; break; }
  fi
done

if [ -z "$PY" ]; then
  echo "Kein Python gefunden, das HTTPS-Verbindungen aufbauen kann."
  echo "Abhilfe: in Finder /Applications/Python 3.x/ 'Install Certificates.command' doppelklicken,"
  echo "oder:  /usr/bin/python3 -m pip install --user certifi"
  echo
  read -r -p "Enter zum Schliessen"
  exit 1
fi

echo "Python: $PY"
exec "$PY" -m bot.main "$@"
