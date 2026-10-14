#!/bin/bash
# Start der Mac-App: oeffnet die Werkstatt in einem Terminal-Fenster (dort sieht man, was sie gerade macht).
BIN="$(cd "$(dirname "$0")/../Resources" && pwd)/BeamNet-Werkstatt"
osascript - "$BIN" <<'OSA'
on run argv
    tell application "Terminal"
        activate
        do script quoted form of (item 1 of argv)
    end tell
end run
OSA
