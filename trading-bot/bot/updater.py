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


# --- automatic updates ---------------------------------------------------------------
# get.sh writes the commit it installed to .version (GitHub puts it in the archive). The
# running bot asks GitHub every CHECK_EVERY_S for the branch's newest commit and, when it
# differs, updates itself the same way as the button: positions and settings stay.
REPO = "sebastian10099/Agar.io-bot"
BRANCH = "claude/agenen-funktionalitaet-hnw6g5"
CHECK_EVERY_S = 30 * 60
FIRST_CHECK_S = 5 * 60


def installed_version(project: Path) -> str:
    try:
        sha = (project / ".version").read_text().strip()
    except OSError:
        return ""
    return sha if len(sha) == 40 and all(c in "0123456789abcdef" for c in sha) else ""


def latest_version(fetch: Optional[Callable[[str], str]] = None) -> str:
    """The branch's newest commit, "" when GitHub does not answer."""
    url = f"https://api.github.com/repos/{REPO}/commits/{BRANCH}"
    try:
        if fetch is not None:
            sha = fetch(url)
        else:
            import urllib.request
            from .sources.http import ssl_context
            req = urllib.request.Request(url, headers={"Accept": "application/vnd.github.sha",
                                                       "User-Agent": "new-token-bot/0.1"})
            with urllib.request.urlopen(req, timeout=15, context=ssl_context()) as r:
                sha = r.read(100).decode("ascii", "replace")
    except Exception:  # noqa: BLE001 - offline or rate-limited: try again next time
        return ""
    sha = sha.strip()
    return sha if len(sha) == 40 and all(c in "0123456789abcdef" for c in sha) else ""


def newer_version(project: Path, fetch: Optional[Callable[[str], str]] = None) -> str:
    """The newer commit to install, or "" (none, unknown, or not an installation get.sh made)."""
    mine = installed_version(project)
    if not mine or not available(project):
        return ""
    latest = latest_version(fetch)
    return latest if latest and latest != mine else ""


def watch(engine: Any, project: Path, port: int, wait: Callable[[float], bool],
          fetch: Optional[Callable[[str], str]] = None, runner: Optional[Callable[..., Any]] = None) -> None:
    """Background loop: `wait(seconds)` returns True when the bot is shutting down."""
    delay = FIRST_CHECK_S
    while not wait(delay):
        delay = CHECK_EVERY_S
        if not engine.cfg.get("auto_update", True):
            continue
        sha = newer_version(project, fetch)
        if not sha:
            continue
        engine.store.log("info", f"Neue Version {sha[:7]} – aktualisiere mich selbst, Konto und Einstellungen bleiben")
        result = start_update(project, port, runner)
        if result["ok"]:
            engine.stop()
            return
        engine.store.log("warn", f"Automatisches Update ging nicht: {result.get('error')}")
