#!/usr/bin/env bash
# Tests fuer beamnet.sh in einer nachgebauten Server-Umgebung (Attrappen fuer systemctl, journalctl, pgrep ...).
# Aufruf: bash BeamNet/tests/beamnet_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../beamnet.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILS=0
PASSES=0

pass() { PASSES=$((PASSES + 1)); }
fail() { FAILS=$((FAILS + 1)); printf 'FEHLER: %s\n' "$*"; }
contains() { # contains <ausgabe> <muster> <beschreibung>
    if grep -qE -- "$2" <<<"$1"; then pass; else fail "$3 – erwartet: $2"; printf '%s\n' "$1" | sed 's/^/    | /' | head -60; fi
}
lacks() {
    if grep -qE -- "$2" <<<"$1"; then fail "$3 – unerwartet: $2"; else pass; fi
}

# --- Attrappen ---------------------------------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/state" "$T/units" "$T/root" "$T/backups"
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
S="$FAKE/state"
cmd=$1; shift
[[ $cmd == show ]] && { unit=${*: -1}; cat "$S/$unit.pid" 2>/dev/null || echo 0; exit 0; }
unit=${1:-}
echo "$cmd $unit" >>"$FAKE/actions"
case $cmd in
    cat) [[ -f $FAKE/units/$unit ]] ;;
    is-active) if [[ -f $S/$unit.active ]]; then echo active; else echo inactive; exit 3; fi ;;
    is-enabled) if [[ -f $S/$unit.enabled ]]; then echo enabled; else echo disabled; exit 1; fi ;;
    start|restart) [[ -f $FAKE/units/$unit ]] || exit 5
        if [[ -f $S/$unit.sabotage ]]; then rm -f "$S/$unit.active"; else touch "$S/$unit.active"; fi ;;
    stop) rm -f "$S/$unit.active" ;;
    enable) touch "$S/$unit.enabled" ;;
esac
EOF
cat >"$T/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE/journal.txt" 2>/dev/null
EOF
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE/crontab.txt" 2>/dev/null
EOF
cat >"$T/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ -f $FAKE/agent.pids ]] && cat "$FAKE/agent.pids" || exit 1
EOF
cat >"$T/bin/id" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
    -u) echo "${FAKE_UID:-0}" ;;
    openclaw) [[ -f $FAKE/agent.user ]] && echo "uid=1001(openclaw)" || exit 1 ;;
    *) /usr/bin/id "$@" ;;
esac
EOF
cat >"$T/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
echo "256 SHA256:testfingerprint root@pc (ED25519)"
EOF
cat >"$T/bin/chown" <<'EOF'
#!/usr/bin/env bash
echo "chown $*" >>"$FAKE/actions"
EOF
cat >"$T/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$T/bin/ss" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE/ss.txt" 2>/dev/null
EOF
chmod +x "$T"/bin/*

export FAKE="$T" PATH="$T/bin:$PATH"
ME=$(/usr/bin/id -un)
export BEAMNET_ROOT="$T/root" BEAMNET_USER="$ME" BEAMNET_SHARED="$T/root/shared/beamnet"
export BEAMNET_BACKUP_DIR="$T/backups" BEAMNET_AUTH_KEYS="$T/authorized_keys" BEAMNET_WAIT=0 BEAMNET_FAKE_PROCS="$T/procs"

maps=(gridmap_v2 west_coast_usa italy east_coast_usa utah utah)
for nr in 1 2 3 4 5 6; do
    mkdir -p "$T/root/$nr/Resources/Server/XPSystem"
    port=$((30813 + nr))
    cat >"$T/root/$nr/ServerConfig.toml" <<EOF
[General]
Name = "BeamNet | Server $nr"
Port = $port # Kommentar
AuthKey = "$([[ $nr == 6 ]] || echo "geheim-$nr")"
MaxPlayers = 8
Map = "/levels/${maps[$((nr - 1))]}/info.json"
EOF
    echo "[INFO] Server $nr gestartet" >"$T/root/$nr/Server.log"
    touch "$T/units/beammp-$nr.service"
    touch "$T/state/beammp-$nr.service.enabled"
done
mkdir -p "$T/root/shared" "$T/root/plugins"          # keine Server-Ordner
# Server 1-4 laufen ueber systemd, 5 laeuft wild als root (nohup), 6 ist aus und nicht im Autostart.
: >"$T/procs"
for nr in 1 2 3 4; do
    touch "$T/state/beammp-$nr.service.active"
    echo $((1000 + nr)) >"$T/state/beammp-$nr.service.pid"
    echo "$((1000 + nr)) beammp $T/root/$nr" >>"$T/procs"
done
echo "999991 root $T/root/5" >>"$T/procs"
rm -f "$T/state/beammp-6.service.enabled"
echo "ssh-ed25519 AAAAC3Nza test@pc" >"$T/authorized_keys"
touch -d '3 days ago' "$T/authorized_keys"
printf 'tcp LISTEN 0 4096 *:30814 *:*\n' >"$T/ss.txt"
echo "*/2 * * * * python3 /srv/beammp/plugins/automod/auto_install.py" >"$T/crontab.txt"
touch "$T/agent.user"
echo "4242" >"$T/agent.pids"
cat >"$T/journal.txt" <<'EOF'
Jul 27 14:40:18 srv sudo[1]: openclaw : PWD=/home/openclaw/.openclaw/workspace ; USER=root ; COMMAND=/usr/bin/systemctl stop beammp-5
Jul 27 14:40:18 srv sudo[2]: openclaw : PWD=/home/openclaw/.openclaw/workspace ; USER=root ; COMMAND=/usr/bin/pkill -f /srv/beammp/5/BeamMP
Jul 27 14:41:24 srv sudo[3]: openclaw : PWD=/home/openclaw/.openclaw/workspace ; USER=root ; COMMAND=/usr/bin/systemctl is-active beammp-5
EOF

# --- Tests -------------------------------------------------------------------------------------------------------
out=$("$TOOL" hilfe)
contains "$out" "beamnet doctor" "Hilfe nennt doctor"

out=$("$TOOL" status)
contains "$out" "^1 +läuft +an +systemd \\(beammp\\) +30814 +\\? +gridmap_v2 +BeamNet \\| Server 1" "Status Server 1"
contains "$out" "^5 +aus +an +root/nohup! +30818" "Status erkennt wilden root-Prozess"
contains "$out" "^6 +aus +aus +– +30819" "Status Server 6 aus, kein Autostart"
lacks "$out" "^(shared|plugins) " "Ordner ohne ServerConfig sind keine Server"
contains "$out" "Spielerzahlen erscheinen" "Hinweis auf Plugin"

out=$("$TOOL" doctor)
contains "$out" "6 Server unter" "Doctor zählt Server"
contains "$out" "Server 5 .*läuft außerhalb von systemd \\(Prozess 999991 als root\\)" "Doctor: wilder Prozess"
contains "$out" "Server 6 .*kein AuthKey" "Doctor: fehlender AuthKey"
contains "$out" "Server 6 .*startet nach einem Neustart nicht automatisch" "Doctor: Autostart"
contains "$out" "Port 30815 ist nicht offen" "Doctor: Port nicht offen"
contains "$out" "Mehrere Server mit derselben Map: utah" "Doctor: doppelte Map"
contains "$out" "OpenClaw-Agent läuft \\(Benutzer openclaw, Prozess 4242\\)" "Doctor: OpenClaw läuft"
contains "$out" "/usr/bin/systemctl stop beammp-5" "Doctor zeigt OpenClaw-Stopp"
lacks "$out" "is-active beammp-5" "Doctor: harmlose Abfragen werden nicht als Stopp gemeldet"
contains "$out" "auto_install.py" "Doctor: cron"
contains "$out" "1 Schlüssel in" "Doctor: Schlüssel gezählt"
contains "$out" "SHA256:testfingerprint" "Doctor: Fingerabdruck"
lacks "$out" "geheim-" "Doctor gibt keine AuthKeys aus"
contains "$out" "Problem\\(e\\)" "Doctor: Zusammenfassung"

# Dateirechte: eine Datei gehoert einem anderen Benutzer (braucht root oder sudo ohne Passwort, z. B. in der CI).
touch "$T/root/2/fremd.txt"
if /bin/chown nobody "$T/root/2/fremd.txt" 2>/dev/null || sudo -n /bin/chown nobody "$T/root/2/fremd.txt" 2>/dev/null; then
    out=$("$TOOL" doctor)
    contains "$out" "Server 2 .*Dateien gehören nicht" "Doctor: Dateirechte"
    OWNER_TEST=1
