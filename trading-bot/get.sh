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
  # GitHub puts the commit into the archive's comment: the version the app compares with
  unzip -z bot.zip 2>/dev/null | grep -E '^[0-9a-f]{40}$' | head -n 1 > "$top/trading-bot/.version"
  # swap in one step: an interrupted update leaves the old version, never none
  rm -rf src.old
  if [ -d src ]; then mv src src.old || { echo "Alte Version laesst sich nicht verschieben"; return 1; }; fi
  if ! mv "$top/trading-bot" src; then
    [ -d src.old ] && mv src.old src
    echo "Neue Version laesst sich nicht einsetzen - die alte bleibt"; return 1
  fi
  rm -rf src.old unpack bot.zip
  echo "Programm liegt in $root/src"
  # the app's own start-up update only needs the program, not a new app on the Desktop
  [ "${NEW_TOKEN_BOT_SKIP_APP:-}" = "1" ] && return 0
  bash "$root/src/install-app.sh" < /dev/null
}
main ${1+"$@"}
