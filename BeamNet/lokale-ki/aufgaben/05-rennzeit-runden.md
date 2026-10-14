Branch: lokal/rennzeit-runden
Dateien: BeamNet/server/BeamNetCore/main.lua BeamNet/tests/core_test.lua
Test: python3 BeamNet/tests/run_lua_tests.py
---
Fehler: `BN.fmtRaceTime(119.96)` ergibt "1:60.0" statt "2:00.0".

In BeamNet/server/BeamNetCore/main.lua in `function BN.fmtRaceTime(seconds)`: Runde die Sekunden zuerst auf Zehntel,
also direkt nach `seconds = math.max(0, seconds or 0)` die Zeile
`seconds = math.floor(seconds * 10 + 0.5) / 10` einfügen. Sonst nichts ändern.

Tests in BeamNet/tests/core_test.lua direkt VOR der Zeile `-- Herunterfahren speichert alle.` als Abschnitt
`-- --- Rennzeit runden`: eq(BN.fmtRaceTime(119.96), "2:00.0", ...), eq(BN.fmtRaceTime(59.94), "0:59.9", ...),
eq(BN.fmtRaceTime(61.25), "1:01.3", ...) – prüfe die letzte Zahl selbst nach, bevor du sie einträgst.