else
    echo "(Dateirechte-Test übersprungen: weder root noch sudo)"
    OWNER_TEST=0
fi

# fix mit -y: Rechte, Autostart, Start. Server 6 wird von OpenClaw sofort wieder gestoppt (Sabotage).
touch "$T/state/beammp-6.service.sabotage"
: >"$T/actions"
out=$("$TOOL" fix -y)
contains "$out" "Server 5: 999991 root" "Fix zeigt wilden Prozess"
[[ $OWNER_TEST == 1 ]] && contains "$(cat "$T/actions")" "chown -hR .* $T/root/2" "Fix setzt Rechte"
contains "$(cat "$T/actions")" "enable beammp-6.service" "Fix schaltet Autostart ein"
contains "$(cat "$T/actions")" "start beammp-5.service" "Fix startet Server 5"
contains "$out" "Wieder aus: Server 6" "Fix erkennt erneutes Stoppen"
contains "$out" "Gestoppt von:" "Fix nennt Verursacher"
contains "$out" "openclaw pause" "Fix empfiehlt OpenClaw anzuhalten"

# Start mit unbekannter Nummer bricht ab, ohne etwas zu tun.
: >"$T/actions"
out=$("$TOOL" start 99 2>&1)
contains "$out" "Server 99 gibt es nicht" "Start: unbekannter Server"
lacks "$(cat "$T/actions")" "^start " "Start: nichts gestartet"

# stop ohne -y und ohne Eingabe: abgebrochen.
: >"$T/actions"
out=$("$TOOL" stop 1 </dev/null 2>&1)
contains "$out" "Abgebrochen" "Stop fragt nach"
lacks "$(cat "$T/actions")" "^stop " "Stop ohne Zustimmung tut nichts"

# set-map
out=$("$TOOL" set-map 6 nordschleife 2>&1)
contains "$out" "keine bekannte Vanilla-Map" "set-map lehnt unbekannte Map ab"
out=$("$TOOL" set-map 6 'utah"; rm -rf /' 2>&1)
contains "$out" "Ungültiger Map-Name" "set-map lehnt Sonderzeichen ab"
rm -f "$T/state/beammp-6.service.sabotage"
out=$("$TOOL" set-map 6 johnson_valley -y 2>&1)
contains "$out" "Server 6: Map = johnson_valley" "set-map setzt Map"
contains "$(cat "$T/root/6/ServerConfig.toml")" '^Map = "/levels/johnson_valley/info.json"$' "set-map schreibt Konfiguration"
contains "$(ls "$T/backups/config/6")" "ServerConfig.toml\\.[0-9]{8}-[0-9]{6}" "set-map sichert vorher (im root-Ordner)"
lacks "$(ls "$T/root/6")" "\\.bak-" "set-map: keine Sicherung im Server-Ordner"
out=$("$TOOL" set-map --force 6 my_mod_map -y 2>&1)
contains "$(cat "$T/root/6/ServerConfig.toml")" "my_mod_map" "set-map --force erlaubt Mod-Map"

out=$("$TOOL" maps)
contains "$out" "^6 +30819 +my_mod_map" "maps zeigt neue Map"

# backup
out=$("$TOOL" backup 2>&1)
contains "$out" "Gesichert: $T/backups/beamnet-" "Backup angelegt"
archive=$(ls "$T"/backups/beamnet-*.tgz | head -n1)
contains "$(tar -tzf "$archive")" "^1/ServerConfig.toml$" "Backup enthält Konfiguration"
contains "$(tar -tzf "$archive")" "^3/Resources/Server/XPSystem/$" "Backup enthält Plugins"

# install-core (Plugin aus dem Ordner neben dem Skript)
out=$("$TOOL" install-core -y 2>&1)
contains "$out" "Server 6: BeamNetCore installiert" "install-core installiert"
[[ -f $T/root/3/Resources/Server/BeamNetCore/main.lua ]] && pass || fail "install-core: Datei fehlt"
[[ -d $T/root/shared/beamnet/players && -d $T/root/shared/beamnet/servers ]] && pass || fail "install-core: gemeinsamer Ordner fehlt"
out=$("$TOOL" plugins)
contains "$out" "Server 1 +.*BeamNetCore" "plugins listet BeamNetCore"
contains "$out" "XPSystem" "plugins listet vorhandene Plugins"

# Altes Plugin abschalten und wieder einschalten (nichts wird geloescht).
out=$("$TOOL" plugin-disable XPSystem -y 2>&1)
contains "$out" "Plugin XPSystem auf 6 Server\(n\) abgeschaltet" "plugin-disable"
[[ -d $T/root/4/Resources/Server.disabled/XPSystem && ! -e $T/root/4/Resources/Server/XPSystem ]] && pass || fail "plugin-disable verschiebt"
out=$("$TOOL" plugins)
contains "$out" "Server 4 +BeamNetCore +· abgeschaltet: XPSystem" "plugins zeigt Abgeschaltetes"
out=$("$TOOL" plugin-disable XPSystem -y 2>&1)
contains "$out" "auf keinem Server gefunden" "plugin-disable doppelt"
out=$("$TOOL" plugin-disable '../etc' -y 2>&1)
contains "$out" "Aufruf: beamnet plugin-disable" "plugin-disable lehnt Pfade ab"
out=$("$TOOL" plugin-disable .. -y 2>&1)
contains "$out" "Aufruf: beamnet plugin-disable" "plugin-disable lehnt .. ab"
[[ -d $T/root/1/Resources/Server ]] && pass || fail "plugin-disable .. hat nichts verschoben"
out=$("$TOOL" plugin-enable XPSystem -y 2>&1)
contains "$out" "eingeschaltet" "plugin-enable"
[[ -d $T/root/4/Resources/Server/XPSystem ]] && pass || fail "plugin-enable stellt wieder her"

# Spielerzahl aus dem Plugin-Status (frisch und veraltet)
now=$(date +%s)
echo "{\"server\":1,\"port\":30814,\"players\":3,\"max\":8,\"updated\":$now,\"api\":{\"positions\":true}}" >"$T/root/shared/beamnet/servers/30814.json"
echo "{\"port\":30816,\"players\":0,\"max\":8,\"updated\":$now,\"api\":{\"files\":true,\"positions\":false}}" >"$T/root/shared/beamnet/servers/30816.json"
echo "{\"server\":2,\"port\":30815,\"players\":5,\"max\":8,\"updated\":$((now - 600))}" >"$T/root/shared/beamnet/servers/30815.json"
out=$("$TOOL" status)
contains "$out" "^1 +läuft .* 30814 +3/8 " "Status zeigt Spieler"
contains "$out" "^2 +läuft .* 30815 +\\? " "Status ignoriert veraltete Spielerzahl"

# Plugin-Check im doctor: Server 1 meldet sich frisch, Server 3 nie, Server 2 veraltet.
echo "[LUA] [BeamNetCore] Fehler im Takt: attempt to index a nil value" >>"$T/root/2/Server.log"
out=$("$TOOL" doctor)
contains "$out" "Server 1 .*BeamNetCore aktiv" "doctor: Plugin aktiv"
contains "$out" "Server 2 .*BeamNetCore meldet sich seit 10 min nicht mehr" "doctor: Plugin veraltet"
contains "$out" "Server 3 .*BeamNetCore aktiv" "doctor: Plugin Server 3 aktiv"
contains "$out" "Server 3 .*BeamMP-Server zu alt" "doctor: fehlende BeamMP-Funktion"
lacks "$out" "Server 1 .*BeamMP-Server zu alt" "doctor: Server 1 hat alle Funktionen"
contains "$out" "Server 4 .*BeamNetCore ist installiert, hat sich aber noch nie gemeldet" "doctor: Plugin nie gemeldet"
contains "$out" "Server 2 .*Fehlermeldung von BeamNetCore: .*attempt to index" "doctor: Plugin-Fehler im Protokoll"

# Bericht zum Teilen: ohne IP-Adressen und AuthKeys, ohne Farbcodes.
echo "[INFO] Client 192.168.178.20 connected" >>"$T/root/1/Server.log"
echo "[ERROR] Connection from 85.12.1.200 failed: timeout" >>"$T/root/1/Server.log"
echo 'AuthKey = "geheim-1" # error' >>"$T/root/1/Server.log"
out=$("$TOOL" report 2>&1)
contains "$out" "=== BeamNet-Bericht" "report: Kopf"
contains "$out" "=== Status ===" "report: Status"
contains "$out" "BeamNet-Diagnose" "report: Diagnose"
contains "$out" "=== Plugins ===" "report: Plugins"
contains "$out" "Connection from x.x.x.x failed" "report: Fehlerzeile mit maskierter IP"
lacks "$out" "85\\.12\\.1\\.200|192\\.168" "report: keine IP-Adressen"
lacks "$out" "geheim-" "report: keine AuthKeys"
lacks "$out" $'\e\\[' "report: keine Farbcodes"

