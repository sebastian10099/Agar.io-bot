Branch: lokal/hilfe-zu-befehl
Dateien: BeamNet/server/BeamNetCore/main.lua BeamNet/tests/core_test.lua
Test: python3 BeamNet/tests/run_lua_tests.py
---
Aufgabe: `/hilfe <Befehl>` (englisch `/help <command>`) soll eine kurze Erklärung zu genau einem Befehl zeigen.

In BeamNet/server/BeamNetCore/main.lua:
1. Lege direkt über `function commands.hilfe(pid)` eine Tabelle `BN.HELP` an. Schlüssel = Befehlsname ohne Schrägstrich,
   Wert = ein deutscher Satz. Mindestens für: stats, top, liga, saison, server, km, rennen, rekorde, erfolge,
   aufgabe, vote, lang. Beispiel: `stats = "/stats [Name] – Level, Liga, XP, Kilometer und Rang (ohne Name: deine eigenen)."`
2. Ändere `commands.hilfe(pid)` zu `commands.hilfe(pid, arg)`: Ist `arg` leer, bleibt alles wie bisher.
   Sonst: führenden "/" entfernen, klein schreiben; englische Namen auf die deutschen abbilden
   (help→hilfe, league→liga, season→saison, race→rennen, records→rekorde, achievements→erfolge, daily→aufgabe).
   Gibt es einen Eintrag in BN.HELP: `say(pid, BN.HELP[name])`. Sonst: `say(pid, "Unbekannter Befehl: %s – alle Befehle: /hilfe", arg)`.
3. Jeder neue deutsche Text braucht einen englischen Eintrag in der Tabelle `EN` (gleiche Platzhalter wie im Deutschen).

In BeamNet/tests/core_test.lua direkt VOR der Zeile `-- Herunterfahren speichert alle.` einen Abschnitt
`-- --- Hilfe zu einem Befehl` einfügen, der prüft: `/hilfe stats` zeigt den stats-Text, `/hilfe /rennen` funktioniert,
`/hilfe gibtsnicht` meldet "Unbekannter Befehl", und ein Spieler mit `/lang en` bekommt bei `/help league` den englischen Text.
Nutze die vorhandenen Helfer `players`, `join`, `say`, `chatContains` wie in den anderen Abschnitten.
