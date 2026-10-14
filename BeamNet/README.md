# BeamNet – Werkzeug und Plugin für die BeamMP-Server

Zwei Teile, beide getestet:

1. **`beamnet`** – ein Befehl für die Server-Konsole: zeigt den Zustand aller Server, findet Probleme und repariert sie.
2. **`BeamNetCore`** – ein Server-Plugin: Kilometer, Fahrzeit, XP und Level, Ligen, Bestenliste, **Zeitrennen mit
   Rekordliste**, **Moderation** (Banns auf allen Servern, Ansagen, Spamschutz) und eine Liste aller Server im Chat –
   gemeinsam für alle Server.

## Schnellstart (Web-Konsole des Servers, als root)

Zwei Befehle – der zweite ist ein Assistent, der vor jedem Schritt fragt:

```bash
curl -fsSL https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/friendly-goldberg-31l8fp/BeamNet/beamnet.sh \
  -o /usr/local/bin/beamnet && chmod +x /usr/local/bin/beamnet
beamnet setup
```

`beamnet setup` führt durch: Diagnose → Sicherung → OpenClaw anhalten (falls er stört) → Server reparieren und starten
→ Plugin BeamNetCore installieren (alte Plugins mit gleichen Aufgaben abschalten) → Admins eintragen → Wächter mit
Discord → Statusseite → Neustart. Mit Enter wird ein Schritt übersprungen.

Lieber einzeln? `beamnet status` und `beamnet doctor` ändern nichts; `beamnet backup` und `beamnet fix` reparieren.

**Zum Teilen:** `beamnet report` erstellt einen Bericht mit Status, Diagnose, Plugins und auffälligen Protokollzeilen –
IP-Adressen und AuthKeys sind darin unkenntlich gemacht. Einfach komplett in den Chat kopieren.

## Befehle

| Befehl | Was er macht |
|---|---|
| `beamnet setup` | Geführte Einrichtung aller Teile (fragt vor jedem Schritt) |
| `beamnet status` | Übersicht: läuft?, Autostart, wer den Prozess gestartet hat, Port, Spieler, Map, Name |
| `beamnet doctor` | Diagnose mit Erklärung und Lösung je Problem (siehe unten) |
| `beamnet report` | Bericht zum Teilen: Status + Diagnose + Plugins + Fehlerzeilen der Protokolle, ohne IPs und AuthKeys |
| `beamnet fix` | Beendet „wilde“ Server-Prozesse (per `nohup` als root gestartet), setzt Dateirechte zurück, schaltet Autostart ein, startet alles sauber über systemd und prüft danach, ob die Server **an bleiben** |
| `beamnet start / stop / restart [nr … \| all]` | Server steuern; `stop` und `restart` fragen vorher |
| `beamnet maps` | Maps aller Server und die verfügbaren Vanilla-Maps |
| `beamnet set-map <nr> <map>` | Map ändern (sichert vorher, fragt vor dem Neustart); Mod-Maps mit `--force` |
| `beamnet logs <nr> [zeilen]` | Letzte Zeilen des Server-Protokolls |
| `beamnet plugins` | Installierte (und abgeschaltete) Plugins je Server |
| `beamnet plugin-disable <name>` / `plugin-enable <name>` | Plugin auf allen Servern ab- oder einschalten – verschiebt nur nach `Resources/Server.disabled`, löscht nichts |
| `beamnet players` | Spieler je Server (mit BeamNetCore) |
| `beamnet backup` | Konfigurationen, Plugins und systemd-Dienste nach `/root/beamnet-backups` (die 20 neuesten bleiben) |
| `beamnet install-core` | Installiert BeamNetCore auf allen Servern |
| `beamnet openclaw status / pause / resume` | OpenClaw-Agent ansehen, anhalten (einfrieren, nichts wird gelöscht) und fortsetzen |
| `beamnet watch install / status / test / uninstall` | Wächter einrichten (siehe unten) |
| `beamnet web install [port]` / `web uninstall` | Statusseite als Webseite (siehe unten), Standard-Port 8080 |
| `beamnet bans` / `unban <Name>` / `modlog [n]` | Banns ansehen und aufheben, Moderationsprotokoll lesen |
| `beamnet admin list / add <Name …> / remove <Name …>` | Admins für Rennen und Moderation – wirksam innerhalb einer Minute, ohne Neustart |
| `beamnet self-update` | Neueste Version des Werkzeugs laden |

