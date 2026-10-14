Branch: lokal/config-ganzzahlen
Dateien: BeamNet/server/BeamNetCore/main.lua BeamNet/tests/core_test.lua
Test: python3 BeamNet/tests/run_lua_tests.py
---
Fehler: In config.json führen Kommazahlen an zwei Stellen zu Abstürzen, weil sie mit %d ausgegeben werden.

In BeamNet/server/BeamNetCore/main.lua:
1. In der Tabelle `local INTEGER_KEYS = { ... }` fehlt `spamMuteSec = true`. Ergänze es.
2. In `function BN.validLeagues(list)` muss jede Liga eine ganze Zahl als `xp` haben. Ergänze in der Schleife die
   Bedingung: wenn `league.xp % 1 ~= 0` dann `return false`.

Tests in BeamNet/tests/core_test.lua direkt VOR der Zeile `-- Herunterfahren speichert alle.` als Abschnitt
`-- --- Ganzzahlen in config.json`:
- `check(not BN.validLeagues({ { xp = 0, name = "A" }, { xp = 10.5, name = "B" } }), "Liga-XP ganzzahlig")`
- writeJson(SHARED .. "/config.json", { spamMuteSec = 30.5 }); BN.loadOverrides(); eq(C.spamMuteSec, 30, ...);
  danach os.remove(SHARED .. "/config.json") und C.spamMuteSec = 30 zurücksetzen.
