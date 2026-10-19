#!/bin/bash
# New Token Bot auf einem Linux-Server (VPS) einrichten – oder aktualisieren.
# Auf dem Server als root bzw. mit sudo:
#
#   curl -fsSL https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/agenen-funktionalitaet-hnw6g5/trading-bot/deploy/vps-install.sh | sudo bash
#
# Für Ubuntu 22.04/24.04 und Debian 12 (apt), Fedora/Rocky (dnf). Der Bot läuft
# als eigener Systembenutzer "newtokenbot" unter systemd: startet beim Booten,
# nach einem Absturz von selbst neu. Paper-Modus, wie auf dem Mac.
#
# Die Steuerseite hört nur auf 127.0.0.1 des Servers – aus dem Internet ist sie
# nicht erreichbar. Man öffnet sie über einen SSH-Tunnel (Anleitung am Ende der
# Ausgabe, auf dem Mac per Doppelklick: "VPS verbinden.command").
#
# Nochmal ausführen = aktualisieren. Konto, Einstellungen und Schlüssel liegen
# getrennt vom Programm (/var/lib/new-token-bot, /etc/new-token-bot.env) und
# bleiben erhalten.
#
# Optional: NTB_BRANCH (Branch), NTB_PORT (Port der Steuerseite, Standard 8765),
# NTB_SOURCE (einen vorhandenen Checkout installieren statt herunterzuladen),
# z. B.  curl … | sudo NTB_PORT=8780 bash
#
# Alles steckt in main(), das erst am Ende aufgerufen wird: bei "curl | bash"
# liest bash so das ganze Skript, bevor ein Befehl (apt, pip) etwas von stdin
# nehmen und damit den Rest des Skripts verschlucken könnte.
set -euo pipefail
umask 022                                # venv and program readable for the bot user, whatever sudo's umask

main() {

REPO="sebastian10099/Agar.io-bot"
BRANCH="${NTB_BRANCH:-claude/agenen-funktionalitaet-hnw6g5}"
PORT="${NTB_PORT:-8765}"
APP=/opt/new-token-bot
DATA=/var/lib/new-token-bot
ENVFILE=/etc/new-token-bot.env
BOT_USER=newtokenbot
SERVICE=new-token-bot

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nFEHLER: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "bitte mit sudo bzw. als root ausführen"
command -v systemctl >/dev/null && [ -d /run/systemd/system ] || die "dieser Server hat kein systemd"
case "$PORT" in ''|*[!0-9]*) die "NTB_PORT muss eine Zahl sein" ;; esac

say "Pakete (Python 3, venv, curl, unzip)"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3 python3-venv curl unzip ca-certificates >/dev/null
elif command -v dnf >/dev/null; then
  dnf install -y -q python3 curl unzip ca-certificates >/dev/null
else
  echo "kein apt/dnf – Python 3.9+, curl und unzip müssen schon da sein"
fi
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "Python 3.9 oder neuer nötig ($(python3 --version 2>&1))"

say "Benutzer $BOT_USER und Datenordner $DATA"
id -u "$BOT_USER" >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin "$BOT_USER"
install -d -o "$BOT_USER" -g "$BOT_USER" -m 700 "$DATA"

say "Programm holen ($BRANCH)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [ -n "${NTB_SOURCE:-}" ]; then
  cp -a "$NTB_SOURCE/trading-bot" "$tmp/src"