Mit `-y` laufen Befehle ohne Rückfrage.

### Was `beamnet doctor` prüft

- Jeder Server: systemd-Dienst vorhanden, läuft, Autostart an, kein Prozess außerhalb von systemd, Dateien gehören dem
  Dienst-Benutzer `beammp`, AuthKey eingetragen, Port nicht doppelt, Port wirklich offen, BeamNetCore meldet sich
  (und keine Fehlermeldungen von BeamNetCore im Protokoll).
- Mehrere Server mit derselben Map.
- **OpenClaw**: läuft der Agent? Hat er in den letzten 24 h Server gestoppt oder beendet? Hat er sudo-Rechte?
- cron-Aufgaben, die BeamMP betreffen (z. B. `auto_install.py` alle 2 Minuten als root).
- SSH-Schlüssel: Anzahl, Fingerabdrücke, ob die Datei in den letzten 24 h geändert wurde.
- Freier Speicherplatz und Arbeitsspeicher.

### Wächter: Ausfälle melden, optional neu starten

```bash
beamnet watch install      # prüft ab jetzt jede Minute alle Server (systemd-Timer)
nano /etc/beamnet.conf     # Discord-Webhook und automatischen Neustart eintragen
beamnet watch test         # Testnachricht an Discord
```

- Meldet „🔴 Server 5 (utah) ist ausgefallen“ und „🟢 … ist wieder online“ – im Systemprotokoll und, wenn eingetragen,
  per **Discord-Webhook**. Jeder Ausfall wird nur einmal gemeldet.
- Mit `AUTO_RESTART=1` startet er ausgefallene Server neu – höchstens 3-mal pro Stunde, danach kommt eine Warnung.
- Er kämpft nicht gegen dich: Mit `beamnet stop` gestoppte Server gelten als Wartung (kein Alarm, kein Neustart), bis
  du sie mit `beamnet start` wieder startest.
- Er kämpft nicht gegen OpenClaw: Hat der Agent einen Server gestoppt, meldet er das, startet aber nicht neu.
- Montags postet er die **Wochensieger** der Vorwoche nach Discord.

### Statusseite für die Community

```bash
beamnet web install 8080   # erzeugt die Seite jede Minute neu und stellt sie auf Port 8080 bereit
ufw allow 8080/tcp         # nur nötig, wenn die Firewall ufw aktiv ist
```

Danach ist sie unter `http://<IP-Adresse des Servers>:8080/` erreichbar – zum Teilen, z. B. in Discord. Sie zeigt alle
Server mit Map, Spielerzahl und wer gerade fährt, die Bestenliste (Level, Liga, XP, Kilometer), die Kilometer dieser
Woche und die Streckenrekorde; hell oder dunkel je nach Gerät, auch fürs Handy. Eigener Titel: `WEB_TITLE=…` in
`/etc/beamnet.conf`. Der kleine Webserver läuft abgeschottet (eigener Benutzer, nur Lesezugriff auf die Seite).

<p><img src="docs/statusseite.png" alt="Statusseite (Beispieldaten)" width="640"> <img src="docs/statusseite-handy.png" alt="Statusseite auf dem Handy" width="200"></p>

## Stand vom 27.07.2026 (letzte Sitzung auf dem Server)

- 12 BeamMP-Server (v3.9.3) unter `/srv/beammp/1` … `/srv/beammp/12`, Ports 30814–30825, Dienste `beammp-1` … `beammp-12`.
- Jeder Server hat eine eigene Map bekommen; alte Konfigurationen liegen in `/root/beammp-config-backup/`.
- Server 1–4 liefen. **Server 5–12 wurden vom OpenClaw-Agenten immer wieder gestoppt** (`systemctl stop` + `pkill` über sudo).
- Der eingetragene SSH-Schlüssel verschwand nach wenigen Minuten aus `/root/.ssh/authorized_keys` – Verursacher unklar
  (OpenClaw oder das root-Skript `auto_install.py`).
