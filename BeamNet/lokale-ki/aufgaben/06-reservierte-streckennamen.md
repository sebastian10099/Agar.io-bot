Branch: lokal/reservierte-streckennamen
Dateien: BeamNet/server/BeamNetCore/main.lua BeamNet/tests/core_test.lua
Test: python3 BeamNet/tests/run_lua_tests.py
---
Fehler: `/rennen neu stop` legt eine Strecke "stop" an, die man nie starten kann, weil `/rennen stop` den Rennmodus
beendet. Dasselbe gilt für andere Wörter, die `/rennen` selbst benutzt.

In BeamNet/server/BeamNetCore/main.lua in `local function trackName(name)`: Lehne diese Namen ab (Rückgabe nil):
stop, neu, new, ziel, finish, ende, end, quit, loeschen, delete, remove, liste, list.
Am einfachsten mit einer Tabelle `local RESERVED = { stop = true, ... }` direkt über der Funktion und
`if RESERVED[name] then return nil end` nach dem Kleinschreiben.

Tests in BeamNet/tests/core_test.lua direkt VOR der Zeile `-- Herunterfahren speichert alle.` als Abschnitt
`-- --- Reservierte Streckennamen`: Ein Admin (wie im Abschnitt Zeitrennen) versucht `/rennen neu stop`; danach darf es
in `BN.loadTracks().tracks` keinen Eintrag "stop" geben. Schau im Abschnitt "Zeitrennen" nach, wie Admins und
`/rennen neu` dort getestet werden, und mach es genauso.