else
  curl -fsSL -o "$tmp/bot.zip" "https://github.com/$REPO/archive/refs/heads/$BRANCH.zip" || die "Download fehlgeschlagen – Internet da? Dann nochmal ausführen."
  unzip -q "$tmp/bot.zip" -d "$tmp/unpack"
  mv "$tmp"/unpack/*/trading-bot "$tmp/src"
fi
[ -f "$tmp/src/bot/main.py" ] || die "im Download fehlt bot/main.py"

install -d -m 755 "$APP"
[ -x "$APP/venv/bin/python" ] || python3 -m venv "$APP/venv"
# the Anthropic SDK is only needed for the optional AI mode
"$APP/venv/bin/pip" install -q --disable-pip-version-check --upgrade anthropic \
  || echo "Hinweis: Anthropic-SDK nicht installiert – der Bot läuft, nur der KI-Modus fehlt"

systemctl stop "$SERVICE" 2>/dev/null || true
rm -rf "$APP/src.old"
[ -d "$APP/src" ] && mv "$APP/src" "$APP/src.old"
mv "$tmp/src" "$APP/src"
rm -rf "$APP/src.old"
chown -R root:root "$APP/src"
chmod -R go-w,a+rX "$APP/src"           # the bot may read its program, never change it

if [ ! -f "$ENVFILE" ]; then
  say "Schlüssel-Datei $ENVFILE (nur root kann sie lesen)"
  ( umask 077; cat > "$ENVFILE" <<'EOF'
# Umgebung des New Token Bot. Nach einer Änderung: sudo systemctl restart new-token-bot
#
# Claude als Berater (optional; ohne Schlüssel entscheiden die Regeln allein):
# ANTHROPIC_API_KEY=sk-ant-...
#
# Eigener Solana-Knoten, z. B. ein kostenloser Helius-Schlüssel – damit klappt
# die Halter-Prüfung (der öffentliche Knoten drosselt sie):
# SOLANA_RPC_URL=https://mainnet.helius-rpc.com/?api-key=...
# SOLANA_HOLDER_RPCS=https://mainnet.helius-rpc.com/?api-key=...
EOF
  )
fi
chown root:root "$ENVFILE"
chmod 600 "$ENVFILE"

say "systemd-Dienst $SERVICE"
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=New Token Bot (Paper-Trading gegen echte Kurse)
Wants=network-online.target
After=network-online.target

[Service]
User=$BOT_USER
Group=$BOT_USER
Environment=NEW_TOKEN_BOT_HOME=$DATA
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
EnvironmentFile=-$ENVFILE
WorkingDirectory=$APP/src
ExecStart=$APP/venv/bin/python -m bot.main --no-open --port $PORT
# "Beenden" auf der Steuerseite hält den Bot an; ein Absturz startet ihn neu
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --quiet "$SERVICE"
systemctl restart "$SERVICE"

say "Start prüfen"
for _ in $(seq 1 60); do
  if curl -s -m 2 "http://127.0.0.1:$PORT/api/state" | grep -q '"app": "new-token-bot"'; then
    up=1; break
  fi
  sleep 1
done
if [ -z "${up:-}" ]; then
  journalctl -u "$SERVICE" -n 40 --no-pager || true
  other="$( (journalctl -u "$SERVICE" -n 200 --no-pager 2>/dev/null || true) | grep -o 'Dashboard: http://127.0.0.1:[0-9]*' | tail -1 | grep -o '[0-9]*$' || true)"
  if [ -n "$other" ] && [ "$other" != "$PORT" ]; then
    die "Port $PORT ist auf diesem Server belegt, der Bot lief auf $other. Mit festem freien Port installieren: curl … | sudo NTB_PORT=$other bash"
  fi
  die "der Bot antwortet nicht auf Port $PORT (Protokoll oben)"
fi

host="$( (hostname -I 2>/dev/null || true) | awk '{print $1}')"
cat <<EOF

Fertig: der Bot läuft auf diesem Server (Paper-Modus) und startet beim Booten von selbst.

Steuerseite öffnen – auf dem Mac im Terminal:
    ssh -N -L $PORT:127.0.0.1:$PORT ${SUDO_USER:-root}@${host:-DEIN-SERVER}
und dann im Browser  http://127.0.0.1:$PORT/
(oder Doppelklick auf "VPS verbinden.command" im Ordner trading-bot).

Nützlich auf dem Server:
    sudo systemctl status $SERVICE        läuft er?
    sudo journalctl -u $SERVICE -f        Protokoll live
    sudo systemctl restart $SERVICE       neu starten (z. B. nach Änderung an $ENVFILE)
    sudo nano $ENVFILE                    Claude- oder Solana-Schlüssel eintragen
    (dieselbe Befehlszeile wie zur Installation)   aktualisieren
EOF
}

main "$@"