# OpenClaw
out=$("$TOOL" openclaw status 2>&1)
contains "$out" "Letzte Befehle von openclaw" "openclaw status"
rm -f "$T/agent.user"
out=$("$TOOL" doctor)
contains "$out" "Kein Benutzer openclaw" "Ohne OpenClaw keine Warnung"

# --- Waechter ------------------------------------------------------------------------------------------------------
export BEAMNET_CONF="$T/beamnet.conf" BEAMNET_STATE="$T/watch" BEAMNET_SYSTEMD_DIR="$T/systemd"
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/curl.log"
[[ -f $FAKE/curl.fail ]] && exit 22
exit 0
EOF
chmod +x "$T/bin/curl"
for nr in 1 2 3 4 5 6; do touch "$T/state/beammp-$nr.service.active" "$T/state/beammp-$nr.service.enabled"; done
rm -f "$T"/state/*.sabotage
: >"$T/actions"
out=$("$TOOL" watch install 2>&1)
contains "$out" "Wächter eingerichtet" "watch install"
[[ -f $T/systemd/beamnet-watch.timer && -f $T/beamnet.conf ]] && pass || fail "watch install: Dateien fehlen"
contains "$(cat "$T/systemd/beamnet-watch.service")" "^ExecStart=.*beamnet.sh watch$" "watch install: Dienst ruft das Werkzeug"
contains "$(cat "$T/actions")" "enable --now" "watch install: Timer aktiviert"
contains "$(cat "$T/beamnet.conf")" "^AUTO_RESTART=0$" "watch install: Neustart standardmaessig aus"
contains "$(cat "$T/beamnet.conf")" "^MAP_VOTE=1$" "watch install: Map-Abstimmung standardmaessig an"

out=$("$TOOL" watch 2>&1)
lacks "$out" "ausgefallen|online" "watch: erste Runde ohne Meldung"
rm -f "$T/state/beammp-3.service.active"
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
contains "$out" "🔴 Server 3 \\(italy\\) ist ausgefallen" "watch: Ausfall gemeldet"
lacks "$(cat "$T/actions")" "restart beammp-3" "watch: ohne AUTO_RESTART kein Neustart"
out=$("$TOOL" watch 2>&1)
lacks "$out" "ausgefallen" "watch: Ausfall nur einmal gemeldet"

sed -i 's/^AUTO_RESTART=0/AUTO_RESTART=1/; s|^DISCORD_WEBHOOK=|DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc|' "$T/beamnet.conf"
: >"$T/curl.log"
out=$("$TOOL" watch 2>&1)
contains "$out" "🟡 Server 3 \\(italy\\) automatisch neu gestartet" "watch: automatischer Neustart"
contains "$(cat "$T/curl.log")" '\{"content":"🟡 Server 3 \(italy\) automatisch neu gestartet\.","allowed_mentions":\{"parse":\[\]\}\}' "watch: Discord-Nachricht als JSON (ohne @-Erwähnungen)"
contains "$(cat "$T/curl.log")" "https://discord.com/api/webhooks/1/abc" "watch: an den Webhook"

# Bewusst gestoppt: keine Meldung, kein Neustart; Start hebt die Wartung auf.
"$TOOL" stop 2 -y >/dev/null
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
lacks "$out" "Server 2" "watch: Wartung wird nicht gemeldet"
lacks "$(cat "$T/actions")" "restart beammp-2" "watch: Wartung wird nicht neu gestartet"
out=$("$TOOL" watch status 2>&1)
contains "$out" "In Wartung \\(bewusst gestoppt\\): 2" "watch status: Wartung"
contains "$out" "Discord: an" "watch status: Discord"
"$TOOL" start 2 >/dev/null
[[ ! -f $T/watch/maintenance-2 ]] && pass || fail "start hebt Wartung auf"

# Von OpenClaw gestoppt: melden, aber nicht dagegen ankaempfen.
echo "Oct 14 10:00:00 srv sudo[9]: openclaw : PWD=/home/openclaw ; USER=root ; COMMAND=/usr/bin/systemctl stop beammp-4" >>"$T/journal.txt"
rm -f "$T/state/beammp-4.service.active"
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
contains "$out" "Server 4 \\(east_coast_usa\\) wurde von OpenClaw gestoppt – kein automatischer Neustart" "watch: OpenClaw erkannt"
lacks "$(cat "$T/actions")" "restart beammp-4" "watch: kein Kampf gegen OpenClaw"

# Server 6 startet nie: hoechstens 3 Neustarts pro Stunde, dann eine Warnung.
touch "$T/state/beammp-6.service.sabotage"
rm -f "$T/state/beammp-6.service.active"
"$TOOL" watch >/dev/null 2>&1
"$TOOL" watch >/dev/null 2>&1
out=$("$TOOL" watch 2>&1)
contains "$out" "Neustart von Server 6 .* fehlgeschlagen" "watch: Neustart fehlgeschlagen"
out=$("$TOOL" watch 2>&1)
contains "$out" "zu viele Neustarts in einer Stunde" "watch: Neustart-Limit"
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
lacks "$out" "Server 6" "watch: Limit-Warnung nur einmal"
lacks "$(cat "$T/actions")" "restart beammp-6" "watch: nach dem Limit kein Neustart"
rm -f "$T/state/beammp-6.service.sabotage"
touch "$T/state/beammp-6.service.active"
out=$("$TOOL" watch 2>&1)
contains "$out" "🟢 Server 6 \\(my_mod_map\\) ist wieder online" "watch: wieder online"

# Wochensieger montags nach Discord (einmal je Woche).
lastweek=$(date -u -d '7 days ago' +%G-W%V)
echo "{\"id\":\"1\",\"name\":\"Sebi\",\"week\":\"$lastweek\",\"weekKm\":42.5}" >"$T/root/shared/beamnet/players/1.json"
echo "{\"id\":\"2\",\"name\":\"Max\",\"lastWeek\":\"$lastweek\",\"lastWeekKm\":12}" >"$T/root/shared/beamnet/players/2.json"
: >"$T/curl.log"
out=$(BEAMNET_DOW=1 "$TOOL" watch 2>&1)
contains "$out" "🏁 Wochensieger .* KW .*: 1\\. Sebi \\(42\\.5 km\\) · 2\\. Max \\(12\\.0 km\\)" "watch: Wochensieger"
contains "$(cat "$T/curl.log")" "Wochensieger" "watch: Wochensieger an Discord"
out=$(BEAMNET_DOW=1 "$TOOL" watch 2>&1)
lacks "$out" "Wochensieger" "watch: Wochensieger nur einmal"
# Saisonsieger am 1. des Monats nach Discord (aus dem Archiv, sonst aus den Spielerdaten; einmal je Monat).
prevmonth=$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m)
mkdir -p "$T/root/shared/beamnet/seasons"
echo "{\"month\":\"$prevmonth\",\"top\":[{\"name\":\"Sebi\",\"xp\":900},{\"name\":\"Max\",\"xp\":300}]}" >"$T/root/shared/beamnet/seasons/$prevmonth.json"
: >"$T/curl.log"
out=$(BEAMNET_DOM=02 "$TOOL" watch 2>&1)
lacks "$out" "Saisonsieger" "watch: Saisonsieger nur am 1."
out=$(BEAMNET_DOM=01 "$TOOL" watch 2>&1)
contains "$out" "🏆 Saisonsieger $prevmonth: 1\\. Sebi \\(900 XP\\) · 2\\. Max \\(300 XP\\)" "watch: Saisonsieger aus dem Archiv"
contains "$(cat "$T/curl.log")" "Saisonsieger" "watch: Saisonsieger an Discord"
out=$(BEAMNET_DOM=01 "$TOOL" watch 2>&1)
lacks "$out" "Saisonsieger" "watch: Saisonsieger nur einmal"
rm -f "$T/watch/season-$prevmonth" "$T/root/shared/beamnet/seasons/$prevmonth.json"
echo "{\"id\":\"1\",\"name\":\"Sebi\",\"lastMonth\":\"$prevmonth\",\"lastMonthXp\":120}" >"$T/root/shared/beamnet/players/1.json"
echo "{\"id\":\"2\",\"name\":\"Max\",\"month\":\"$prevmonth\",\"monthXp\":450}" >"$T/root/shared/beamnet/players/2.json"
out=$(BEAMNET_DOM=01 "$TOOL" watch 2>&1)
contains "$out" "🏆 Saisonsieger $prevmonth: 1\\. Max \\(450 XP\\) · 2\\. Sebi \\(120 XP\\)" "watch: Saisonsieger aus den Spielerdaten"

sed -i 's|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=http://example.com/hook|' "$T/beamnet.conf"
rm -f "$T/state/beammp-1.service.active"
out=$("$TOOL" watch 2>&1)
contains "$out" "sieht nicht wie ein Discord-Webhook aus" "watch: falscher Webhook wird abgelehnt"

# Map-Abstimmung: Lebenszeichen fuer das Plugin und Auftraege aus votes/<Port>.json.
V="$T/root/shared/beamnet/votes"
mkdir -p "$V"
"$TOOL" watch >/dev/null 2>&1
hb=$(cat "$T/root/shared/beamnet/watch.json")
contains "$hb" '^\{"at":[0-9]+,"mapVote":true,"maps":\["gridmap_v2",.*"automation_test_track"\]\}$' "watch: Lebenszeichen mit Maps"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$T/root/shared/beamnet/watch.json" && pass || fail "watch: Lebenszeichen ist gültiges JSON"
vote() { echo "{\"at\":${3:-$(date +%s)},\"by\":\"Sebi \\\"map\\\":\\\"x\\\"\",\"from\":\"utah\",\"map\":\"$2\",\"no\":0,\"online\":3,\"port\":$1,\"yes\":2}" >"$V/$1.json"; }
vote 30818 italy
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
contains "$out" "🗺️ Server 5: Map per Abstimmung von utah auf italy gewechselt" "watch: Abstimmung umgesetzt"
contains "$(cat "$T/root/5/ServerConfig.toml")" '^Map = "/levels/italy/info.json"$' "watch: Map in der Konfiguration"
contains "$(cat "$T/actions")" "restart beammp-5" "watch: Neustart nach Abstimmung"
[[ ! -f $V/30818.json ]] && pass || fail "watch: Auftrag erledigt und entfernt"
vote 30818 utah
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
lacks "$(cat "$T/actions")" "restart beammp-5" "watch: höchstens ein Wechsel in 5 Minuten"
[[ ! -f $V/30818.json ]] && pass || fail "watch: auch abgewiesene Aufträge werden entfernt"
rm -f "$T/watch/mapvote-5"
vote 30818 evil_mod
out=$("$TOOL" watch 2>&1)
contains "$out" "Port 30818: Map nicht erlaubt" "watch: nur erlaubte Maps"
lacks "$out" "evil_mod" "watch: unerlaubter Text geht nicht nach Discord"
contains "$(cat "$T/root/5/ServerConfig.toml")" "/levels/italy/" "watch: nicht erlaubte Map ändert nichts"
sed -i 's/^VOTE_MAPS=.*/VOTE_MAPS=evil_mod/' "$T/beamnet.conf"
vote 30818 evil_mod
out=$("$TOOL" watch 2>&1)
contains "$out" "von italy auf evil_mod gewechselt" "watch: VOTE_MAPS erlaubt weitere Maps"
contains "$(cat "$T/root/shared/beamnet/watch.json")" '"evil_mod"\]' "watch: Lebenszeichen nennt VOTE_MAPS"
rm -f "$T/watch/mapvote-5"
vote 30818 utah $(( $(date +%s) - 3600 ))
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
lacks "$(cat "$T/actions")" "restart beammp-5" "watch: alte Aufträge verfallen"
sed -i 's/^MAP_VOTE=.*/MAP_VOTE=0/' "$T/beamnet.conf"
vote 30818 utah
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
lacks "$(cat "$T/actions")" "restart beammp-5" "watch: MAP_VOTE=0 schaltet ab"
contains "$(cat "$T/root/shared/beamnet/watch.json")" '"mapVote":false' "watch: Lebenszeichen meldet aus"
contains "$("$TOOL" watch status 2>&1)" "Map-Abstimmung: aus" "watch status: Abstimmung"
sed -i 's/^MAP_VOTE=.*/MAP_VOTE=1/; s/^VOTE_MAPS=.*/VOTE_MAPS=/' "$T/beamnet.conf"

