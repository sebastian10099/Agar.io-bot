# BeamNet – Werkzeug und Plugin für die BeamMP-Server

Zwei Teile, beide getestet:

1. **`beamnet`** – ein Befehl für die Server-Konsole: zeigt den Zustand aller Server, findet Probleme und repariert sie.
2. **`BeamNetCore`** – ein Server-Plugin: Kilometer, Fahrzeit, XP und Level, Ligen, Bestenliste, **Zeitrennen mit
   Rekordliste** und eine Liste aller Server im Chat – gemeinsam für alle Server.

## Schnellstart (Web-Konsole des Servers, als root)

```bash
# 1. Werkzeug installieren
curl -fsSL https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/friendly-goldberg-31l8fp/BeamNet/beamnet.sh \
  -o /usr/local/bin/beamnet && chmod +x /usr/local/bin/beamnet

# 2. Nachsehen, was los ist (ändert nichts)
beamnet status
beamnet doctor

# 3. Sichern, dann reparieren (fragt vor jedem Schritt)
beamnet backup
beamnet fix
```

**Zum Teilen:** `beamnet report` erstellt einen Bericht mit Status, Diagnose, Plugins und auffälligen Protokollzeilen –
IP-Adressen und AuthKeys sind darin unkenntlich gemacht. Einfach komplett in den Chat kopieren.

## Befehle

| Befehl | Was er macht |
|---|---|
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
| `/top [km \| xp \| woche]` | Bestenliste (Top 5) – nach XP, Gesamtkilometern oder Kilometern dieser Woche |
| `/liga` | Alle Ligen und wie weit es bis zur nächsten ist |
| `/server` | Alle BeamNet-Server mit Map und Spielerzahl (wechseln geht im BeamMP-Launcher) |
| `/km` | Eigene Kilometer |
| `/rennen` | Strecken dieser Map mit Rekord |
| `/rennen <Name>` | Auf Zeit fahren: zum Start fahren, die Zeit läuft ab dem Verlassen des Startbereichs |
| `/rennen stop` | Rennmodus beenden |
| `/rekorde [Name]` | Top 5 einer Strecke bzw. die Rekorde aller Strecken der Map |

Befehle anderer Plugins werden nicht abgefangen.

### Zeitrennen

Admins legen Strecken direkt im Spiel an – keine Koordinaten nötig:

1. Mit dem Auto an den Start stellen: `/rennen neu bergsprint`
2. Zum Ziel fahren: `/rennen ziel bergsprint` (Start = Ziel ergibt einen Rundkurs)
3. Fertig – alle können `/rennen bergsprint` fahren. Entfernen: `/rennen loeschen bergsprint`

Admins stehen in `config.json` (BeamMP-Namen oder -IDs, Gäste nie): `{"admins": ["Sebi"]}`.

Gemessen wird mit der Spieluhr des Fahrzeugs, der Moment des Überfahrens von Start und Ziel wird zwischen zwei
Messpunkten eingerechnet (etwa eine Zehntelsekunde genau, Messung viermal pro Sekunde während eines Laufs).
Zurücksetzen, Teleport oder mehr als 30 Minuten machen einen Lauf ungültig. Neuer Streckenrekord → Meldung an alle.
Gäste bekommen ihre Zeit, kommen aber nicht in die Rekordliste. Strecken gelten je Map (`races/<Map>.json`).

### So wird gezählt

- **Kilometer**: Position jedes Fahrzeugs einmal pro Sekunde. Sprünge (Teleport, Zurücksetzen, über 540 km/h) und
  Messrauschen im Stand zählen nicht.
- **XP** = 10 je km + 1 je Minute online. **Level** L braucht 25 × (L−1)² XP (Level 10 = 2.025 XP, Level 30 = 21.025 XP).
- **Ligen**: Bronze (0), Silber (500), Gold (2.000), Platin (6.000), Diamant (15.000), Legende (40.000 XP).
- Level-Aufstiege und Liga-Wechsel werden im Chat verkündet.
- Gäste (ohne BeamMP-Konto) werden nur für die laufende Sitzung gezählt.

### Daten

Alles liegt in `/srv/beammp/shared/beamnet/`:

- `players/<BeamMP-ID>.json` – je Spieler eine Datei; sie gilt für alle Server. Beim Speichern wird nur der Zuwachs
  ergänzt, daher geht bei einem schnellen Serverwechsel nichts verloren. Dateien werden atomar geschrieben (erst
  Hilfsdatei, dann umbenennen) – ein Absturz hinterlässt keine halbe Datei.
- `servers/<Port>.json` – jeder Server meldet alle 15 s Name, Map und Spieler (daraus entstehen `/server` und `beamnet status`).
- `races/<Map>.json` – Strecken und Rekorde je Map.
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
