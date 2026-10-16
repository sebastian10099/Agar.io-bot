Branch: lokal/tagesaufgabe-map
Dateien: BeamNet/server/BeamNetCore/main.lua BeamNet/tests/core_test.lua
Test: python3 BeamNet/tests/run_lua_tests.py
---
Aufgabe: Neue Tagesaufgabe "Fahre heute X km auf dieser Map" (Kilometer je Map und Tag).

In BeamNet/server/BeamNetCore/main.lua:
1. In `local function applyDay(rec)` beim Tageswechsel zusätzlich `rec.dayMapKm = {}` setzen.
2. In `local function normalizeRecord(rec, id, name)` in der Schleife über die Tabellenfelder
   ("maps", "achievements", "dayMaps", "mapKm") auch "dayMapKm" ergänzen.
3. In `function BN.savePlayer(s)` direkt nach der Zeile mit `rec.mapKm[here] = (rec.mapKm[here] or 0) + s.pendingKm`
   eine gleichartige Zeile für `rec.dayMapKm[here]` einfügen (gleiche Bedingung wie dort).
4. In `function BN.dayTotals(s)` ein Feld `mapKm` zurückgeben: Kilometer heute auf `BN.server.map` =
   `(same and rec.dayMapKm[BN.server.map] or 0) + s.pendingKm` (nur wenn `BN.server.map` gesetzt ist, sonst 0).
5. In der Tabelle `BN.CHALLENGES` einen Eintrag ergänzen:
   `mapkm = { text = "Fahre heute %s km auf einer Map", goals = { 5, 8, 12 }, value = function(d) return d.mapKm end },`
6. Den Text "Fahre heute %s km auf einer Map" in der Tabelle `EN` übersetzen: "Drive %s km on one map today".
   (Die Liste `challengeTypes` NICHT ändern – Admins schalten die neue Aufgabe in config.json ein.)

In BeamNet/tests/core_test.lua direkt VOR der Zeile `-- Herunterfahren speichert alle.` einen Abschnitt
`-- --- Tagesaufgabe km auf einer Map` einfügen, der prüft: `BN.CHALLENGES.mapkm` existiert mit goals {5, 8, 12};
ein Spieler mit `pendingKm = 6` hat `BN.dayTotals(s).mapKm` ≥ 6; nach `BN.savePlayer(s)` steht in seiner
Spielerdatei `dayMapKm.gridmap_v2` ≈ 6 (Map im Test ist gridmap_v2). Nutze die Helfer `players`, `_G[events.onPlayerJoin]`,
`readJson`, `near`, `check` wie in den anderen Abschnitten (eigene Spieler-ID, z. B. "7777", pid 77).