# Taegliche Map-Rotation (nur wenn der Server leer ist, einmal am Tag).
out=$("$TOOL" rotation 5 italy 2>&1)
contains "$out" "mindestens zwei Maps" "rotation: mindestens zwei Maps"
out=$("$TOOL" rotation 5 italy mond 2>&1)
contains "$out" "mond ist weder Vanilla-Map" "rotation: nur erlaubte Maps"
out=$("$TOOL" rotation 5 italy utah 2>&1)
contains "$out" "Server 5: täglich wechselnd italy utah" "rotation: festgelegt"
contains "$("$TOOL" rotation 2>&1)" "Server 5: italy utah" "rotation: Anzeige"
status5() { echo "{\"port\":30818,\"players\":$1,\"max\":8,\"updated\":$(date +%s)}" >"$T/root/shared/beamnet/servers/30818.json"; }
status5 0
: >"$T/actions"
BEAMNET_HOUR=05 "$TOOL" watch >/dev/null 2>&1
lacks "$(cat "$T/actions")" "restart beammp-5" "rotation: nicht vor der Uhrzeit"
status5 2
BEAMNET_HOUR=07 "$TOOL" watch >/dev/null 2>&1
lacks "$(cat "$T/actions")" "restart beammp-5" "rotation: nicht, solange jemand fährt"
status5 0
out=$(BEAMNET_HOUR=07 "$TOOL" watch 2>&1)
contains "$out" "🔄 Server 5: Map des Tages ist jetzt italy \\(vorher evil_mod\\)" "rotation: Wechsel, sobald leer"
contains "$(cat "$T/root/5/ServerConfig.toml")" '^Map = "/levels/italy/info.json"$' "rotation: Map in der Konfiguration"
: >"$T/actions"
status5 0
BEAMNET_HOUR=08 "$TOOL" watch >/dev/null 2>&1
lacks "$(cat "$T/actions")" "restart beammp-5" "rotation: nur einmal am Tag"
rm -f "$T/watch/rotate-5"; status5 0
out=$(BEAMNET_HOUR=07 "$TOOL" watch 2>&1)
contains "$out" "Map des Tages ist jetzt utah \\(vorher italy\\)" "rotation: nächster Tag, nächste Map"
rm -f "$T/watch/rotate-5"; status5 0
out=$(BEAMNET_HOUR=07 "$TOOL" watch 2>&1)
contains "$out" "Map des Tages ist jetzt italy \\(vorher utah\\)" "rotation: Liste beginnt von vorn"
"$TOOL" rotation 5 aus >/dev/null 2>&1
rm -f "$T/watch/rotate-5"; status5 0
: >"$T/actions"
BEAMNET_HOUR=07 "$TOOL" watch >/dev/null 2>&1
lacks "$(cat "$T/actions")" "restart beammp-5" "rotation: abschaltbar"

# doctor prueft das Lebenszeichen des Waechters.
"$TOOL" rotation 3 italy utah >/dev/null 2>&1
"$TOOL" watch >/dev/null 2>&1
out=$("$TOOL" doctor 2>&1)
contains "$out" "Wächter läuft \\(zuletzt vor [0-9]+ s\\)" "doctor: Wächter läuft"
contains "$out" "Server 3: tägliche Map-Rotation \\(italy utah\\)" "doctor: Rotation"
"$TOOL" rotation 3 aus >/dev/null 2>&1
echo "{\"at\":$(( $(date +%s) - 1200 )),\"mapVote\":true,\"maps\":[]}" >"$T/root/shared/beamnet/watch.json"
out=$("$TOOL" doctor 2>&1)
contains "$out" "letztes Lebenszeichen vor 20 Minuten – er läuft nicht mehr" "doctor: Wächter steht"

out=$("$TOOL" watch uninstall 2>&1)
contains "$out" "Wächter entfernt" "watch uninstall"
contains "$("$TOOL" doctor 2>&1)" "Wächter nicht eingerichtet" "doctor: ohne Wächter ein Hinweis"
[[ ! -f $T/systemd/beamnet-watch.timer && -f $T/beamnet.conf ]] && pass || fail "watch uninstall: Timer weg, Einstellungen bleiben"

