#!/usr/bin/env python3
"""Install the Mission Control dashboard upgrade into /root/local_agent/server.py.

This is a small root-patch helper kept in the workspace so the server can pull
it from GitHub and apply it without needing the agent to invent the UI changes.
It expects `server.py.mission-control-source` beside this script; when present,
that tested source replaces `/root/local_agent/server.py` with a backup.
"""

from __future__ import annotations

import json
import py_compile
import shutil
import time
from pathlib import Path


WORKSPACE = Path(__file__).resolve().parent
ROOT = WORKSPACE.parent
SOURCE = WORKSPACE / "server.py.mission-control-source"
TARGET = ROOT / "server.py"
REPORT = WORKSPACE / "dashboard_upgrade_report.json"


def utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def main() -> int:
    report = {"checked_at": utc(), "source": str(SOURCE), "target": str(TARGET)}
    if not SOURCE.exists():
        report.update({"ok": False, "message": "mission-control source missing"})
        REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(json.dumps(report, indent=2))
        return 2
    py_compile.compile(str(SOURCE), doraise=True)
    backup = TARGET.with_suffix(TARGET.suffix + f".bak-dashboard-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}")
    shutil.copy2(TARGET, backup)
    shutil.copy2(SOURCE, TARGET)
    py_compile.compile(str(TARGET), doraise=True)
    report.update({
        "ok": True,
        "message": "Mission Control dashboard installed",
        "backup": str(backup),
    })
    REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
