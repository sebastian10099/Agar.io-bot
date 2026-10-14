# BeamNet – Roadmap

Erledigt (Version 1.1):
- [x] `beamnet report`: Bericht zum Teilen (IP-Adressen und AuthKeys unkenntlich), `doctor` prüft, ob BeamNetCore
      auf jedem Server läuft und ob es Fehler meldet.
- [x] Zeitrennen: Strecken im Spiel anlegen (`/rennen neu`, `/rennen ziel`), Zeitmessung mit Spieluhr und
      Interpolation, Rundkurse, Rekordliste je Strecke, ungültig bei Reset/Teleport.

Erledigt (Version 1.0):
- [x] `beamnet`: Status, Diagnose (inkl. OpenClaw, cron, SSH-Schlüssel), Reparatur, Maps, Sicherung, Protokolle,
      Plugins ab-/einschalten, OpenClaw anhalten/fortsetzen, Selbst-Update – getestet in einer nachgebauten Umgebung.
- [x] Plugin BeamNetCore: Kilometer, Fahrzeit, XP/Level, Ligen, Bestenliste (gesamt, km, Woche), `/server`,
      serverübergreifend, getestet unter Lua 5.3, 5.4 und LuaJIT.

Als Nächstes (sobald der Server-Zugang wieder steht und die Ausgabe von `beamnet doctor` vorliegt):
- [ ] Auf dem echten Server prüfen: `beamnet doctor`, `beamnet fix`, BeamNetCore installieren, alte Plugins vergleichen.
- [ ] Statusseite: `beamnet web` erzeugt jede Minute eine HTML-Seite mit allen Servern, Spielern und der Bestenliste
      (zum Teilen, z. B. in Discord).
- [ ] Discord-Meldungen per Webhook: Server ausgefallen/wieder da, Level-Aufstiege, Wochensieger am Sonntag.
- [ ] Wächter als systemd-Timer: startet ausgefallene Server neu und meldet es – erst, wenn der OpenClaw-Konflikt
      geklärt ist (sonst kämpfen zwei Programme gegeneinander).

Ideen:
- [ ] Wochenliga mit Auf- und Abstieg (Saisons), Wochensieger in der Bestenliste.
- [ ] Abstimmung im Chat: `/vote map <name>` wechselt die Map, wenn die Mehrheit zustimmt.
- [ ] Map-Rotation für einen Server (jeden Tag eine andere Map).
- [ ] Englische Texte je nach Spieler.