# --- Statusseite --------------------------------------------------------------------------------------------------
export BEAMNET_WEB_DIR="$T/web"
rm -f "$T"/root/shared/beamnet/servers/*.json "$T"/root/shared/beamnet/players/*.json
now=$(date +%s)
week=$(date -u +%G-W%V)
echo "{\"name\":\"BeamNet | Server 1\",\"port\":30814,\"map\":\"gridmap_v2\",\"players\":2,\"max\":8,\"names\":[\"Sebi\",\"<b>Hacker</b>\"],\"updated\":$now}" >"$T/root/shared/beamnet/servers/30814.json"
echo "{\"name\":\"Alt\",\"port\":30899,\"map\":\"x\",\"players\":9,\"max\":8,\"updated\":$((now - 3600))}" >"$T/root/shared/beamnet/servers/30899.json"
month=$(date -u +%Y-%m)
echo "{\"id\":\"1\",\"name\":\"Sebi\",\"km\":120.4,\"seconds\":7200,\"xp\":1500,\"week\":\"$week\",\"weekKm\":33.3,\"month\":\"$month\",\"monthStartXp\":1000}" >"$T/root/shared/beamnet/players/1.json"
echo "{\"id\":\"2\",\"name\":\"<b>Hacker</b>\",\"km\":2,\"seconds\":60,\"bonusXp\":5}" >"$T/root/shared/beamnet/players/2.json"
echo "kaputt" >"$T/root/shared/beamnet/players/3.json"
# Ab Plugin 1.9: Saison-XP als Zaehler (monthXp) statt Startwert.
echo "{\"id\":\"4\",\"name\":\"Zaehler\",\"km\":40,\"seconds\":0,\"xp\":400,\"month\":\"$month\",\"monthXp\":321,\"mapKm\":{\"italy\":30.5,\"utah\":9.5}}" >"$T/root/shared/beamnet/players/4.json"
mkdir -p "$T/root/shared/beamnet/races"
echo '{"tracks":{"sprint":{"records":[{"id":"1","name":"Sebi","time":49.0667}]},"leer":{"records":[]}}}' >"$T/root/shared/beamnet/races/italy.json"
out=$("$TOOL" web run 2>&1)
contains "$out" "Statusseite erzeugt" "web run"
page=$(cat "$T/web/index.html")
contains "$page" "<title>BeamNet – Status</title>" "Statusseite: Titel"
contains "$page" "<td><b>BeamNet \\| Server 1</b><div class=small>Sebi, &lt;b&gt;Hacker&lt;/b&gt;</div></td><td>Grid Map</td><td class=n>2/8</td>" "Statusseite: Server"
lacks "$page" ">Alt<" "Statusseite: veraltete Server fehlen"
contains "$page" "1 Server online · 2 Spieler" "Statusseite: Zusammenfassung"
contains "$page" "<td class=n>1</td><td><a href=\"p/1.html\">Sebi</a></td><td class=n>8</td><td>Silber</td><td class=n>1500</td><td class=n>120 km</td><td class=n>0</td>" "Statusseite: Bestenliste"
contains "$page" "&lt;b&gt;Hacker&lt;/b&gt;" "Statusseite: Namen werden maskiert"
lacks "$page" "<b>Hacker</b>" "Statusseite: kein HTML aus Spielernamen"
contains "$page" "<td class=n>1</td><td><a href=\"p/1.html\">Sebi</a></td><td class=n>33.3 km</td>" "Statusseite: Woche"
contains "$page" "<td>Italy</td><td>sprint</td><td>Sebi</td><td class=n>0:49.1</td>" "Statusseite: Rekorde"
contains "$page" "<h2>Saison [A-Za-zä]+ [0-9]{4}</h2>.*<td class=n>1</td><td><a href=\"p/1.html\">Sebi</a></td><td class=n>500</td>" "Statusseite: Saison"
contains "$page" "<td class=n>2</td><td><a href=\"p/4.html\">Zaehler</a></td><td class=n>321</td>" "Statusseite: Saison-Zaehler (1.9)"
contains "$page" "<th class=n>XP</th>" "Statusseite: Zahlenspalten rechtsbuendig"
prof=$(cat "$T/web/p/1.html")
contains "$prof" "<h1>Sebi</h1>" "Profilseite: Name"
contains "$page" "<h2>Beliebteste Maps</h2>.*<td>Italy</td><td class=n>30.5 km</td><td class=n>1</td>" "Statusseite: Beliebteste Maps"
contains "$(cat "$T/web/p/4.html")" "Lieblingsmap<b>Italy</b>" "Profilseite: Lieblingsmap"
contains "$(cat "$T/web/p/4.html")" "<span>Italy · 30.5 km</span><span>Utah, USA · 9.5 km</span>" "Profilseite: km je Map"
contains "$prof" "Rang<b>1 von 3</b>" "Profilseite: Rang"
contains "$prof" "Kilometer<b>120 km</b>" "Profilseite: Kilometer"
contains "$prof" "<td>Italy</td><td>sprint</td><td class=n>0:49.1</td><td class=n>1</td>" "Profilseite: Bestzeiten"
contains "$prof" "href=\"../index.html\"" "Profilseite: Link zurueck"
contains "$(cat "$T/web/p/2.html")" "<h1>&lt;b&gt;Hacker&lt;/b&gt;</h1>" "Profilseite: Namen maskiert"
echo "{\"id\":\"../böse\",\"name\":\"X\",\"km\":1}" >"$T/root/shared/beamnet/players/5.json"
touch "$T/web/p/alt.html"
"$TOOL" web run >/dev/null 2>&1
[[ ! -e $T/web/p/alt.html ]] && pass || fail "Profilseite: alte Seiten werden entfernt"
[[ -z $(find "$T/web" -name '*böse*') ]] && pass || fail "Profilseite: unsichere ID ohne Seite"
lacks "$(cat "$T/web/index.html")" "böse.html" "Profilseite: kein Link fuer unsichere ID"
rm -f "$T/root/shared/beamnet/players/5.json"
contains "$page" "</html>" "Statusseite: vollstaendig"
echo "WEB_TITLE=Sebis Netz" >>"$T/beamnet.conf"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" "<title>Sebis Netz – Status</title>" "Statusseite: eigener Titel"

: >"$T/actions"
out=$("$TOOL" web install 99 2>&1)
contains "$out" "Port muss zwischen 1024 und 65535" "web install: Port geprueft"
out=$("$TOOL" web install 8088 2>&1)
contains "$out" "Statusseite läuft auf Port 8088" "web install"
contains "$(cat "$T/systemd/beamnet-web.service")" "http.server 8088 --bind 0.0.0.0 --directory $T/web" "web install: Webserver"
contains "$(cat "$T/systemd/beamnet-web.service")" "^DynamicUser=yes" "web install: abgeschottet"
contains "$(cat "$T/systemd/beamnet-web-update.service")" "beamnet.sh web run$" "web install: Erneuern"
contains "$(cat "$T/actions")" "enable --now" "web install: aktiviert"
out=$("$TOOL" web uninstall 2>&1)
[[ ! -f $T/systemd/beamnet-web.service ]] && pass || fail "web uninstall"

# --- Moderation ----------------------------------------------------------------------------------------------------
out=$("$TOOL" bans 2>&1)
contains "$out" "Keine Banns" "bans: leer"
now=$(date +%s)
cat >"$T/root/shared/beamnet/bans.json" <<EOF
{"bans":[{"id":"2002","name":"Max","reason":"Beleidigung","by":"Sebi","at":$now,"until":$((now + 7200))},
{"ip":"7.7.7.7","name":"Gast42","reason":"Spam","by":"Sebi","at":$now},
{"id":"5","name":"Alt","reason":"vorbei","by":"Sebi","at":1,"until":2}]}
EOF
out=$("$TOOL" bans 2>&1)
contains "$out" "^Max \\(2002\\) – Beleidigung – bis .* – von Sebi" "bans: Zeitbann"
contains "$out" "^Gast42 \\(IP 7\\.7\\.7\\.7\\) – Spam – bis dauerhaft" "bans: IP-Bann"
contains "$out" "\\(1 abgelaufene Banns gespeichert\\)" "bans: abgelaufene"
lacks "$out" "^Alt " "bans: abgelaufene nicht als aktiv"
out=$("$TOOL" unban max 2>&1)
contains "$out" 'Bann für "max" aufgehoben \(1\)' "unban"
lacks "$("$TOOL" bans)" "^Max " "unban wirkt"
out=$("$TOOL" unban niemand 2>&1)
contains "$out" 'Kein Bann für "niemand"' "unban: unbekannt"
printf '%s\n' "{\"action\":\"ban\",\"by\":\"Sebi\",\"target\":\"Max\",\"reason\":\"Beleidigung\",\"at\":$now,\"server\":30814,\"until\":$((now + 7200))}" \
    '{"action":"kick","by":"Sebi","target":"Tom","reason":"","at":1,"server":30815}' 'kaputt' >"$T/root/shared/beamnet/modlog.jsonl"
out=$("$TOOL" modlog 2>&1)
contains "$out" "Port 30814 · Sebi: ban Max Beleidigung \\(bis " "modlog: Bann"
contains "$out" "Port 30815 · Sebi: kick Tom$" "modlog: Kick"

# --- Admins --------------------------------------------------------------------------------------------------------
out=$("$TOOL" admin list 2>&1)
contains "$out" "Admins: keine" "admin list leer"
echo '{"xpPerKm": 12}' >"$T/root/shared/beamnet/config.json"
out=$("$TOOL" admin add Sebi Max 2>&1)
contains "$out" "Admins: Sebi, Max" "admin add"
contains "$out" "Wirksam innerhalb einer Minute" "admin add: Hinweis"
out=$("$TOOL" admin add sebi 2>&1)
contains "$out" "Admins: Sebi, Max$" "admin add: keine Doppelten"
out=$("$TOOL" admin remove max 2>&1)
contains "$out" "Admins: Sebi$" "admin remove"
contains "$(cat "$T/root/shared/beamnet/config.json")" '"xpPerKm": 12' "admin: andere Einstellungen bleiben"
out=$("$TOOL" admin add 'x"; rm -rf /' 2>&1)
contains "$out" "Ungültiger Name" "admin: unsichere Namen abgelehnt"
echo "{kaputt" >"$T/root/shared/beamnet/config.json"
out=$("$TOOL" admin add Tom 2>&1)
contains "$out" "config.json ist fehlerhaft" "admin: kaputte config.json wird nicht ueberschrieben"
contains "$(cat "$T/root/shared/beamnet/config.json")" "^\\{kaputt$" "admin: kaputte Datei unveraendert"
rm -f "$T/root/shared/beamnet/config.json"

# Regression: "all" muss auch funktionieren, wenn der letzte Ordner kein Server ist (hier: shared, plugins).
: >"$T/actions"
out=$("$TOOL" restart all -y 2>&1)
for nr in 1 2 3 4 5 6; do contains "$(cat "$T/actions")" "^restart beammp-$nr.service$" "restart all erreicht Server $nr"; done
: >"$T/actions"
"$TOOL" start >/dev/null 2>&1
contains "$(cat "$T/actions")" "^start beammp-6.service$" "start ohne Nummer erreicht alle Server"

# --- Einrichtungs-Assistent ---------------------------------------------------------------------------------------
rm -f "$T/agent.pids" "$T/agent.user"               # kein OpenClaw (nie echte Prozesse anhalten)
rm -rf "$T/systemd" "$T/watch" "$T/beamnet.conf" "$T/web"
# Alles verneinen: nichts darf passieren.
: >"$T/actions"
out=$(printf '\n\n\n\n\n\n\n\n\n\n' | "$TOOL" setup 2>&1)
contains "$out" "Schritt 1/9: Diagnose" "setup: Diagnose"
contains "$out" "Schritt 9/9: Neustart" "setup: alle Schritte"
lacks "$(cat "$T/actions")" "^(start|restart|stop|enable) " "setup ohne Zustimmung aendert nichts"
[[ ! -f $T/systemd/beamnet-watch.timer ]] && pass || fail "setup ohne Zustimmung: kein Waechter"
# Alles bejahen (mit Admins, Webhook, Port).
rm -rf "$T/root/1/Resources/Server/BeamNetCore"
answers='j\nj\nj\nj\nSebi Max\nj\nhttps://discord.com/api/webhooks/123/abc_DEF-9\nj\nj\n8090\nj\n'
: >"$T/actions"
out=$(printf "$answers" | "$TOOL" setup 2>&1)
contains "$out" "Gesichert: $T/backups/" "setup: Sicherung"
[[ -f $T/root/1/Resources/Server/BeamNetCore/main.lua ]] && pass || fail "setup: Plugin installiert"
contains "$out" "Plugin XPSystem auf 6 Server\\(n\\) abgeschaltet" "setup: alte Plugins abgeschaltet"
contains "$("$TOOL" admin list)" "Admins: Sebi, Max" "setup: Admins"
contains "$(cat "$T/beamnet.conf")" "^DISCORD_WEBHOOK=https://discord.com/api/webhooks/123/abc_DEF-9$" "setup: Webhook"
contains "$(cat "$T/beamnet.conf")" "^AUTO_RESTART=1$" "setup: automatischer Neustart"
[[ $(grep -c '^DISCORD_WEBHOOK=' "$T/beamnet.conf") == 1 ]] && pass || fail "setup: Webhook nur einmal in der Datei"
contains "$(cat "$T/systemd/beamnet-web.service")" "http.server 8090" "setup: Statusseite auf Port 8090"
contains "$(cat "$T/actions")" "restart beammp-6.service" "setup: Neustart"
contains "$out" "Zum Teilen mit mir: beamnet report" "setup: Abschluss"
# Ungueltiger Webhook wird nicht gespeichert.
out=$(printf '\n\n\n\nj\nhttp://evil.example/x\n\nj\nkeinport\n\n' | "$TOOL" setup 2>&1)
contains "$out" "keine Discord-Webhook-URL" "setup: falscher Webhook abgelehnt"
contains "$(cat "$T/beamnet.conf")" "^DISCORD_WEBHOOK=https://discord.com/api/webhooks/123/abc_DEF-9$" "setup: alter Webhook bleibt"
contains "$out" "Ungültiger Port 'keinport' – Statusseite übersprungen" "setup: ungueltiger Port bricht nicht ab"
contains "$out" "Zum Teilen mit mir" "setup laeuft nach ungueltigem Port bis zum Ende"
"$TOOL" plugin-enable XPSystem -y >/dev/null 2>&1

# --- Funde aus der Code-Pruefung ---------------------------------------------------------------------------------
# (12) Ein Server-Prozess als Kind eines Start-Skripts gehoert zum Dienst (cgroup), auch wenn er nicht MainPID ist.
echo "3003 beammp $T/root/3 beammp-3.service" >>"$T/procs"
out=$("$TOOL" doctor 2>&1)
lacks "$out" "Server 3 .*außerhalb von systemd" "doctor: Kindprozess des Dienstes ist kein wilder Prozess"
contains "$out" "Server 5 .*außerhalb von systemd \\(Prozess 999991 als root\\)" "doctor: echter wilder Prozess bleibt erkannt"
sed -i '/^3003 /d' "$T/procs"

# (6) Wartung endet, sobald der Server wieder laeuft – egal wie er gestartet wurde.
"$TOOL" watch install >/dev/null 2>&1
sed -i 's/^AUTO_RESTART=.*/AUTO_RESTART=0/' "$T/beamnet.conf"
"$TOOL" stop 2 -y >/dev/null 2>&1
"$TOOL" watch >/dev/null 2>&1
touch "$T/state/beammp-2.service.active"           # direkt per systemctl gestartet
"$TOOL" watch >/dev/null 2>&1
[[ ! -f $T/watch/maintenance-2 ]] && pass || fail "watch: Wartungsmarker entfernt, sobald der Server laeuft"
rm -f "$T/state/beammp-2.service.active"           # Absturz
out=$("$TOOL" watch 2>&1)
contains "$out" "🔴 Server 2 .* ist ausgefallen" "watch: Absturz nach Wartung wird gemeldet"
touch "$T/state/beammp-2.service.active"
"$TOOL" watch >/dev/null 2>&1

