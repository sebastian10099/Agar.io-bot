#!/bin/bash
# Doppelklick auf dem Mac: öffnet die Steuerseite des Bots, der auf deinem
# VPS läuft (eingerichtet mit deploy/vps-install.sh). Baut einen SSH-Tunnel
# auf und öffnet den Browser; dieses Fenster offen lassen – schließen trennt.
# Beim ersten Mal fragt es nach dem Server (z. B. root@203.0.113.5) und merkt
# ihn sich. Anderer Server: ./"VPS verbinden.command" benutzer@adresse
set -u
CONF="$HOME/Library/Application Support/NewTokenBot/vps.txt"
REMOTE_PORT="${NTB_PORT:-8765}"
LOCAL_PORT="${NTB_LOCAL_PORT:-18765}"   # nicht 8765: dort läuft vielleicht der Bot auf dem Mac
mkdir -p "$(dirname "$CONF")"

TARGET="${1:-$(cat "$CONF" 2>/dev/null || true)}"
if [ -z "$TARGET" ]; then
  printf 'Server (z. B. root@203.0.113.5): '
  read -r TARGET
fi
[ -n "$TARGET" ] || { echo "Kein Server angegeben."; exit 1; }
printf '%s\n' "$TARGET" > "$CONF"

echo "Verbinde mit $TARGET …"
ssh -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -N -L "$LOCAL_PORT:127.0.0.1:$REMOTE_PORT" "$TARGET" &
PID=$!
trap 'kill "$PID" 2>/dev/null' EXIT INT TERM
for _ in $(seq 1 60); do
  if curl -s -m 2 "http://127.0.0.1:$LOCAL_PORT/api/state" | grep -q '"app": "new-token-bot"'; then
    open "http://127.0.0.1:$LOCAL_PORT/"
    echo "Steuerseite offen: http://127.0.0.1:$LOCAL_PORT/  – dieses Fenster offen lassen (schließen trennt die Verbindung)."
    wait "$PID"
    exit 0
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "SSH-Verbindung fehlgeschlagen. Stimmt die Adresse ($TARGET)? Klappt 'ssh $TARGET' im Terminal?"
    rm -f "$CONF"
    exit 1
  fi
  sleep 1
done
echo "Verbunden, aber der Bot antwortet nicht. Auf dem Server prüfen: sudo systemctl status new-token-bot"
exit 1
