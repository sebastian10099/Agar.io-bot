Branch: lokal/bann-dauer
Dateien: BeamNet/server/BeamNetCore/main.lua BeamNet/tests/core_test.lua
Test: python3 BeamNet/tests/run_lua_tests.py
---
Fehler: `/ban Name 2H` (großes H), `/ban Name 1w` oder `/ban Name 30min` sperren für IMMER, weil die Dauer nicht
erkannt wird und dann als Grund gilt. `/ban Name 99999999999999999999d` lässt das Plugin abstürzen.

Ändere in BeamNet/server/BeamNetCore/main.lua nur die Funktion `BN.parseDuration(text)` (sie steht so da):

    function BN.parseDuration(text)
        local n, unit = tostring(text or ""):match("^(%d+)([mhd])$")
        ...

Neu soll sie:
1. den Text vorher klein schreiben (`:lower()`),
2. zusätzlich `w` (Woche = 7 Tage) erlauben,
3. höchstens 6 Ziffern erlauben (sonst nil),
4. ganze Zahlen zurückgeben (wie bisher Sekunden).
Rückgabe nil bei allem anderen – wie bisher.

Tests in BeamNet/tests/core_test.lua direkt VOR der Zeile `-- Herunterfahren speichert alle.` als Abschnitt
`-- --- Bann-Dauer` mit `eq(...)`: "2H" → 7200, "1w" → 604800, "30m" → 1800, "9999999d" → nil, "30min" → nil, "abc" → nil.
