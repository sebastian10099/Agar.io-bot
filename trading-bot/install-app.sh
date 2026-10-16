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

# Anthropic-CLI fuer "Mit Claude anmelden" (einmalig, optional)
if command -v ant >/dev/null 2>&1 || [ -x /opt/homebrew/bin/ant ] || [ -x /usr/local/bin/ant ]; then
  echo "Anthropic-CLI (ant) ist da."
elif command -v brew >/dev/null 2>&1; then
  echo "Installiere die Anthropic-CLI (ant) fuer die Claude-Anmeldung ..."
  if brew install anthropics/tap/ant < /dev/null; then
    xattr -d com.apple.quarantine "$(brew --prefix)/bin/ant" 2>/dev/null || true
    echo "ant installiert."
  else
    echo "ant konnte nicht installiert werden - 'Mit Claude anmelden' zeigt den Befehl spaeter noch einmal."
  fi
else
  echo "Hinweis: Homebrew fehlt. Fuer 'Mit Claude anmelden' spaeter: https://brew.sh  und dann  brew install anthropics/tap/ant"
fi

/usr/bin/open -R "$DEST" 2>/dev/null || true
echo "Fertig. Doppelklick auf 'New Token Bot' startet den Bot und oeffnet die Steuerseite."
