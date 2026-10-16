Branch: lokal/readme-englisch
Dateien: BeamNet/README.en.md
Test: test -s BeamNet/README.en.md && grep -q "beamnet doctor" BeamNet/README.en.md && grep -q "/stats" BeamNet/README.en.md
---
Aufgabe: Englische Kurzanleitung BeamNet/README.en.md (neue Datei) für Server-Admins aus anderen Ländern.

Übersetze aus BeamNet/README.md sinngemäß ins Englische (nicht Wort für Wort, kurz und klar), in dieser Reihenfolge:
1. Überschrift "# BeamNet – tool and plugin for BeamMP server networks" und 3–4 Sätze, was BeamNet macht.
2. "## Install" mit dem Installationsbefehl (curl … | bash) und `beamnet setup` – Befehle unverändert übernehmen.
3. "## Commands" als Tabelle der wichtigsten Befehle: status, doctor, report, fix, start/stop/restart, players,
   backup, restore, install-core, watch install, web install, ansage, update – jeweils ein englischer Satz.
4. "## Watcher" (Ausfälle, Discord/Telegram, Spielerrekord, Datensicherung, hängende Server) in Stichpunkten.
5. "## In-game chat commands" als Tabelle: /help, /stats, /top, /league, /season, /server, /where, /km, /race,
   /records, /achievements, /daily, /vote, /event, /report, /rules, /lang – jeweils ein englischer Satz.
6. Am Ende: "German documentation: README.md".
Keine Erfindungen: nur was in README.md steht. Befehle, Dateinamen und Konfigurationsnamen nicht übersetzen.
