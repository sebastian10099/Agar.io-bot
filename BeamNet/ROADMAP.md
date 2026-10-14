# BeamNet – Roadmap

Erledigt (Werkzeug 1.13):
- [x] Statusseite: Profilseite je Fahrer (Level, Liga, Rang, km, Fahrzeit, Spitze, Saison, Erfolge, Maps, Bestzeiten);
      Namen in allen Tabellen verlinkt; Seiten verschwundener Fahrer werden entfernt.

Erledigt (Werkzeug 1.12):
- [x] Saisonsieger am 1. jedes Monats nach Discord (aus dem Saisonarchiv, sonst aus den Spielerdaten).

Erledigt (Plugin 1.10, Werkzeug 1.11):
- [x] Map-Abstimmung im Chat: `/vote map <Name>`, `/vote ja|nein`, Mehrheit der Spieler online; der Wächter prüft die
      Map gegen die erlaubte Liste, stellt um, startet neu und meldet nach Discord (höchstens ein Wechsel je Server in
      5 Minuten). Das Plugin bietet die Abstimmung nur an, wenn der Wächter läuft (Lebenszeichen `watch.json`).

Erledigt (Plugin 1.9, Werkzeug 1.10) – 8 Funde einer zweiten Code-Prüfung behoben, jeweils mit Test:
- [x] Update im laufenden Betrieb: Sitzungen der alten Version werden um neue Felder ergänzt (vorher: Fehler in jedem
      Takt); jeder Spieler wird im Takt einzeln abgesichert, Fehler landen gedrosselt im Log.
- [x] Erfolge und Tagesaufgabe werden erst beim Speichern gutgeschrieben – und nur, wenn die Datei sie noch nicht kennt
      (vorher: doppelte XP bei schnellem Serverwechsel).
- [x] Saison-XP als echter Zähler statt Startwert; nachträglich vergebene Erfolge zählen nicht für die Saison;
      Datensätze von 1.8 werden automatisch umgestellt; verpasstes Saisonarchiv wird stündlich nachgeholt.
- [x] Maps zählen erst ab 100 m Fahrt (vorher reichte kurzes Vorbeischauen für Erfolge und die Tagesaufgabe).
- [x] Werkzeug: `self-update` meldet kein „aktualisiert“ mehr, wenn das Ersetzen scheitert; `update` lädt das Plugin
      immer frisch von GitHub; Zahlen in `config.json` werden geprüft (ganze XP-Werte, sinnvolle Untergrenzen).

Erledigt (Plugin 1.8, Werkzeug 1.9):
- [x] Saisons: Monats-XP, `/saison`, Sieger und Archiv beim Monatswechsel, Statusseite.

Erledigt (Werkzeug 1.8):
- [x] `beamnet update` (Werkzeug + Plugin in einem Schritt, sicher gegen leere Downloads); `doctor` zeigt die
      Plugin-Version je Server und warnt bei unterschiedlichen Versionen.

Erledigt (Plugin 1.7):
- [x] Tagesaufgaben: täglich eine netzwerkweit gleiche Aufgabe mit Bonus-XP, `/aufgabe`, Hinweis bei der Begrüßung.

Erledigt (Plugin 1.6, Werkzeug 1.7):
- [x] Erfolge: 13 Stück (km, Fahrzeit, Tempo, Rennen, Rekorde, Maps, Level) mit Bonus-XP, `/erfolge`, Anzeige auf
      der Statusseite.

Erledigt (Plugin 1.5, Werkzeug 1.6) – 15 Funde einer unabhängigen Code-Prüfung behoben, jeweils mit Test:
- [x] Volle Platte: Dateien werden nur ersetzt, wenn das Schreiben vollständig geklappt hat (vorher: leere Spieler-
      oder Bann-Dateien möglich); Hilfsdateien je Server eindeutig.
- [x] Rundkurs: Wackeln an der Linie zählt nicht mehr als Runde (man muss sich mindestens 36 m entfernen).
- [x] `/ban Name`: genauer Name (auch offline) vor Teilname; Bann umfasst auch die IP (kein Zurückkommen als Gast).
- [x] Stummschaltung gilt auch für „/…“-Nachrichten, netzweit und nach Neu-Verbinden; `/mute 0.33` stürzt nicht mehr
      ab; Chat-Verarbeitung abgesichert; Befehls-Bremse; Wochenrangliste zwischengespeichert.
- [x] Werkzeug: Wartungsmarker endet, sobald der Server läuft; `watch test` meldet Fehler; Assistent läuft nach einem
      Fehler weiter und akzeptiert Kommas; `unban` mit kaputter Datei; „außerhalb von systemd“ über die cgroup;
      gemeinsamer Ordner immer mit Rechten für `beammp`; Sicherung im laufenden Betrieb.

Erledigt (Plugin 1.4):
- [x] Deutsch und Englisch je Spieler (`/lang`), Rundmeldungen in der Sprache jedes Empfängers, englische Befehlsnamen;
      Test prüft, dass jede Übersetzung dieselben Platzhalter hat.

Erledigt (Tests):
- [x] Integrationstest in der CI mit dem echten BeamMP-Server 3.9.3: Plugin lädt (Lua 5.3.5), onInit, Takt läuft,
      alle fünf BeamMP-Funktionen vorhanden, keine Fehler.

Erledigt (Werkzeug 1.5):
- [x] Einrichtungs-Assistent `beamnet setup`; `beamnet admin add/remove/list` (wirksam ohne Neustart).
- [x] Fehler behoben: `start/stop/restart all` brach ab, wenn im Server-Ordner ein Nicht-Server-Ordner (z. B. `shared`)
      als letzter lag – von einem neuen Test gefunden.

Erledigt (Plugin 1.3, Werkzeug 1.4):
- [x] Moderation: `/kick`, `/ban` (auf allen Servern, mit Dauer, Gäste per IP, auch offline), `/unban`, `/bans`,
      `/warn`, `/mute`, `/ansage` an alle Server, Spamschutz, Moderationsprotokoll; `beamnet bans/unban/modlog`.

Erledigt (Werkzeug 1.3):
- [x] Statusseite `beamnet web`: Server, wer fährt, Bestenliste, Wochenkilometer, Rekorde; jede Minute neu,
      kleiner abgeschotteter Webserver, hell/dunkel, fürs Handy.

Erledigt (Werkzeug 1.2):
- [x] Wächter `beamnet watch`: Ausfälle und Rückkehr melden, Discord-Webhook, optionaler Neustart (Limit 3/Stunde,
      nicht bei Wartung oder OpenClaw-Stopp), Wochensieger montags nach Discord.
- [x] Plugin prüft beim Start die BeamMP-Funktionen; `doctor` warnt bei zu alten Servern.

Erledigt (Plugin 1.2):
- [x] Rennen geben XP (Lauf, Bestzeit, Rekord) und zählen damit für Level und Liga.
- [x] Wochensieger: Verkündung beim Wochenwechsel, `/top vorwoche`.

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

Ideen:
- [ ] Map-Rotation für einen Server (jeden Tag eine andere Map).
