#!/bin/bash
# Installiert crypto-scanner und crypto-timemachine nach ~/.claude/skills (Claude Code, Mac/Linux).
#   bash install.sh                      aus dem Repo heraus
#   curl -fsSL <raw-URL>/install.sh | bash   ohne Repo, lädt die vier Dateien von GitHub
set -euo pipefail
RAW="${CRYPTO_SKILLS_RAW:-https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/agenen-funktionalitaet-hnw6g5/crypto-skills}"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
FILES="crypto-scanner/SKILL.md crypto-scanner/scan.py crypto-timemachine/SKILL.md crypto-timemachine/timemachine.py"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

command -v python3 >/dev/null || { echo "python3 fehlt (Mac: xcode-select --install)"; exit 1; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || { echo "Python 3.8 oder neuer nötig"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for f in $FILES; do
  mkdir -p "$TMP/$(dirname "$f")"
  if [ -n "$HERE" ] && [ -f "$HERE/$f" ]; then
    cp "$HERE/$f" "$TMP/$f"
  else
    curl -fsSL "$RAW/$f" -o "$TMP/$f"
  fi
done
mkdir -p "$DEST"
for d in crypto-scanner crypto-timemachine; do
  rm -rf "$DEST/$d.new"
  cp -R "$TMP/$d" "$DEST/$d.new"
  rm -rf "$DEST/$d"
  mv "$DEST/$d.new" "$DEST/$d"
done
echo "Installiert: $DEST/crypto-scanner und $DEST/crypto-timemachine"
echo "In Claude Code: /crypto-scanner und /crypto-timemachine (oder einfach: \"scanne Krypto\")."
