#!/bin/bash
# Gemeinsamer Starter. Nimmt den ersten Python >= 3.9, bei dem der Vorab-Check
# (bot/preflight.py) HTTPS hinbekommt - fehlende CA-Zertifikate und das
# Anthropic-SDK installiert der Check selbst per pip, einmalig.
set -u
cd "$(dirname "$0")" || exit 1

CANDIDATES=(
  "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"
  "/opt/homebrew/bin/python3"
  "/usr/local/bin/python3"
  "/usr/bin/python3"
)

DEMO=""
[[ " $* " == *" --demo "* ]] && DEMO="--demo"

PY=""
LAST=""
for candidate in "${CANDIDATES[@]}"; do
  [ -x "$candidate" ] || continue
  "$candidate" -c 'import sys; assert sys.version_info >= (3, 9)' 2>/dev/null || continue
  OUT="$("$candidate" -m bot.preflight $DEMO 2>&1)"
  STATUS=$?
  echo "$OUT"
  if [ "$STATUS" -eq 0 ]; then PY="$candidate"; break; fi
  LAST="$OUT"
done

if [ -z "$PY" ]; then
  echo
  echo "Kein Python gefunden, das HTTPS-Verbindungen aufbauen kann."
  echo "Abhilfe: in Finder /Applications/Python 3.x/ 'Install Certificates.command' doppelklicken,"
  echo "oder:  /usr/bin/python3 -m pip install --user certifi"
  echo
  [ -t 0 ] && read -r -p "Enter zum Schliessen"
  exit 1
fi

echo "Python: $PY"
exec "$PY" -m bot.main "$@"
