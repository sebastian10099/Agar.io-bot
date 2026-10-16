"""One-click update from the control page: fetch the current version with
get.sh, wait for this bot to exit, start the app again. Only where the
program was installed by get.sh (the project folder carries get.sh) and
only on macOS – everywhere else the page hides the button."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Optional

SCRIPT = r'''
set -u
LOG="$HOME/Library/Application Support/NewTokenBot/update.log"
mkdir -p "$(dirname "$LOG")"
{
  echo "=== Aktualisierung $(date) ==="
  bash "$PROJECT/get.sh" || { echo "get.sh fehlgeschlagen"; exit 1; }
  # wait until the old bot has released its port
  for _ in $(seq 1 60); do
    curl -s -m 1 "http://127.0.0.1:$PORT/api/state" | grep -q '"app": "new-token-bot"' || break
    sleep 1
  done
  sleep 1
  if [ -d "$HOME/Desktop/New Token Bot.app" ]; then open "$HOME/Desktop/New Token Bot.app"; else open -a "New Token Bot" || true; fi
  echo "neu gestartet"
} >> "$LOG" 2>&1
'''


def available(project: Path) -> bool:
    return (project / "get.sh").is_file() and (sys.platform == "darwin" or os.environ.get("NEW_TOKEN_BOT_ALLOW_UPDATE") == "1")


def start_update(project: Path, port: int, runner: Optional[Callable[..., Any]] = None) -> dict[str, Any]:
    if not (project / "get.sh").is_file():
        return {"ok": False, "error": "Aktualisieren geht nur bei einer Installation über get.sh (Ordner ~/NewTokenBot/src)."}
    if not available(project):
        return {"ok": False, "error": "Aktualisieren gibt es nur auf macOS."}
    env = dict(os.environ, PROJECT=str(project), PORT=str(port))
    try:
        if runner is not None:
            runner(["/bin/bash", "-c", SCRIPT], env)
        else:
            subprocess.Popen(["/bin/bash", "-c", SCRIPT], env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as error:
        return {"ok": False, "error": f"Aktualisierung ließ sich nicht starten: {error}"}
    return {"ok": True, "detail": "Neue Version wird geladen; der Bot beendet sich gleich und die App startet ihn neu. Log: ~/Library/Application Support/NewTokenBot/update.log"}
