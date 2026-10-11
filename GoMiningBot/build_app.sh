#!/bin/bash
# Baut "GoMining Bot.app" (universal: Apple Silicon + Intel) aus dem Swift-Paket.
# Voraussetzung: macOS 14+, Xcode oder die Command Line Tools (xcode-select --install).
#
#   ./build_app.sh                 # erzeugt dist/GoMining Bot.app und dist/GoMining-Bot.zip
#   APP_VERSION=4.1 ./build_app.sh # eigene Versionsnummer
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${APP_VERSION:-4.0}"
BUILD="${APP_BUILD:-$(date +%Y%m%d%H%M)}"
APP_NAME="GoMining Bot"
EXEC="GoMiningBot"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "→ Kompiliere (Release, arm64 + x86_64) …"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "→ Baue $APP …"
rm -rf "$APP" "$DIST/GoMining-Bot.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC" "$APP/Contents/MacOS/$EXEC"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist.template > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

echo "→ Signiere (ad-hoc) …"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "→ Packe ZIP …"
( cd "$DIST" && ditto -c -k --keepParent "$APP_NAME.app" "GoMining-Bot.zip" )

lipo -info "$APP/Contents/MacOS/$EXEC" || true
echo "Fertig: $APP"
echo "Erster Start: Rechtsklick auf die App → Öffnen (die App ist nicht notarisiert)."