- Auf den Servern liefen bereits die Plugins XPSystem, LigaSystem, Rankings, GlobalChat und ein BeamNet-Netzwerk-Plugin
  (von OpenClaw gebaut, ungeprüft).

**Empfohlene Reihenfolge:** `beamnet doctor` → `beamnet backup` → `beamnet openclaw pause` (falls er Server stoppt) →
`beamnet fix` → `beamnet status`.

## Plugin BeamNetCore

Installieren und aktivieren:

```bash
beamnet install-core
beamnet restart all
```

Läuft es, die alten Plugins mit gleichen Aufgaben abschalten (damit Befehle nicht doppelt antworten):

```bash
beamnet plugin-disable XPSystem
beamnet plugin-disable LigaSystem
beamnet plugin-disable Rankings
beamnet restart all
```

### Chat-Befehle

| Befehl | Antwort |
|---|---|
| `/hilfe` | Liste der Befehle |
| `/stats [Name]` | Level, Liga, XP, Kilometer, Fahrzeit, Höchstgeschwindigkeit, Rang, XP bis zum nächsten Level |
| `/top [km \| xp \| woche \| vorwoche]` | Bestenliste (Top 5) – nach XP, Gesamtkilometern, Kilometern dieser oder der letzten Woche |
| `/liga` | Alle Ligen und wie weit es bis zur nächsten ist |
| `/server` | Alle BeamNet-Server mit Map und Spielerzahl (wechseln geht im BeamMP-Launcher) |
| `/km` | Eigene Kilometer |
| `/rennen` | Strecken dieser Map mit Rekord |
| `/rennen <Name>` | Auf Zeit fahren: zum Start fahren, die Zeit läuft ab dem Verlassen des Startbereichs |
| `/rennen stop` | Rennmodus beenden |
| `/rekorde [Name]` | Top 5 einer Strecke bzw. die Rekorde aller Strecken der Map |

Befehle anderer Plugins werden nicht abgefangen.

### Moderation (nur Admins)

| Befehl | Wirkung |
|---|---|
| `/kick <Name> [Grund]` | Wirft den Spieler vom Server |
| `/ban <Name> [30m\|2h\|7d] [Grund]` | Sperrt auf **allen** BeamNet-Servern – sofort, auch wenn er gerade woanders fährt; ohne Dauer dauerhaft. Gäste werden über die IP gesperrt. Funktioniert auch für Spieler, die offline sind |
| `/unban <Name>` · `/bans` | Bann aufheben · aktive Banns zeigen |
| `/warn <Name> <Text>` | Verwarnung nur an diesen Spieler |
| `/mute <Name> [Minuten]` | Im Chat stummschalten (Standard 10 min) |
| `/ansage <Text>` | Nachricht auf allen Servern gleichzeitig, z. B. „Neustart in 5 Minuten“ |

- Teilnamen genügen (`/ban max`), solange sie eindeutig sind – sonst passiert nichts und es kommt ein Hinweis.
- Admins können nicht gesperrt werden und haben keinen Spamschutz.
- **Spamschutz** für alle anderen: mehr als 5 Nachrichten in 5 Sekunden → 30 Sekunden stumm (einstellbar:
  `spamMessages`, `spamWindowSec`, `spamMuteSec` in `config.json`). Befehle funktionieren weiter.
- Alles landet im Moderationsprotokoll (`modlog.jsonl`, lesbar mit `beamnet modlog`).

### Zeitrennen

Admins legen Strecken direkt im Spiel an – keine Koordinaten nötig:

1. Mit dem Auto an den Start stellen: `/rennen neu bergsprint`
2. Zum Ziel fahren: `/rennen ziel bergsprint` (Start = Ziel ergibt einen Rundkurs)
3. Fertig – alle können `/rennen bergsprint` fahren. Entfernen: `/rennen loeschen bergsprint`

Admins (BeamMP-Namen oder -IDs, Gäste nie) einträgst du mit `beamnet admin add Sebi` – wirksam innerhalb einer Minute.