# (7) watch test meldet einen fehlgeschlagenen Versand.
sed -i 's|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc|' "$T/beamnet.conf"
touch "$T/curl.fail"
out=$("$TOOL" watch test 2>&1); rc=$?
lacks "$out" "Testnachricht gesendet" "watch test: kein falsches Erfolgsmeldung"
contains "$out" "Discord-Meldung fehlgeschlagen" "watch test: Fehler gemeldet"
[[ $rc -ne 0 ]] && pass || fail "watch test: Fehlercode"
rm -f "$T/curl.fail"
out=$("$TOOL" watch test 2>&1)
contains "$out" "Testnachricht gesendet" "watch test: Erfolg"

# (10) unban mit leerer/kaputter bans.json: verstaendliche Meldung statt Python-Fehler.
: >"$T/root/shared/beamnet/bans.json"
out=$("$TOOL" unban max 2>&1)
contains "$out" "bans.json ist fehlerhaft" "unban: kaputte Datei"
lacks "$out" "Traceback" "unban: kein Python-Fehler"
rm -f "$T/root/shared/beamnet/bans.json"

# (13) admin legt den gemeinsamen Ordner mit Rechten fuer den Dienst-Benutzer an.
rm -rf "$T/root/shared/beamnet"
: >"$T/actions"
"$TOOL" admin add Sebi >/dev/null 2>&1
contains "$(cat "$T/actions")" "chown -hR $ME:$ME $T/root/shared/beamnet" "admin: Ordner bekommt den Dienst-Benutzer"
[[ -d $T/root/shared/beamnet/players ]] && pass || fail "admin: Unterordner angelegt"

