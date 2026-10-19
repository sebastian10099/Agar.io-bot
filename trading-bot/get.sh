#!/bin/bash
# Holt die aktuelle Version OHNE git nach ~/NewTokenBot/src und legt die App
# "New Token Bot" auf den Schreibtisch. Zum Aktualisieren einfach nochmal
# ausfuehren - Daten und Einstellungen liegen getrennt davon in
# ~/Library/Application Support/NewTokenBot und bleiben erhalten.
#
#   curl -fsSL https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/agenen-funktionalitaet-hnw6g5/trading-bot/get.sh | bash
#
# Braucht nur curl und unzip (beides ist auf jedem Mac dabei), kein git,
# keine Xcode-Tools.
main() {
  set -u
  local repo="sebastian10099/Agar.io-bot"
  local branch="${NEW_TOKEN_BOT_BRANCH:-claude/agenen-funktionalitaet-hnw6g5}"
  local root="${NEW_TOKEN_BOT_ROOT:-$HOME/NewTokenBot}"
  local zip="https://github.com/$repo/archive/refs/heads/$branch.zip"

  mkdir -p "$root" && cd "$root" || { echo "Kann $root nicht anlegen"; return 1; }
  echo "Lade $zip ..."
  if ! curl -fsSL -o bot.zip "$zip"; then
    echo "Download fehlgeschlagen. Internet da? Dann den Befehl einfach nochmal ausfuehren."
    return 1
  fi
  rm -rf unpack && mkdir unpack
  if ! unzip -q -o bot.zip -d unpack; then echo "Entpacken fehlgeschlagen"; return 1; fi
  local top
  top="$(find unpack -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ ! -d "$top/trading-bot" ]; then echo "Im Archiv fehlt der Ordner trading-bot"; return 1; fi
  rm -rf src && mv "$top/trading-bot" src && rm -rf unpack bot.zip
  echo "Programm liegt in $root/src"
  bash "$root/src/install-app.sh" < /dev/null
}
main ${1+"$@"}
