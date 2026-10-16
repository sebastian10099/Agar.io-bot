Branch: lokal/neue-erfolge
Dateien: BeamNet/server/BeamNetCore/main.lua BeamNet/tests/core_test.lua BeamNet/beamnet.sh
Test: python3 BeamNet/tests/run_lua_tests.py
---
Aufgabe: Vier neue Erfolge (Achievements) für BeamNetCore.

In BeamNet/server/BeamNetCore/main.lua in der Tabelle `BN.ACHIEVEMENTS` (nach dem Eintrag "level10") anhängen,
im selben Format wie die vorhandenen (`id`, `name`, `xp`, `value = function(t) ... end`, `goal`):
1. id "km5000", name "5000 km", xp 400, Wert t.km, Ziel 5000
2. id "hours50", name "50 Stunden unterwegs", xp 250, Wert t.seconds / 3600, Ziel 50
3. id "race50", name "50 Rennen", xp 150, Wert t.races, Ziel 50
4. id "record5", name "5 Streckenrekorde", xp 150, Wert t.records, Ziel 5
Jeder neue deutsche Name braucht einen englischen Eintrag in der Tabelle `EN` (z. B. "50 Stunden unterwegs" →
"50 hours on the road", "50 Rennen" → "50 races", "5 Streckenrekorde" → "5 track records"; "5000 km" bleibt "5000 km").

In BeamNet/beamnet.sh die Python-Tabelle `ACH = {...}` (Statusseite) um dieselben vier Einträge ergänzen
(Schlüssel = id, Wert = deutscher Name).

In BeamNet/tests/core_test.lua direkt VOR der Zeile `-- Herunterfahren speichert alle.` einen Abschnitt
`-- --- Neue Erfolge` einfügen, der prüft: Es gibt in BN.ACHIEVEMENTS Einträge mit den ids km5000, hours50, race50,
record5 (mit `check(...)`), und jeder hat ein Ziel > 0 und xp > 0.