# (14) Sicherung im laufenden Betrieb: tar-Code 1 (Datei geaendert) ist kein Fehler.
cat >"$T/bin/tar" <<'EOF'
#!/usr/bin/env bash
/usr/bin/tar "$@"; [[ -f $FAKE/tar.warn ]] && exit 1; exit 0
EOF
chmod +x "$T/bin/tar"
touch "$T/tar.warn"
out=$("$TOOL" backup 2>&1)
contains "$out" "Gesichert:" "backup: tar-Warnung ist kein Fehler"
rm -f "$T/tar.warn" "$T/bin/tar"

# (8) Assistent: Komma-getrennte Namen und ein fehlschlagender Schritt beenden ihn nicht.
cat >"$T/bin/tar" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$T/bin/tar"
out=$(printf 'j\n\n\nMax, Moritz\n\n\n\n' | "$TOOL" setup 2>&1)
contains "$out" "Sicherung fehlgeschlagen" "setup: Fehler in einem Schritt wird gezeigt"
contains "$out" "Dieser Schritt hat nicht geklappt – es geht mit dem nächsten weiter" "setup: geht nach Fehler weiter"
contains "$("$TOOL" admin list)" "Max, Moritz" "setup: Komma-getrennte Admins"
contains "$out" "Zum Teilen mit mir" "setup: läuft bis zum Ende"
rm -f "$T/bin/tar"

# --- Versionen und Update -----------------------------------------------------------------------------------------
now=$(date +%s)
"$TOOL" install-core -y >/dev/null 2>&1
for nr in 1 2 3; do
    port=$((30813 + nr)); ver="1.7"; [[ $nr == 3 ]] && ver="1.6"
    echo "{\"port\":$port,\"players\":0,\"max\":8,\"updated\":$now,\"version\":\"$ver\",\"api\":{\"positions\":true}}" \
        >"$T/root/shared/beamnet/servers/$port.json"