Gemessen wird mit der Spieluhr des Fahrzeugs, der Moment des Überfahrens von Start und Ziel wird zwischen zwei
Messpunkten eingerechnet (etwa eine Zehntelsekunde genau, Messung viermal pro Sekunde während eines Laufs).
Zurücksetzen, Teleport oder mehr als 30 Minuten machen einen Lauf ungültig. Neuer Streckenrekord → Meldung an alle.
Gäste bekommen ihre Zeit, kommen aber nicht in die Rekordliste. Strecken gelten je Map (`races/<Map>.json`).

### So wird gezählt

- **Kilometer**: Position jedes Fahrzeugs einmal pro Sekunde. Sprünge (Teleport, Zurücksetzen, über 540 km/h) und
  Messrauschen im Stand zählen nicht.
- **XP** = 10 je km + 1 je Minute online + Renn-Bonus (15 je gültigem Lauf, +10 für eine persönliche Bestzeit,
  +50 für einen Streckenrekord). **Level** L braucht 25 × (L−1)² XP (Level 10 = 2.025 XP, Level 30 = 21.025 XP).
- **Ligen**: Bronze (0), Silber (500), Gold (2.000), Platin (6.000), Diamant (15.000), Legende (40.000 XP).
- Level-Aufstiege und Liga-Wechsel werden im Chat verkündet, beim Wochenwechsel (Montag 0 Uhr UTC) die
  **Wochensieger** (Top 3 nach Kilometern).
- Gäste (ohne BeamMP-Konto) werden nur für die laufende Sitzung gezählt.

### Daten

Alles liegt in `/srv/beammp/shared/beamnet/`:

- `players/<BeamMP-ID>.json` – je Spieler eine Datei; sie gilt für alle Server. Beim Speichern wird nur der Zuwachs
  ergänzt, daher geht bei einem schnellen Serverwechsel nichts verloren. Dateien werden atomar geschrieben (erst
  Hilfsdatei, dann umbenennen) – ein Absturz hinterlässt keine halbe Datei.
- `servers/<Port>.json` – jeder Server meldet alle 15 s Name, Map und Spieler (daraus entstehen `/server` und `beamnet status`).
- `races/<Map>.json` – Strecken und Rekorde je Map.
- `bans.json`, `announcements.json`, `modlog.jsonl` – Banns, Ansagen, Moderationsprotokoll (für alle Server).
- `config.json` (optional) – Einstellungen ohne Code-Änderung, z. B.:

```json
{
  "admins": ["Sebi"],
  "publicHost": "deine-ip-oder-domain",
  "xpPerKm": 12,
  "xpPerMinute": 1,
  "leagues": [{"xp": 0, "name": "Bronze"}, {"xp": 1000, "name": "Silber"}, {"xp": 5000, "name": "Gold"}]
}
```

Fehlerhafte Einträge werden ignoriert, die Standardwerte bleiben.

## Grenzen (ehrlich)

- **KI-Autos per Chat-Befehl**: Die BeamNG-KI läuft im Spiel der Spieler, nicht auf dem Server. Das geht nur mit einem
  zusätzlichen Client-Mod, und BeamMP zählt solche Autos zum Fahrzeuglimit des Spielers. Nicht eingebaut.
- **Automatischer Serverwechsel**: BeamMP kann Spieler nicht auf einen anderen Server umleiten. Ersatz: `/server`
  zeigt alle Server mit Map und Spielerzahl, gewechselt wird im Launcher.

## Für Entwickler

```bash
bash BeamNet/tests/beamnet_test.sh                 # Werkzeug in einer nachgebauten Server-Umgebung
pip install lupa && python3 BeamNet/tests/run_lua_tests.py   # Plugin unter Lua 5.3 (wie BeamMP), 5.4 und LuaJIT
shellcheck BeamNet/beamnet.sh
```

Die Tests laufen bei jeder Änderung automatisch auf GitHub (Workflow „BeamNet“).

## Nächste Ideen

Siehe [ROADMAP.md](ROADMAP.md).
