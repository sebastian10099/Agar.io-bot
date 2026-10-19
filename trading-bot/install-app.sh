#!/bin/bash
# Legt "New Token Bot.app" auf den Schreibtisch und verdrahtet sie mit diesem
# Projektordner. Erneut ausfuehren ist harmlos (ersetzt die App).
#
#   bash install-app.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Desktop/New Token Bot.app"

rm -rf "$DEST"
cp -R "$HERE/New Token Bot.app" "$DEST" || { echo "Kopieren fehlgeschlagen"; exit 1; }
mkdir -p "$DEST/Contents/Resources"
printf '%s\n' "$HERE" > "$DEST/Contents/Resources/project.path"
chmod +x "$DEST/Contents/MacOS/New Token Bot"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
touch "$DEST"
echo "App liegt auf dem Schreibtisch: $DEST"

# Anthropic-CLI fuer "Mit Claude anmelden" (einmalig). Mit Homebrew per brew,
# sonst direkt als Download von GitHub nach ~/NewTokenBot/bin/ant.
ANT_DIR="$HOME/NewTokenBot/bin"
# `ant` is also Apache Ant (Java build tool): only accept a binary that answers "ant version 1.x"
is_anthropic_ant() { [ -x "$1" ] && "$1" --version 2>&1 | head -n 1 | grep -q '^ant version [0-9]'; }
HAVE_ANT=""
for c in "$ANT_DIR/ant" "$(command -v ant 2>/dev/null)" /opt/homebrew/bin/ant /usr/local/bin/ant; do
  if [ -n "$c" ] && is_anthropic_ant "$c"; then HAVE_ANT="$c"; break; fi
done
if [ -n "$HAVE_ANT" ]; then
  echo "Anthropic-CLI (ant) ist da: $HAVE_ANT"
elif command -v brew >/dev/null 2>&1 && [ -z "${NEW_TOKEN_BOT_ANT_ZIP:-}" ]; then
  echo "Installiere die Anthropic-CLI (ant) fuer die Claude-Anmeldung ..."
  if brew install anthropics/tap/ant < /dev/null; then
    xattr -d com.apple.quarantine "$(brew --prefix)/bin/ant" 2>/dev/null || true
    echo "ant installiert."
  else
    echo "ant konnte nicht installiert werden - 'Mit Claude anmelden' zeigt den Befehl spaeter noch einmal."
  fi
else
  echo "Lade die Anthropic-CLI (ant) fuer die Claude-Anmeldung ..."
  ARCH="$(uname -m)"; case "$ARCH" in arm64|aarch64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
  VER="$(curl -fsSL -o /dev/null -w '%{redirect_url}' https://github.com/anthropics/anthropic-cli/releases/latest 2>/dev/null | sed -n 's#.*/tag/v##p')"
  [ -n "$VER" ] || VER="1.42.0"
  ZIP="${NEW_TOKEN_BOT_ANT_ZIP:-https://github.com/anthropics/anthropic-cli/releases/download/v$VER/ant_${VER}_macos_${ARCH}.zip}"
  TMPZ="${TMPDIR:-/tmp}/ant-download-$$.zip"
  mkdir -p "$ANT_DIR"
  if curl -fsSL -o "$TMPZ" "$ZIP" && unzip -q -o "$TMPZ" ant -d "$ANT_DIR"; then
    chmod +x "$ANT_DIR/ant"; xattr -d com.apple.quarantine "$ANT_DIR/ant" 2>/dev/null || true
    echo "ant $VER liegt in $ANT_DIR/ant"
    "$ANT_DIR/ant" --version 2>/dev/null || echo "(Hinweis: ant liess sich hier nicht starten - die App versucht es beim Anmelden erneut)"
  else
    echo "Download von $ZIP fehlgeschlagen - 'Mit Claude anmelden' zeigt spaeter den Befehl zum Nachholen."
  fi
  rm -f "$TMPZ"
fi

/usr/bin/open -R "$DEST" 2>/dev/null || true
echo "Fertig. Doppelklick auf 'New Token Bot' startet den Bot und oeffnet die Steuerseite."