done
out=$("$TOOL" doctor 2>&1)
contains "$out" "Server 1 .*BeamNetCore 1\\.7 aktiv" "doctor: Plugin-Version"
contains "$out" "Unterschiedliche BeamNetCore-Versionen auf den Servern: 1\\.6 1\\.7" "doctor: unterschiedliche Versionen"
# Update aus einer Kopie des Werkzeugs, Quelle per file:// (kein Netz noetig, echtes curl).
mv "$T/bin/curl" "$T/curl.stub"
# Eine leere Datei (z. B. abgebrochener Download) darf das Werkzeug nie ersetzen.
mkdir -p "$T/inst" "$T/leer"
: >"$T/leer/beamnet.sh"
cp "$TOOL" "$T/inst/beamnet"
out=$(BEAMNET_RAW="file://$T/leer" "$T/inst/beamnet" self-update 2>&1)
contains "$out" "kein BeamNet-Werkzeug" "self-update: leere Datei abgelehnt"
cmp -s "$T/inst/beamnet" "$TOOL" && pass || fail "self-update: Werkzeug unveraendert nach Fehler"
# Ersetzen scheitert (z. B. Platte voll): Fehler melden, alte Version und keine Reste.
printf '#!/bin/bash\nexit 1\n' >"$T/bin/install"; chmod +x "$T/bin/install"
cp "$TOOL" "$T/inst/beamnet"
out=$(BEAMNET_RAW="file://$HERE/.." "$T/inst/beamnet" self-update 2>&1); rc=$?
contains "$out" "konnte nicht ersetzt werden" "self-update: Fehler beim Ersetzen gemeldet"
lacks "$out" "Werkzeug aktualisiert" "self-update: kein falscher Erfolg"
[[ $rc -ne 0 && ! -e $T/inst/beamnet.new ]] && pass || fail "self-update: Fehlercode und keine Reste"
cmp -s "$T/inst/beamnet" "$TOOL" && pass || fail "self-update: alte Version bleibt"
rm -f "$T/bin/install"
# update laedt das Plugin immer neu – auch wenn neben dem Werkzeug eine alte Kopie liegt.
mkdir -p "$T/inst/server/BeamNetCore"
echo "-- BeamNetCore alt" >"$T/inst/server/BeamNetCore/main.lua"
rm -f "$T"/root/*/Resources/Server/BeamNetCore/main.lua
out=$(BEAMNET_RAW="file://$HERE/.." "$T/inst/beamnet" update -y 2>&1)
contains "$out" "Werkzeug aktualisiert: $T/inst/beamnet" "update: Werkzeug"
contains "$out" "Server 6: BeamNetCore installiert" "update: Plugin auf allen Servern"
[[ -x $T/inst/beamnet && ! -e $T/inst/beamnet.new ]] && pass || fail "update: Werkzeug ersetzt, keine Reste"
cmp -s "$T/root/1/Resources/Server/BeamNetCore/main.lua" "$HERE/../server/BeamNetCore/main.lua" && pass || fail "update: Plugin ist die neue Version"
out=$(BEAMNET_RAW="file:///gibt/es/nicht" "$T/inst/beamnet" update -y 2>&1)
contains "$out" "Download fehlgeschlagen" "update: Fehler beim Laden"
mv "$T/curl.stub" "$T/bin/curl"

# --- Tageszusammenfassung (watch_daily) ---------------------------------------------------------------------------
contains "$(cat "$T/beamnet.conf")" "^DAILY_SUMMARY=1$" "watch install: Tageszusammenfassung standardmaessig an"
contains "$(cat "$T/beamnet.conf")" "^DAILY_HOUR=22$" "watch install: Tageszusammenfassung ab 22 Uhr"
cp "$T/beamnet.conf" "$T/conf.keep"
P="$T/root/shared/beamnet/players"
mkdir -p "$P" "$T/root/shared/beamnet/races"
mv "$P" "$T/players.keep"; mkdir -p "$P"
today=$(( $(date +%s) / 86400 )); todaydate=$(date +%Y-%m-%d)
rm -f "$T/watch/daily-$todaydate"
sed -i '/^DAILY_/d; s|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc|' "$T/beamnet.conf"
echo "{\"name\":\"Sebi\",\"day\":$today,\"dayKm\":40.2}" >"$P/1.json"
echo "{\"name\":\"Max\",\"day\":$today,\"dayKm\":30}" >"$P/2.json"
echo "{\"name\":\"Ana\",\"day\":$today,\"dayKm\":12}" >"$P/3.json"
echo "{\"name\":\"Bo\",\"day\":$today,\"dayKm\":5.5}" >"$P/4.json"
echo "{\"name\":\"Gestern\",\"day\":$(( today - 1 )),\"dayKm\":99}" >"$P/5.json"
echo "{\"name\":\"Null\",\"day\":$today,\"dayKm\":0}" >"$P/6.json"
echo "kaputt" >"$P/7.json"
echo "{\"name\":\"Fremd\",\"day\":$today,\"dayKm\":500}" >"$T/fremd.json"
ln -s "$T/fremd.json" "$P/8.json"
now=$(date +%s)
echo "{\"tracks\":{\"A\":{\"records\":[{\"name\":\"Sebi\",\"time\":61.2,\"at\":$now}]},\"B\":{\"records\":[{\"name\":\"Max\",\"time\":50,\"at\":$now},{\"name\":\"Ana\",\"time\":55,\"at\":$now}]},\"C\":{\"records\":[{\"name\":\"Alt\",\"time\":40,\"at\":$(( now - 3 * 86400 ))}]},\"D\":{\"records\":[]}}}" \
    >"$T/root/shared/beamnet/races/italy.json"
: >"$T/curl.log"
out=$(BEAMNET_HOUR=21 "$TOOL" watch 2>&1)
lacks "$out" "Heute im Netzwerk" "daily: nicht vor 22 Uhr"
[[ ! -f $T/watch/daily-$todaydate ]] && pass || fail "daily: vor der Uhrzeit nicht als erledigt markiert"
out=$(BEAMNET_HOUR=22 "$TOOL" watch 2>&1)
contains "$out" "📊 Heute im Netzwerk: 87\\.7 km von 4 Fahrern · Top: 1\\. Sebi \\(40\\.2 km\\) · 2\\. Max \\(30\\.0 km\\) · 3\\. Ana \\(12\\.0 km\\) · 2 neue Streckenrekorde" "daily: Zusammenfassung"
lacks "$out" "Gestern|Fremd|Bo \\(" "daily: nur heute, kein Symlink, nur Top 3"
contains "$(cat "$T/curl.log")" "Heute im Netzwerk" "daily: an Discord"
[[ -f $T/watch/daily-$todaydate ]] && pass || fail "daily: als erledigt markiert"
: >"$T/curl.log"
out=$(BEAMNET_HOUR=23 "$TOOL" watch 2>&1)
lacks "$out" "Heute im Netzwerk" "daily: nur einmal am Tag"
# Eigene Uhrzeit, Einzahl und ein Rekord.
rm -f "$T/watch/daily-$todaydate" "$P"/[2-4].json
echo "{\"tracks\":{\"A\":{\"records\":[{\"name\":\"Sebi\",\"time\":61.2,\"at\":$now}]}}}" >"$T/root/shared/beamnet/races/italy.json"
echo "DAILY_HOUR=8" >>"$T/beamnet.conf"
out=$(BEAMNET_HOUR=09 "$TOOL" watch 2>&1)
contains "$out" "📊 Heute im Netzwerk: 40\\.2 km von 1 Fahrer · Top: 1\\. Sebi \\(40\\.2 km\\) · 1 neuer Streckenrekord$" "daily: DAILY_HOUR, Einzahl"
contains "$("$TOOL" watch status 2>&1)" "Tageszusammenfassung: an \\(täglich ab 8 Uhr\\)" "watch status: Tageszusammenfassung"
# Niemand gefahren: keine Meldung.
rm -f "$T/watch/daily-$todaydate" "$P"/1.json
: >"$T/curl.log"
out=$(BEAMNET_HOUR=22 "$TOOL" watch 2>&1)
lacks "$out" "Heute im Netzwerk" "daily: ohne Fahrer keine Meldung"
[[ ! -s $T/curl.log ]] && pass || fail "daily: ohne Fahrer nichts an Discord"
# DAILY_SUMMARY=0 schaltet ab.
rm -f "$T/watch/daily-$todaydate"
echo "{\"name\":\"Sebi\",\"day\":$today,\"dayKm\":40.2}" >"$P/1.json"
echo "DAILY_SUMMARY=0" >>"$T/beamnet.conf"
out=$(BEAMNET_HOUR=22 "$TOOL" watch 2>&1)
lacks "$out" "Heute im Netzwerk" "daily: DAILY_SUMMARY=0 schaltet ab"
contains "$("$TOOL" watch status 2>&1)" "Tageszusammenfassung: aus" "watch status: Tageszusammenfassung aus"
# Ohne Webhook: nichts.
sed -i '/^DAILY_SUMMARY=/d; s|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=|' "$T/beamnet.conf"
out=$(BEAMNET_HOUR=22 "$TOOL" watch 2>&1)
lacks "$out" "Heute im Netzwerk" "daily: ohne Webhook keine Zusammenfassung"
rm -rf "$P" "$T/fremd.json" "$T/root/shared/beamnet/races/italy.json" "$T/watch/daily-$todaydate"
mv "$T/players.keep" "$P"
mv "$T/conf.keep" "$T/beamnet.conf"

# --- Sicherheit: root folgt nie Symlinks in Ordnern, die dem Dienst-Benutzer gehoeren ------------------------------
S="$T/root/shared/beamnet"
victim="$T/victim"
mkdir -p "$victim/dir"
echo "geheim" >"$victim/passwd"; chmod 600 "$victim/passwd"
echo '{"bleibt":1}' >"$victim/dir/keep.json"; chmod 700 "$victim/dir"
unchanged() { [[ $(cat "$victim/passwd") == geheim && $(stat -c %a "$victim/passwd") == 600 ]]; }
# ServerConfig.toml als Symlink auf eine fremde Datei mit Map-Zeile: set-map schreibt nicht hindurch.
printf 'root:x:0:0\nMap = "/levels/x/info.json"\n' >"$victim/system.conf"; chmod 600 "$victim/system.conf"
mv "$T/root/6/ServerConfig.toml" "$T/cfg6.keep"
ln -s "$victim/system.conf" "$T/root/6/ServerConfig.toml"
"$TOOL" set-map 6 utah -y >/dev/null 2>&1
contains "$(cat "$victim/system.conf")" "levels/x/" "Sicherheit: set-map folgt keinem Symlink"
rm -f "$T/root/6/ServerConfig.toml"; mv "$T/cfg6.keep" "$T/root/6/ServerConfig.toml"
# Lebenszeichen: watch.json als Symlink.
ln -sf "$victim/passwd" "$S/watch.json"
ln -sf "$victim/passwd" "$S/.watch.json.tmp"      # feste Zwischendatei der Version 1.11–1.16
"$TOOL" watch >/dev/null 2>&1
unchanged && pass || fail "Sicherheit: Lebenszeichen folgt keinem Symlink"
[[ -f $S/watch.json && ! -L $S/watch.json ]] && pass || fail "Sicherheit: Lebenszeichen ersetzt den Symlink"
# votes/ als Symlink auf einen fremden Ordner: dort wird nichts geloescht.
rm -rf "$S/votes"; ln -s "$victim/dir" "$S/votes"
"$TOOL" watch >/dev/null 2>&1
[[ -f $victim/dir/keep.json ]] && pass || fail "Sicherheit: votes-Symlink – nichts gelöscht"
rm -f "$S/votes"; mkdir -p "$S/votes"
# Auftrag als Symlink auf eine fremde Datei.
ln -s "$victim/passwd" "$S/votes/30818.json"
"$TOOL" watch >/dev/null 2>&1
unchanged && pass || fail "Sicherheit: Auftrags-Symlink wird nicht gelesen oder verändert"
# install-core: main.lua als Symlink.
rm -f "$T/root/2/Resources/Server/BeamNetCore/main.lua"
ln -s "$victim/passwd" "$T/root/2/Resources/Server/BeamNetCore/main.lua"
"$TOOL" install-core -y >/dev/null 2>&1
unchanged && pass || fail "Sicherheit: install-core folgt keinem Symlink"
[[ -f $T/root/2/Resources/Server/BeamNetCore/main.lua && ! -L $T/root/2/Resources/Server/BeamNetCore/main.lua ]] && pass \
    || fail "Sicherheit: install-core ersetzt den Symlink durch das Plugin"
baks=("$T"/root/2/Resources/Server/BeamNetCore/*.bak*)
[[ ! -e ${baks[0]} ]] && pass || fail "Sicherheit: keine Plugin-Sicherung im Server-Ordner"
# Gemeinsamer Ordner: Unterordner als Symlink bekommt keine fremden Rechte.
rm -rf "$S/races"; ln -s "$victim/dir" "$S/races"
"$TOOL" admin add Sicherheit >/dev/null 2>&1
[[ $(stat -c %a "$victim/dir") == 700 ]] && pass || fail "Sicherheit: chmod folgt keinem Symlink"
[[ -d $S/races && ! -L $S/races ]] && pass || fail "Sicherheit: Symlink-Unterordner wird ersetzt"
"$TOOL" admin remove Sicherheit >/dev/null 2>&1
# config.json als Symlink: nicht hindurch schreiben.
mv "$S/config.json" "$T/config.keep" 2>/dev/null
ln -s "$victim/passwd" "$S/config.json"
"$TOOL" admin add Sicherheit >/dev/null 2>&1
unchanged && pass || fail "Sicherheit: admin folgt keinem Symlink"
rm -f "$S/config.json"; mv "$T/config.keep" "$S/config.json" 2>/dev/null
# Rotation: doppelte Maps und "all" werden abgelehnt.
contains "$("$TOOL" rotation 5 italy utah italy 2>&1)" "Jede Map nur einmal" "rotation: doppelte Maps abgelehnt"
contains "$("$TOOL" rotation all italy utah 2>&1)" "eine Server-Nummer" "rotation: nur eine Server-Nummer"

# Nicht als root: Aenderungen verweigert.
out=$(FAKE_UID=1000 "$TOOL" restart all 2>&1)
contains "$out" "Bitte als root" "restart verlangt root"

printf '\n%d Prüfungen bestanden, %d fehlgeschlagen\n' "$PASSES" "$FAILS"
[[ $FAILS -eq 0 ]]
