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
if [[ $cmd == show ]]; then
    unit=${*: -1}
    case "$*" in
        *CPUUsageNSec*) cat "$S/$unit.cpu" 2>/dev/null || echo "[not set]" ;;
        *MemoryCurrent*) cat "$S/$unit.mem" 2>/dev/null || echo "[not set]" ;;
        *) cat "$S/$unit.pid" 2>/dev/null || echo 0 ;;
    esac
    exit 0
fi
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
REAL_TIMEOUT=$(command -v timeout)     # die Attrappe unten ersetzt timeout fuer den Waechter
cat >"$T/bin/timeout" <<EOF
#!/usr/bin/env bash
# Port-Pruefung des Waechters (timeout <s> bash -c ...): "offen", ausser \$FAKE/portdown existiert. Alles andere
# (z. B. cfg: timeout 5 head ...) laeuft ueber das echte timeout.
if [[ \${2:-} == bash ]]; then
    [[ -f \$FAKE/portdown ]] && exit 1
    exit 0
fi
exec "$REAL_TIMEOUT" "\$@"
EOF
chmod +x "$T/bin/timeout"
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
export BEAMNET_CANARY=0          # Update zuerst auf einem Testserver: eigener Test weiter unten
export BEAMNET_TRUST_LINK_UID=-1   # die Tests laufen als root: alle Symlinks gehoeren root – keinem vertrauen
export BEAMNET_LOGROTATE="$T/logrotate.d/beamnet"
mkdir -p "$T/logrotate.d"
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

# Protokolle: sehr grosse Server.log und fehlende Rotation meldet doctor, fix richtet sie ein.
truncate -s 300M "$T/root/3/Server.log"
out=$("$TOOL" doctor 2>&1)
contains "$out" "Sehr große Server-Protokolle: Server 3: 300 MB" "Doctor: grosses Protokoll"
contains "$out" "Keine Protokoll-Rotation für Server.log" "Doctor: Rotation fehlt"
truncate -s 0 "$T/root/3/Server.log"
# fix mit -y: Rechte, Rotation, Autostart, Start. Server 6 wird von OpenClaw sofort wieder gestoppt (Sabotage).
touch "$T/state/beammp-6.service.sabotage"
: >"$T/actions"
out=$("$TOOL" fix -y)
contains "$out" "Protokoll-Rotation eingerichtet" "Fix richtet Protokoll-Rotation ein"
contains "$(cat "$BEAMNET_LOGROTATE")" "^$T/root/\\*/Server.log \\{$" "Rotation: alle Server-Protokolle"
contains "$(cat "$BEAMNET_LOGROTATE")" "^    su $ME $ME$" "Rotation: als Dienst-Benutzer (Ordner gehoeren ihm)"
contains "$(cat "$BEAMNET_LOGROTATE")" "^    copytruncate$" "Rotation: Server schreibt weiter (copytruncate)"
contains "$("$TOOL" doctor 2>&1)" "Protokoll-Rotation eingerichtet" "Doctor: Rotation erkannt"
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
# Befehlszeile (fuer andere Benutzer sichtbar) getrennt merken; -K-Dateien (Adresse mit Geheimnis) mit ins Protokoll.
echo "$*" >>"$FAKE/curl.argv"
line="$*"
while (( $# )); do
    if [[ $1 == -K ]]; then line+=" $(cat "$2")"; shift; fi
    shift
done
echo "$line" >>"$FAKE/curl.log"
[[ -f $FAKE/curl.fail ]] && exit 22
[[ $line == *getUpdates* && -f $FAKE/tg-updates.json ]] && cat "$FAKE/tg-updates.json"
[[ $line == *raw.githubusercontent.com*/beamnet.sh* && -f $FAKE/raw-latest.sh ]] && cat "$FAKE/raw-latest.sh"
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
contains "$(cat "$T/systemd/beamnet-watch.service")" "^TimeoutStartSec=300$" "watch install: Zeitlimit (haengt nie fuer immer)"
contains "$(cat "$T/actions")" "enable --now" "watch install: Timer aktiviert"
contains "$(cat "$T/beamnet.conf")" "^AUTO_RESTART=0$" "watch install: Neustart standardmaessig aus"
contains "$(cat "$T/beamnet.conf")" "^MAP_VOTE=1$" "watch install: Map-Abstimmung standardmaessig an"
contains "$(cat "$T/beamnet.conf")" "^NETWORK_REPORT=10$" "watch install: Netzwerk-Uebersicht standardmaessig alle 10 Minuten"
sed -i 's/^NETWORK_REPORT=.*/NETWORK_REPORT=0/' "$T/beamnet.conf"   # eigener Test weiter unten

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
contains "$(cat "$T/curl.log")" '\{"content":"🟡 Server 3 \\\\\(italy\\\\\) automatisch neu gestartet\.","allowed_mentions":\{"parse":\[\]\},"flags":4\}' "watch: Discord-Nachricht als JSON (ohne @-Erwähnungen, Markdown maskiert, ohne Vorschau)"
contains "$(cat "$T/curl.log")" "https://discord.com/api/webhooks/1/abc" "watch: an den Webhook"
lacks "$(cat "$T/curl.argv")" "webhooks/1/abc" "watch: Webhook-Adresse nie auf der Befehlszeile (ps)"

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
inweek=$(( ( $(date +%s) - 7 * 86400 + 3600 ) / 3600 * 3600 ))   # eine Stunde nach "vor 7 Tagen": in der Vorwoche
echo "{\"id\":\"1\",\"name\":\"Sebi\",\"week\":\"$lastweek\",\"weekKm\":42.5,\"weekJobs\":3,\"firstSeen\":$inweek}" >"$T/root/shared/beamnet/players/1.json"
echo "{\"id\":\"2\",\"name\":\"Max\",\"lastWeek\":\"$lastweek\",\"lastWeekKm\":12,\"lastWeekJobs\":2,\"firstSeen\":1}" >"$T/root/shared/beamnet/players/2.json"
echo "{\"id\":\"9\",\"name\":\"Fremd\",\"week\":\"$lastweek\",\"weekKm\":999}" >"$T/fremd-week.json"
ln -sf "$T/fremd-week.json" "$T/root/shared/beamnet/players/9.json"
mkdir -p "$T/watch"; echo "$inweek 23" >"$T/watch/hours"
cp "$T/root/shared/beamnet/teams.json" "$T/teams.keep" 2>/dev/null || true
echo '{"teams":{"blitz":{"name":"Blitz","members":{"1":true,"2":true}},"solo":{"name":"Solo","members":{"9":true}},"kaputt":5}}' >"$T/root/shared/beamnet/teams.json"
: >"$T/curl.log"
out=$(BEAMNET_DOW=1 "$TOOL" watch 2>&1)
contains "$out" "🏅 Team der Woche: Blitz \\(54 km, 2 Fahrer\\)$" "watch: Team der Woche"
# Mit Momentaufnahme des Plugins (teamweek-<Woche>.json): genau die, wie im Spiel angesagt.
echo "{\"week\":\"$lastweek\",\"name\":\"Sturm\",\"km\":77.5,\"members\":{\"5\":true,\"6\":true,\"7\":true}}" >"$T/root/shared/beamnet/teamweek-$lastweek.json"
rm -f "$T/watch/weekly-$lastweek"
out=$(BEAMNET_DOW=1 "$TOOL" watch 2>&1)
contains "$out" "🏅 Team der Woche: Sturm \\(78 km, 3 Fahrer\\)$" "watch: Team der Woche aus der Momentaufnahme"
rm -f "$T/root/shared/beamnet/teamweek-$lastweek.json"
if [[ -f $T/teams.keep ]]; then cp "$T/teams.keep" "$T/root/shared/beamnet/teams.json"; else rm -f "$T/root/shared/beamnet/teams.json"; fi
contains "$out" "🏁 Wochensieger .* KW .*: 1\\. Sebi \\(42\\.5 km\\) · 2\\. Max \\(12\\.0 km\\)" "watch: Wochensieger"
lacks "$out" "Fremd" "watch: Wochensieger folgt keinem Symlink"
contains "$out" "📈 Die Woche: 2 Fahrer · 54 km · Spitze 23 Spieler gleichzeitig \\([A-Z][a-z] [0-9]+ Uhr\\) · 1 neuer Fahrer · 5 Aufträge$" "watch: Wochenzahlen (Fahrer, km, Spitze, Neue, Aufträge)"
rm -f "$T/root/shared/beamnet/players/9.json" "$T/fremd-week.json"
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

# Spielerplaetze: Auslastung je Server und Map, mehr Plaetze fuer volle Server und beliebte Maps.
rm -f "$T/watch/usage-"* "$T/watch/slots-"*
status5 3
BEAMNET_HOUR=05 "$TOOL" watch >/dev/null 2>&1; status5 3
BEAMNET_HOUR=05 "$TOOL" watch >/dev/null 2>&1
contains "$(cat "$T/watch/usage-$(date +%Y-%m-%d)")" "^5 italy 3 6$" "slots: Auslastung je Minute (Spitze, Spielerminuten)"
rm -f "$T/watch/usage-"*
for d in 1 2 3 4 5; do
    f="$T/watch/usage-$(date -d "-$d days" +%Y-%m-%d)"
    echo "5 italy 8 300" >>"$f"
    if (( d <= 3 )); then
        { echo "2 west_coast_usa $([[ $d == 1 ]] && echo 8 || echo 3) 2000"; echo "4 east_coast_usa 2 1500"; echo "1 gridmap_v2 1 1200"; } >>"$f"
    fi
done
echo "6 my_mod_map 8 99999" >"$T/watch/usage-$(date -d "-40 days" +%Y-%m-%d)"
echo "kaputt" >>"$T/watch/usage-$(date -d "-1 days" +%Y-%m-%d)"
out=$("$TOOL" slots 2>&1)
contains "$out" "^  5 +italy +8 +8 +5 .*→ 12 \(5× voll in 30 Tagen\)" "slots: oft voll – mehr Plätze"
contains "$out" "^  2 +west_coast_usa +8 +8 +1 .*→ 12 \(beliebte Map \(Platz 1\)\)" "slots: beliebte Map und einmal voll – mehr Plätze"
contains "$out" "^  4 +east_coast_usa +8 +2 +0 .*bleibt" "slots: nie voll – bleibt"
contains "$out" "^  6 +my_mod_map +8 +0 +0 .*bleibt" "slots: alte Daten (über 30 Tage) zählen nicht"
sed -i 's/^SLOTS_MAX=.*/SLOTS_MAX=10/' "$T/beamnet.conf"
contains "$("$TOOL" slots 2>&1)" "^  5 +italy .*→ 10 " "slots: Obergrenze SLOTS_MAX"
sed -i 's/^SLOTS_MAX=.*/SLOTS_MAX=20/' "$T/beamnet.conf"
# Automatisch: nicht vor SLOTS_HOUR, nicht solange jemand faehrt, dann einmal am Tag.
: >"$T/actions"; status5 0
BEAMNET_HOUR=05 "$TOOL" watch >/dev/null 2>&1
lacks "$(cat "$T/actions")" "restart beammp-5" "slots: nicht vor der Uhrzeit"
status5 2
BEAMNET_HOUR=07 "$TOOL" watch >/dev/null 2>&1
lacks "$(cat "$T/actions")" "restart beammp-5" "slots: nicht, solange jemand fährt"
status5 0
out=$(BEAMNET_HOUR=07 "$TOOL" watch 2>&1)
contains "$out" "📈 Server 5 \(italy\): mehr Platz – jetzt 12 statt 8 Spieler \(5× voll in 30 Tagen\)" "slots: automatisch erhöht, sobald leer"
contains "$(cat "$T/root/5/ServerConfig.toml")" "^MaxPlayers = 12$" "slots: MaxPlayers in der Konfiguration"
contains "$(cat "$T/root/5/ServerConfig.toml")" '^Map = "/levels/italy/info.json"$' "slots: übrige Konfiguration unverändert"
: >"$T/actions"; status5 0
BEAMNET_HOUR=08 "$TOOL" watch >/dev/null 2>&1
lacks "$(cat "$T/actions")" "restart beammp-5" "slots: nur einmal am Tag"
# Von Hand setzen und pruefen.
contains "$("$TOOL" slots 5 99 2>&1)" "Plätze: 2 bis 64" "slots: Grenzen beim Setzen"
contains "$("$TOOL" slots 5 abc 2>&1)" "Aufruf: beamnet slots <nr> <plätze>" "slots: nur Zahlen"
contains "$("$TOOL" slots 5 010 2>&1)" "Aufruf: beamnet slots <nr> <plätze>" "slots: keine führende Null (wäre ungültiges TOML)"
"$TOOL" slots 5 8 >/dev/null 2>&1 </dev/null
contains "$(cat "$T/root/5/ServerConfig.toml")" "^MaxPlayers = 8$" "slots: von Hand gesetzt"
# Von Hand gesetzt: die Automatik macht das 30 Tage lang nicht rueckgaengig.
contains "$("$TOOL" slots 2>&1)" "Server 5: von Hand auf 8 gesetzt – Automatik 30 Tage aus" "slots: von Hand gesetzt angezeigt"
rm -f "$T/watch/slots-"[0-9]*; : >"$T/actions"; status5 0
BEAMNET_HOUR=07 "$TOOL" watch >/dev/null 2>&1
lacks "$(cat "$T/actions")" "restart beammp-5" "slots: von Hand gesenkt bleibt"
"$TOOL" slots 5 auto >/dev/null 2>&1
[[ ! -f $T/watch/slots-manual-5 ]] && pass || fail "slots: <nr> auto schaltet die Automatik wieder ein"
# Map-Rotation und Plaetze am selben Morgen: nur ein Neustart in diesem Lauf.
"$TOOL" rotation 5 italy utah >/dev/null 2>&1
rm -f "$T/watch/slots-"[0-9]* "$T/watch/rotate-5"; : >"$T/actions"; status5 0
BEAMNET_HOUR=07 "$TOOL" watch >/dev/null 2>&1
[[ $(grep -c "restart beammp-5" "$T/actions") == 1 ]] && pass || fail "slots: kein zweiter Neustart direkt nach der Map-Rotation"
"$TOOL" rotation 5 aus >/dev/null 2>&1
"$TOOL" slots 5 8 >/dev/null 2>&1 </dev/null
sed -i 's/^AUTO_SLOTS=.*/AUTO_SLOTS=0/' "$T/beamnet.conf"
rm -f "$T/watch/slots-"*; : >"$T/actions"; status5 0
BEAMNET_HOUR=07 "$TOOL" watch >/dev/null 2>&1
lacks "$(cat "$T/actions")" "restart beammp-5" "slots: AUTO_SLOTS=0 schaltet ab"
sed -i 's/^AUTO_SLOTS=.*/AUTO_SLOTS=1/' "$T/beamnet.conf"
rm -f "$T/watch/usage-"* "$T/watch/slots-"*

# doctor prueft das Lebenszeichen des Waechters.
"$TOOL" rotation 3 italy utah >/dev/null 2>&1
"$TOOL" watch >/dev/null 2>&1
out=$("$TOOL" doctor 2>&1)
contains "$out" "Wächter läuft \\(zuletzt vor [0-9]+ s\\)" "doctor: Wächter läuft"
contains "$out" "Ein Lauf des Wächters dauert [0-9]+ s$" "doctor: Dauer eines Waechter-Laufs"
echo 75 >"$T/watch/watch-seconds"
contains "$("$TOOL" doctor 2>&1)" "Ein Lauf des Wächters dauert 75 s \\(er läuft jede Minute\\)" "doctor: Warnung bei langem Waechter-Lauf"
contains "$out" "Server 3: tägliche Map-Rotation \\(italy utah\\)" "doctor: Rotation"
contains "$out" "XP-Abende aus" "doctor: Hinweis auf XP-Abende"
contains "$out" "beamnet event auto fr,sa 20:00 2 2h" "doctor: Befehl fuer XP-Abende"
"$TOOL" event auto sa 20:00 2 2h >/dev/null 2>&1
contains "$("$TOOL" doctor 2>&1)" "XP-Abende: sa 20:00 2 2h" "doctor: XP-Abende an"
"$TOOL" event auto aus >/dev/null 2>&1
if compgen -G "$T/root/*/Resources/Server/BeamNetCore/main.lua" >/dev/null; then
    contains "$out" "Keine Orte für Fahraufträge \\(/auftrag\\) auf: " "doctor: fehlende Orte für Aufträge"
    for m in $(for f in "$T"/root/*/Resources/Server/BeamNetCore/main.lua; do n=${f#"$T"/root/}; n=${n%%/*}; grep -m1 '^Map' "$T/root/$n/ServerConfig.toml" | sed -E 's#.*/levels/([^/]+)/.*#\1#'; done | sort -u); do
        mkdir -p "$T/root/shared/beamnet/places"
        echo '{"places":[{"type":"krankenhaus","name":"A","x":1,"y":1,"z":1}]}' >"$T/root/shared/beamnet/places/$m.json"
    done
    lacks "$("$TOOL" doctor 2>&1)" "Keine Orte für Fahraufträge" "doctor: mit Orten kein Hinweis"
    rm -rf "$T/root/shared/beamnet/places"
else
    pass; pass
fi
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
# Streckenseiten (mit einer Strecke mit unsicherem Namen, die weder verlinkt noch als Seite erzeugt wird).
echo '{"tracks":{"sprint":{"lengthM":1520,"records":[{"id":"1","name":"Sebi","time":49.0667,"at":1760000000}]},"leer":{"records":[]},"<b>x":{"records":[{"name":"Y","time":5}]}}}' >"$T/root/shared/beamnet/races/italy.json"
"$TOOL" web run >/dev/null 2>&1
page=$(cat "$T/web/index.html")
contains "$page" '<td><a href="t/italy/sprint.html">sprint</a></td>' "Statusseite: Strecke verlinkt"
lacks "$page" 'href="t/italy/&lt;' "Statusseite: unsichere Streckennamen nicht verlinkt"
track=$(cat "$T/web/t/italy/sprint.html" 2>/dev/null)
contains "$track" "<h1>sprint</h1>" "Streckenseite: erzeugt"
contains "$track" "Map Italy · Länge 1,5 km · 1 Fahrer mit Zeit" "Streckenseite: Map, Länge, Fahrer"
contains "$track" '<td class=n>1</td><td><a href="../../p/1.html">Sebi</a></td><td class=n>0:49\.1</td>' "Streckenseite: Bestenliste mit Profil-Link"
[[ -f $T/web/t/italy/leer.html && ! -e "$T/web/t/italy/<b>x.html" ]] && pass || fail "Streckenseite: auch ohne Zeiten, nie mit unsicherem Namen"
# Kaputte Orte-Datei (Typ als Liste) bricht die Statusseite nicht.
mkdir -p "$T/root/shared/beamnet/places"; echo '{"places":[{"type":["a"]},{"type":{"b":1}}]}' >"$T/root/shared/beamnet/places/x.json"
contains "$("$TOOL" web run 2>&1)" "Statusseite erzeugt" "Statusseite: fremde Typen in places/*.json brechen nichts"
rm -rf "$T/root/shared/beamnet/places"
# Unendliche/riesige XP in einer Spielerdatei und ein negativer levelBase brechen die Statusseite nicht.
echo '{"id":"955","name":"Unendlich","km":1,"xp":Infinity,"monthXp":1e999}' >"$T/root/shared/beamnet/players/955.json"
cp "$T/root/shared/beamnet/config.json" "$T/cfg955.keep" 2>/dev/null || true
echo '{"levelBase":-1}' >"$T/root/shared/beamnet/config.json"
contains "$("$TOOL" web run 2>&1)" "Statusseite erzeugt" "Statusseite: unendliche XP und negativer levelBase brechen nichts"
rm -f "$T/root/shared/beamnet/players/955.json"
if [[ -f $T/cfg955.keep ]]; then cp "$T/cfg955.keep" "$T/root/shared/beamnet/config.json"; else rm -f "$T/root/shared/beamnet/config.json"; fi
echo '{"tracks":{"sprint":{"records":[{"id":"1","name":"Sebi","time":49.0667}]},"leer":{"records":[]}},"series":{"tour":{"tracks":["sprint","leer"],"records":[{"id":"1","name":"Sebi","time":101.5}]},"bad":"x"}}' >"$T/root/shared/beamnet/races/italy.json"
out=$("$TOOL" web run 2>&1)
contains "$(cat "$T/web/index.html")" "<h2>Rennserien</h2>.*<td>Italy</td><td><b>tour</b><div class=small>sprint → leer</div></td><td>Sebi</td><td class=n>1:41\.5</td>" "Statusseite: Rennserien mit Bestzeit"
contains "$out" "Statusseite erzeugt" "web run"
page=$(cat "$T/web/index.html")
contains "$page" "<title>BeamNet – Status</title>" "Statusseite: Titel"
echo "{\"id\":\"9501\",\"name\":\"Frisch\",\"km\":1,\"firstSeen\":$(( $(date +%s) - 3600 ))}" >"$T/root/shared/beamnet/players/9501.json"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" " · 1 neuer Fahrer in 7 Tagen · Stand" "Statusseite: neue Fahrer der letzten 7 Tage"
rm -f "$T/root/shared/beamnet/players/9501.json"
contains "$page" "<td><b>BeamNet \\| Server 1</b><div class=small>Sebi, &lt;b&gt;Hacker&lt;/b&gt;</div></td><td>Grid Map</td><td class=n>2/8</td>" "Statusseite: Server"
lacks "$page" ">Alt<" "Statusseite: veraltete Server fehlen"
contains "$page" "1 Server online · 2 Spieler" "Statusseite: Zusammenfassung"
contains "$page" "<td class=n>1</td><td><a href=\"p/1.html\">Sebi</a></td><td class=n>8</td><td>Silber</td><td class=n>1500</td><td class=n>120 km</td><td class=n>0</td>" "Statusseite: Bestenliste"
contains "$page" "&lt;b&gt;Hacker&lt;/b&gt;" "Statusseite: Namen werden maskiert"
lacks "$page" "<b>Hacker</b>" "Statusseite: kein HTML aus Spielernamen"
# Schnellste Fahrer: Hoechstgeschwindigkeit, unplausible Werte (> 600 km/h) nicht.
echo '{"id":"61","name":"Raser","km":3,"topSpeedKmh":312.6}' >"$T/root/shared/beamnet/players/61.json"
echo '{"id":"62","name":"Cheater","km":3,"topSpeedKmh":9999}' >"$T/root/shared/beamnet/players/62.json"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" '<h2>Schnellste Fahrer</h2>.*<td><a href="p/61.html">Raser</a></td><td class=n>313 km/h</td>' "Statusseite: schnellste Fahrer"
lacks "$(cat "$T/web/index.html")" "9999 km/h" "Statusseite: unplausible Geschwindigkeit nicht gezeigt"
rm -f "$T/root/shared/beamnet/players/61.json" "$T/root/shared/beamnet/players/62.json"
# Meiste Auftraege und Wochenziel fuer alle.
wk=$(date -u +%G-W%V)
echo '{"id":"63","name":"Sanitaeter","km":3,"jobsDone":12,"convoyKm":21.5}' >"$T/root/shared/beamnet/players/63.json"
echo "{\"id\":\"64\",\"name\":\"Pendler\",\"km\":30,\"week\":\"$wk\",\"weekKm\":150}" >"$T/root/shared/beamnet/players/64.json"
echo "{\"week\":\"$wk\",\"goal\":600}" >"$T/root/shared/beamnet/community.json"
"$TOOL" web run >/dev/null 2>&1
page=$(cat "$T/web/index.html")
contains "$page" '<h2>Meiste Aufträge</h2>.*<td><a href="p/63.html">Sanitaeter</a></td><td class=n>12</td>' "Statusseite: meiste Aufträge"
contains "$page" '<h2>Meiste Konvoi-km</h2>.*<td><a href="p/63.html">Sanitaeter</a></td><td class=n>21.5 km</td>' "Statusseite: meiste Konvoi-km"
contains "$page" '<h2>Wochenziel für alle</h2><p>[0-9.]+ km von 600 km \([0-9]+ %\)</p><div class=bar><span style="width:[0-9]+%"></span></div>' "Statusseite: Wochenziel mit Balken"
echo '{"week":"2000-W01","goal":600}' >"$T/root/shared/beamnet/community.json"
"$TOOL" web run >/dev/null 2>&1
lacks "$(cat "$T/web/index.html")" "Wochenziel für alle" "Statusseite: altes Wochenziel nicht gezeigt"
rm -f "$T/root/shared/beamnet/players/63.json" "$T/root/shared/beamnet/players/64.json" "$T/root/shared/beamnet/community.json"
# Demnaechst: geplante Ansagen und laufendes XP-Event; Vergangenes und Unsinn nicht.
now=$(date +%s)
echo "{\"list\":[{\"id\":\"a\",\"text\":\"Gruppenrennen <b>heute</b>\",\"at\":$((now + 3600))},{\"id\":\"b\",\"text\":\"Alt\",\"at\":$((now - 60))},5]}" >"$T/root/shared/beamnet/announcements.json"
echo "{\"factor\":2,\"until\":$((now + 1800)),\"by\":\"Orga\"}" >"$T/root/shared/beamnet/event.json"
"$TOOL" web run >/dev/null 2>&1
page=$(cat "$T/web/index.html")
contains "$page" "<h2>Demnächst</h2>.*<td>jetzt</td><td>🎉 XP-Event läuft: 2-fache XP bis [0-9:]+ Uhr</td>.*📢 Gruppenrennen &lt;b&gt;heute&lt;/b&gt;" "Statusseite: Demnächst (Event, geplante Ansage, maskiert)"
lacks "$page" "📢 Alt" "Statusseite: vergangene Ansagen nicht unter Demnächst"
rm -f "$T/root/shared/beamnet/announcements.json" "$T/root/shared/beamnet/event.json" "$T/root/shared/beamnet/bonusmap.json"
"$TOOL" web run >/dev/null 2>&1
lacks "$(cat "$T/web/index.html")" "Demnächst" "Statusseite: ohne Termine kein Abschnitt Demnächst"
lacks "$(cat "$T/web/hilfe.html")" "Bonus-Map des Tages" "Hilfeseite: ohne Bonus-Map kein Eintrag"
# Bonus-Map des Tages unter Demnaechst und auf der Hilfeseite; abgelaufene nicht.
echo "{\"map\":\"utah\",\"factor\":1.5,\"until\":$((now + 3600)),\"day\":\"x\"}" >"$T/root/shared/beamnet/bonusmap.json"
echo italy >"$T/watch/bonusmap-$(date +%F)"
"$TOOL" web run >/dev/null 2>&1
lacks "$(cat "$T/web/index.html")" "Bonus-Map heute" "Statusseite: Bonus-Map nur, wenn der Waechter sie gewaehlt hat"
echo utah >"$T/watch/bonusmap-$(date +%F)"
echo "{\"name\":\"Utah-Server\",\"port\":30899,\"map\":\"utah\",\"players\":0,\"max\":8,\"names\":[],\"updated\":$now,\"challenge\":\"Erreiche heute 180 km/h\"}" >"$T/root/shared/beamnet/servers/30899.json"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" "<b>Utah-Server</b></td><td>Utah, USA <span class=small>⭐ Bonus-Map</span></td>" "Statusseite: Bonus-Map in der Servertabelle"
contains "$(cat "$T/web/index.html")" "<td>jetzt</td><td>✅ Tagesaufgabe: Erreiche heute 180 km/h" "Statusseite: Tagesaufgabe unter Demnächst"
echo "{\"name\":\"Utah-Server\",\"port\":30899,\"map\":\"utah\",\"players\":0,\"max\":8,\"names\":[],\"updated\":$now,\"challenge\":\"Fahre heute <b>15</b> km\"}" >"$T/root/shared/beamnet/servers/30899.json"
"$TOOL" web run >/dev/null 2>&1
lacks "$(cat "$T/web/index.html")" "Tagesaufgabe:" "Statusseite: nur Tagesaufgaben in bekannter Form"
rm -f "$T/root/shared/beamnet/servers/30899.json"
contains "$(cat "$T/web/index.html")" "<td>jetzt</td><td>🗺️ Bonus-Map heute: utah – \\+50 % XP beim Fahren bis Mitternacht</td>" "Statusseite: Bonus-Map unter Demnächst"
contains "$(cat "$T/web/hilfe.html")" "<li><b>Bonus-Map des Tages</b>" "Hilfeseite: Bonus-Map"
echo "{\"map\":\"utah\",\"factor\":1.5,\"until\":$((now - 60)),\"day\":\"x\"}" >"$T/root/shared/beamnet/bonusmap.json"
"$TOOL" web run >/dev/null 2>&1
lacks "$(cat "$T/web/index.html")" "Bonus-Map heute" "Statusseite: abgelaufene Bonus-Map nicht"
rm -f "$T/watch/bonusmap-$(date +%F)"
lacks "$(cat "$T/web/hilfe.html")" "Bonus-Map des Tages" "Hilfeseite: abgelaufene Bonus-Map nicht"
rm -f "$T/root/shared/beamnet/bonusmap.json"
# Orte fuer Auftraege je Map (kaputte Eintraege und unbekannte Typen ignoriert).
mkdir -p "$T/root/shared/beamnet/places"
echo '{"places":[{"type":"krankenhaus","name":"A","x":1,"y":1,"z":1},{"type":"schule","name":"B"},{"type":"krankenhaus","name":"C"},{"type":"<b>"},5]}' >"$T/root/shared/beamnet/places/italy.json"
echo 'kaputt' >"$T/root/shared/beamnet/places/utah.json"
"$TOOL" web run >/dev/null 2>&1
page=$(cat "$T/web/index.html")
contains "$page" "<h2>Orte für Aufträge</h2>.*<td>Italy</td><td>🚑 2 🚌 1</td><td class=n>3</td>" "Statusseite: Orte für Aufträge (unbekannte Typen und Unsinn nicht mitgezählt)"
rm -rf "$T/root/shared/beamnet/places"
"$TOOL" web run >/dev/null 2>&1
page=$(cat "$T/web/index.html")
# Kilometer je Woche auf der Profilseite (Verlauf + laufende Woche; kaputte Eintraege ignoriert).
cp "$T/root/shared/beamnet/players/1.json" "$T/p1.keep"
python3 - "$T/root/shared/beamnet/players/1.json" "$(date -u +%G-W%V)" <<'PY'
import json, sys
p, wk = sys.argv[1], sys.argv[2]
r = json.load(open(p))
r["weeks"] = [{"week": "2026-W40", "km": 12.5}, {"week": "<b>", "km": 99}, {"week": "2026-W41", "km": 30}]
r["week"], r["weekKm"] = wk, 7
import time
r["jobsDone"], r["streak"], r["streakDay"], r["bestStreak"] = 14, 3, int(time.time() // 86400), 9
r["convoyKm"] = 42.25
r["bonusMapKm"] = 31.5
json.dump(r, open(p, "w"))
PY
cp "$T/root/shared/beamnet/teams.json" "$T/teams-prof.keep" 2>/dev/null || true
echo '{"teams":{"a":{"name":"<i>Crew</i>","members":{"1":"Sebi"}}}}' >"$T/root/shared/beamnet/teams.json"
"$TOOL" web run >/dev/null 2>&1
prof=$(cat "$T/web/p/1.html")
contains "$prof" "<div>Auf Bonus-Maps<b>31[.,]5 km</b></div>" "Profilseite: Kilometer auf Bonus-Maps"
contains "$prof" "<div>Team<b>&lt;i&gt;Crew&lt;/i&gt;</b></div>" "Profilseite: Team (maskiert)"
if [[ -f $T/teams-prof.keep ]]; then cp "$T/teams-prof.keep" "$T/root/shared/beamnet/teams.json"; else rm -f "$T/root/shared/beamnet/teams.json"; fi
contains "$prof" "<div>Aufträge<b>14</b></div>" "Profilseite: Aufträge"
contains "$prof" "<div>Tages-Serie<b>3 Tage \\(beste: 9\\)</b></div>" "Profilseite: Tages-Serie"
contains "$prof" "<div>Im Konvoi<b>42[.,]2 km</b></div>" "Profilseite: Konvoi-Kilometer"
contains "$prof" "<h2>Kilometer je Woche</h2>" "Profilseite: Wochen-Diagramm"
contains "$prof" "<title>KW 40: 12.5 km</title>" "Profilseite: Woche mit Tooltip"
[[ $(grep -o "<rect " <<<"$prof" | wc -l) == 3 ]] && pass || fail "Profilseite: drei Wochen (kaputter Eintrag ignoriert)"
contains "$prof" "die letzte ist die laufende Woche" "Profilseite: laufende Woche beschriftet"
# Seit Wochen nicht gefahren: die zuletzt gefahrene Woche fehlt nicht, ist aber nicht "die laufende".
python3 - "$T/root/shared/beamnet/players/1.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r["week"], r["weekKm"] = "2026-W39", 4
json.dump(r, open(sys.argv[1], "w"))
PY
"$TOOL" web run >/dev/null 2>&1
prof=$(cat "$T/web/p/1.html")
contains "$prof" "<title>KW 39: 4.0 km</title>" "Profilseite: zuletzt gefahrene Woche im Diagramm"
lacks "$prof" "laufende Woche" "Profilseite: alte Woche nicht als laufend beschriftet"
mv "$T/p1.keep" "$T/root/shared/beamnet/players/1.json"
# Saison-Titel auf der Profilseite (Platz 1-3 der archivierten Saisons, neueste zuerst; kaputte Archive ignoriert).
mkdir -p "$T/root/shared/beamnet/seasons"
echo '{"month":"2026-08","top":[{"id":"1","name":"Sebi","xp":900}]}' >"$T/root/shared/beamnet/seasons/2026-08.json"
echo '{"month":"2026-09","top":[{"id":"x","name":"A","xp":9},{"id":"1","name":"Sebi","xp":5}]}' >"$T/root/shared/beamnet/seasons/2026-09.json"
echo '{"month":"<b>","top":[{"id":"1"}]}' >"$T/root/shared/beamnet/seasons/kaputt.json"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/p/1.html")" "<div class=tags><span>🥈 Saison-Zweiter September 2026</span><span>🥇 Saisonsieger August 2026</span></div>" "Profilseite: Saison-Titel"
lacks "$(cat "$T/web/p/1.html")" "&lt;b&gt;|Saison[^<]* <b>" "Profilseite: kaputtes Archiv ignoriert"
rm -rf "$T/root/shared/beamnet/seasons"
"$TOOL" web run >/dev/null 2>&1
page=$(cat "$T/web/index.html")
# Strecke der Woche (vom Plugin in weekly-track.json gewaehlt); eine alte Woche wird nicht gezeigt.
echo "{\"week\":\"$(date -u +%G-W%V)\",\"map\":\"italy\",\"name\":\"<i>bergauf</i>\",\"xp\":50}" >"$T/root/shared/beamnet/weekly-track.json"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" "⭐ Strecke der Woche: <b>&lt;i&gt;bergauf&lt;/i&gt;</b> auf Italy – 50 Bonus-XP" "Statusseite: Strecke der Woche (maskiert)"
echo '{"week":"2000-W01","map":"italy","name":"alt","xp":50}' >"$T/root/shared/beamnet/weekly-track.json"
"$TOOL" web run >/dev/null 2>&1
lacks "$(cat "$T/web/index.html")" "Strecke der Woche" "Statusseite: alte Strecke der Woche nicht gezeigt"
rm -f "$T/root/shared/beamnet/weekly-track.json"
"$TOOL" web run >/dev/null 2>&1
# Teams: Kilometer der Mitglieder, maskierte Namen.
echo '{"teams":{"a":{"name":"<b>Crew</b>","members":{"1":"Sebi","999":"Weg"}}}}' >"$T/root/shared/beamnet/teams.json"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" '<h2>Teams</h2>.*<td class=n>1</td><td>&lt;b&gt;Crew&lt;/b&gt;</td><td class=n>2</td><td class=n>[0-9.]+ km</td><td class=n>[0-9.]+ km</td>' "Statusseite: Teams (mit Kilometern dieser Woche)"
rm -f "$T/root/shared/beamnet/teams.json"
"$TOOL" web run >/dev/null 2>&1
# Kennzahlen fuer Prometheus/Grafana.
m=$(cat "$T/web/metrics.txt")
contains "$m" '^beamnet_players\{port="30814",map="gridmap_v2"\} 2$' "metrics: Spieler je Server"
contains "$m" '^beamnet_players_max\{port="30814"\} 8$' "metrics: Plaetze je Server"
contains "$m" '^beamnet_players_online 2$' "metrics: Spieler gesamt"
contains "$m" '^beamnet_drivers_registered [0-9]+$' "metrics: Fahrer"
contains "$m" '^# TYPE beamnet_km_total counter$' "metrics: Prometheus-Format"
# Hilfeseite: Befehle, Regeln (eigene aus config.json, maskiert), Ligen, Erfolge; verlinkt von der Statusseite.
contains "$page" '<a href="hilfe.html">Hilfe, Befehle &amp; Regeln</a>' "Hilfeseite: verlinkt"
help=$(cat "$T/web/hilfe.html")
contains "$help" "<b>/wo &lt;Name&gt;</b>" "Hilfeseite: Chat-Befehle"
contains "$help" "<li>Fair fahren: kein absichtliches Rammen oder Blockieren.</li>" "Hilfeseite: Standardregeln"
contains "$help" "<td>Gold</td><td class=n>ab 2000 XP</td>" "Hilfeseite: Ligen"
contains "$help" "<span>Erste 10 km</span>" "Hilfeseite: Erfolge"
contains "$help" "10 XP je Kilometer und 1 XP je Minute" "Hilfeseite: XP-Regeln"
contains "$help" "<li><b>Aufträge</b> \\(/auftrag\\): 25 XP je km Luftlinie, ab 1 km \\+20" "Hilfeseite: Auftrags-XP"
contains "$help" "<li><b>Konvoi</b> \\(/konvoi\\): je 3 km zusammen mit anderen \\+20</li>" "Hilfeseite: Konvoi-XP"
contains "$help" "<li><b>Willkommen zurück</b>: nach 14 Tagen Pause einmal \\+50</li>" "Hilfeseite: Rueckkehrer-Bonus"
cp "$T/root/shared/beamnet/config.json" "$T/cfg.help" 2>/dev/null
echo '{"rules":["Kein <script>alert(1)</script>","Linksverkehr"],"xpPerKm":12,"convoyXp":0,"convoyKm":2.5,"comebackXp":75}' >"$T/root/shared/beamnet/config.json"
"$TOOL" web run >/dev/null 2>&1
help=$(cat "$T/web/hilfe.html")
contains "$help" "<li>Kein &lt;script&gt;alert\\(1\\)&lt;/script&gt;</li><li>Linksverkehr</li>" "Hilfeseite: eigene Regeln, maskiert"
lacks "$help" "<script>" "Hilfeseite: kein HTML aus der Konfiguration"
contains "$help" "12 XP je Kilometer" "Hilfeseite: XP aus config.json"
lacks "$help" "<b>Konvoi</b>" "Hilfeseite: ausgeschalteter Konvoi fehlt"
contains "$help" "einmal \\+75</li>" "Hilfeseite: Bonus-Werte aus config.json"
rm -f "$T/root/shared/beamnet/config.json"; [[ -f $T/cfg.help ]] && mv "$T/cfg.help" "$T/root/shared/beamnet/config.json"
"$TOOL" web run >/dev/null 2>&1
page=$(cat "$T/web/index.html")
# Mit IDs (BeamNetCore 1.14+): Namen mit Profilseite verlinkt, Gaeste/unsichere IDs/ohne Profil nicht.
cp "$T/root/shared/beamnet/servers/30814.json" "$T/server-ids.bak"
echo "{\"name\":\"BeamNet | Server 1\",\"port\":30814,\"map\":\"gridmap_v2\",\"players\":4,\"max\":8,\"names\":[\"Sebi\",\"<b>Hacker</b>\",\"Gast\",\"Neu\"],\"ids\":[\"1\",\"2\",\"\",\"777\"],\"updated\":$(date +%s)}" >"$T/root/shared/beamnet/servers/30814.json"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" '<div class=small><a href="p/1.html">Sebi</a>, <a href="p/2.html">&lt;b&gt;Hacker&lt;/b&gt;</a>, Gast, Neu</div>' "Statusseite: Online-Namen verlinken aufs Profil"
echo "{\"name\":\"BeamNet | Server 1\",\"port\":30814,\"map\":\"gridmap_v2\",\"players\":2,\"max\":8,\"names\":[\"Sebi\",\"X\"],\"ids\":[\"1\"],\"updated\":$(date +%s)}" >"$T/root/shared/beamnet/servers/30814.json"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" '<div class=small>Sebi, X</div>' "Statusseite: IDs mit falscher Laenge werden ignoriert"
cp "$T/server-ids.bak" "$T/root/shared/beamnet/servers/30814.json"
"$TOOL" web run >/dev/null 2>&1
page=$(cat "$T/web/index.html")
contains "$page" "<td class=n>1</td><td><a href=\"p/1.html\">Sebi</a></td><td class=n>33.3 km</td>" "Statusseite: Woche"
contains "$page" "<td>Italy</td><td><a href=\"t/italy/sprint.html\">sprint</a></td><td>Sebi</td><td class=n>0:49.1</td>" "Statusseite: Rekorde"
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
# ID mit Zeilenumbruch am Ende ("$" passt in Python auch davor): keine Seite, kein Link.
echo '{"id":"77\n","name":"Umbruch","km":1}' >"$T/root/shared/beamnet/players/77.json"
"$TOOL" web run >/dev/null 2>&1
[[ -z $(find "$T/web/p" -name '77*') ]] && pass || fail "Profilseite: ID mit Zeilenumbruch ohne Seite"
lacks "$(cat "$T/web/index.html")" "p/77" "Profilseite: kein Link fuer ID mit Zeilenumbruch"
rm -f "$T/root/shared/beamnet/players/77.json"
rm -f "$T/root/shared/beamnet/players/5.json"
contains "$page" "</html>" "Statusseite: vollstaendig"
echo "WEB_TITLE=Sebis Netz" >>"$T/beamnet.conf"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" "<title>Sebis Netz – Status</title>" "Statusseite: eigener Titel"
# api.json: dieselben Daten maschinenlesbar, ohne HTML-Maskierung und ohne IP-Adressen.
[[ -f $T/web/api.json ]] && pass || fail "api.json: wird erzeugt"
python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$T/web/api.json" 2>/dev/null && pass || fail "api.json: gueltiges JSON"
api=$(python3 -c '
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))
d = lambda v: json.dumps(v, ensure_ascii=False, sort_keys=True)
print("title", a["title"], "online", a["online"], "generated", type(a["generated"]).__name__)
print("top1", d(a["top"][0]))
print("server", d(a["servers"][0]))
print("week", d(a["week"]))
print("season", a["season"]["month"], a["season"]["title"], d(a["season"]["top"]))
print("record", d(a["records"]))
print("maps", d(a["popularMaps"]))
' "$T/web/api.json" 2>&1)
contains "$api" "^title Sebis Netz online 2 generated int$" "api.json: Titel, Spieler online, Zeitstempel"
contains "$api" '^top1 \{"id": "1", "km": 120.4, "league": "Silber", "level": 8, "name": "Sebi", "xp": 1500\}$' "api.json: Bestenliste"
contains "$api" '^server \{"map": "gridmap_v2", "mapName": "Grid Map", "max": 8, "name": "BeamNet \| Server 1", "names": \["Sebi", "<b>Hacker</b>"\], "players": 2, "port": 30814\}$' "api.json: Server (ohne HTML-Maskierung)"
contains "$api" '^week \[\{"id": "1", "km": 33.3, "name": "Sebi"\}\]$' "api.json: Woche"
contains "$api" "^season $(date -u +%Y-%m) [A-Za-zä]+ [0-9]{4} \\[\\{\"id\": \"1\", \"name\": \"Sebi\", \"xp\": 500\\}, \\{\"id\": \"4\", \"name\": \"Zaehler\", \"xp\": 321\\}\\]$" "api.json: Saison"
contains "$api" '^record \[\{"map": "italy", "mapName": "Italy", "name": "Sebi", "time": 49.067, "track": "sprint"\}\]$' "api.json: Rekorde"
contains "$api" '^maps \[\{"drivers": 1, "km": 30.5, "map": "italy", "mapName": "Italy"\}, \{"drivers": 1, "km": 9.5, "map": "utah", "mapName": "Utah, USA"\}\]$' "api.json: Beliebteste Maps"
contains "$(cat "$T/web/index.html")" "<footer>.*<a href=\"api.json\">api.json</a></footer>" "Statusseite: Link auf api.json"
# Unbekannte Felder (z. B. IP-Adressen) und unsichere IDs landen nie in api.json.
cp "$T/root/shared/beamnet/servers/30814.json" "$T/server-api.bak"
echo "{\"name\":\"S\",\"port\":30814,\"map\":\"italy\",\"players\":1,\"max\":8,\"ip\":\"203.0.113.7\",\"updated\":$(date +%s)}" >"$T/root/shared/beamnet/servers/30814.json"
echo "{\"id\":\"../böse\",\"name\":\"X\",\"km\":1,\"ip\":\"198.51.100.9\"}" >"$T/root/shared/beamnet/players/5.json"
"$TOOL" web run >/dev/null 2>&1
lacks "$(cat "$T/web/api.json")" "203\\.0\\.113\\.7|198\\.51\\.100\\.9" "api.json: keine IP-Adressen"
lacks "$(cat "$T/web/api.json")" "böse" "api.json: keine unsicheren IDs"
contains "$(cat "$T/web/api.json")" '"id": null' "api.json: unsichere ID wird null"
mv "$T/server-api.bak" "$T/root/shared/beamnet/servers/30814.json"
rm -f "$T/root/shared/beamnet/players/5.json"

: >"$T/actions"
out=$("$TOOL" web install 99 2>&1)
contains "$out" "Port muss zwischen 1024 und 65535" "web install: Port geprueft"
out=$("$TOOL" web install 8088 2>&1)
contains "$out" "Statusseite läuft auf Port 8088" "web install"
contains "$(cat "$T/systemd/beamnet-web.service")" "serve_forever\\(\\)' 0\\.0\\.0\\.0 8088 $T/web$" "web install: Webserver"
contains "$(cat "$T/systemd/beamnet-web.service")" "Access-Control-Allow-Origin" "web install: api.json fuer andere Seiten abrufbar"
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
answers='j\nj\nj\nj\nSebi Max\nj\nhttps://discord.com/api/webhooks/123/abc_DEF-9\n123456:ABCDEFghijklmnop_1234567890\n-1001234567890\n42, 43\nj\nj\nj\n8090\nj\n'
: >"$T/actions"
out=$(printf "$answers" | "$TOOL" setup 2>&1)
contains "$out" "Gesichert: $T/backups/" "setup: Sicherung"
[[ -f $T/root/1/Resources/Server/BeamNetCore/main.lua ]] && pass || fail "setup: Plugin installiert"
contains "$out" "Plugin XPSystem auf 6 Server\\(n\\) abgeschaltet" "setup: alte Plugins abgeschaltet"
contains "$("$TOOL" admin list)" "Admins: Sebi, Max" "setup: Admins"
contains "$(cat "$T/beamnet.conf")" "^DISCORD_WEBHOOK=https://discord.com/api/webhooks/123/abc_DEF-9$" "setup: Webhook"
contains "$(cat "$T/beamnet.conf")" "^AUTO_RESTART=1$" "setup: automatischer Neustart"
contains "$(cat "$T/beamnet.conf")" "^TELEGRAM_TOKEN=123456:ABCDEFghijklmnop_1234567890$" "setup: Telegram-Token"
contains "$(cat "$T/beamnet.conf")" "^TELEGRAM_CHAT=-1001234567890$" "setup: Telegram-Chat"
contains "$(cat "$T/beamnet.conf")" "^TELEGRAM_ADMINS=42,43$" "setup: Telegram-Admins"
contains "$(cat "$T/beamnet.conf")" "^AUTO_EVENT=fr,sa 20:00 2 2h$" "setup: XP-Abende eingeschaltet"
[[ $(grep -c '^DISCORD_WEBHOOK=' "$T/beamnet.conf") == 1 ]] && pass || fail "setup: Webhook nur einmal in der Datei"
contains "$(cat "$T/systemd/beamnet-web.service")" "' 0\\.0\\.0\\.0 8090 " "setup: Statusseite auf Port 8090"
contains "$(cat "$T/actions")" "restart beammp-6.service" "setup: Neustart"
contains "$out" "Zum Teilen mit mir: beamnet report" "setup: Abschluss"
# Ungueltiger Webhook wird nicht gespeichert.
out=$(printf '\n\n\n\nj\nhttp://evil.example/x\n\n\n\nj\nkeinport\n\n' | "$TOOL" setup 2>&1)
contains "$out" "keine Discord-Webhook-URL" "setup: falscher Webhook abgelehnt"
contains "$(cat "$T/beamnet.conf")" "^DISCORD_WEBHOOK=https://discord.com/api/webhooks/123/abc_DEF-9$" "setup: alter Webhook bleibt"
contains "$out" "Ungültiger Port 'keinport' – Statusseite übersprungen" "setup: ungueltiger Port bricht nicht ab"
contains "$out" "Zum Teilen mit mir" "setup laeuft nach ungueltigem Port bis zum Ende"
sed -i 's/^AUTO_EVENT=.*/AUTO_EVENT=/; s/^TELEGRAM_ADMINS=.*/TELEGRAM_ADMINS=/' "$T/beamnet.conf"   # fuer die spaeteren Tests
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
contains "$out" "BeamNetCore ist älter als [0-9.]+: Server [0-9]+ \\(1\\.[67]\\)" "doctor: veraltetes Plugin erkannt"
# Die Plugin-Version im Werkzeug gehoert zur Version in main.lua.
[[ $(grep -m1 -o '^CORE_VERSION="[0-9.]*"' "$TOOL" | cut -d'"' -f2) == $(grep -m1 -o 'BN.VERSION = "[0-9.]*"' "$HERE/../server/BeamNetCore/main.lua" | cut -d'"' -f2) ]] \
    && pass || fail "CORE_VERSION im Werkzeug passt zu BN.VERSION im Plugin"
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
cp -p "$T/root/shared/beamnet/races/italy.json" "$T/italy.keep" 2>/dev/null
mv "$P" "$T/players.keep"; mkdir -p "$P"
today=$(( $(date +%s) / 86400 )); todaydate=$(date +%Y-%m-%d)
rm -f "$T/watch/daily-$todaydate"
sed -i '/^DAILY_/d; s|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc|' "$T/beamnet.conf"
echo "{\"name\":\"Sebi\",\"day\":$today,\"dayKm\":40.2}" >"$P/1.json"
echo "{\"name\":\"Max\\n🔴 Server 1 ist ausgefallen\",\"day\":$today,\"dayKm\":30,\"dayJobs\":4}" >"$P/2.json"
echo "{\"name\":\"Ana\",\"day\":$today,\"dayKm\":12,\"dayJobs\":1,\"firstSeen\":$(date +%s)}" >"$P/3.json"
echo "{\"name\":\"Bo\",\"day\":$today,\"dayKm\":5.5}" >"$P/4.json"
echo "{\"name\":\"Gestern\",\"day\":$(( today - 1 )),\"dayKm\":99,\"dayJobs\":9,\"firstSeen\":$(( $(date +%s) - 3 * 86400 ))}" >"$P/5.json"
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
"$TOOL" event auto täglich 23:59 2 2h >/dev/null 2>&1
out=$(BEAMNET_HOUR=22 "$TOOL" watch 2>&1)
"$TOOL" event auto aus >/dev/null 2>&1
contains "$out" "   🎉 Nächster XP-Abend: (heute|Mo|Di|Mi|Do|Fr|Sa|So) 23:59–[0-9]{2}:[0-9]{2} Uhr \\(2-fache XP\\)" "daily: naechster XP-Abend in der Zusammenfassung"
# Ein vom Dienst untergeschobener XP-Abend (xpabend.json im gemeinsamen Ordner) erscheint nicht in den Meldungen.
echo "{\"next\":$(( now + 3600 )),\"factor\":5,\"sec\":3600}" >"$T/root/shared/beamnet/xpabend.json"
rm -f "$T/watch/daily-$todaydate"
out2=$(BEAMNET_HOUR=22 "$TOOL" watch 2>&1)
lacks "$out2" "5-fache XP" "daily: untergeschobener XP-Abend nicht gemeldet"
rm -f "$T/root/shared/beamnet/xpabend.json"
contains "$out" "📊 Heute im Netzwerk: 87\\.7 km von 4 Fahrern · Top: 1\\. Sebi \\(40\\.2 km\\) · 2\\. Max 🔴 Server 1 ist ausgefallen \\(30\\.0 km\\) · 3\\. Ana \\(12\\.0 km\\) · 2 neue Streckenrekorde · 5 Aufträge erledigt · 1 neuer Spieler 👋" "daily: Zusammenfassung (mit Aufträgen und neuen Spielern von heute)"
lacks "$out" "Gestern|Fremd|Bo \\(" "daily: nur heute, kein Symlink, nur Top 3"
lacks "$out" "^ *🔴" "daily: Zeilenumbruch im Namen erzeugt keine eigene Zeile"
contains "$(cat "$T/curl.log")" "Heute im Netzwerk" "daily: an Discord"
[[ -f $T/watch/daily-$todaydate ]] && pass || fail "daily: als erledigt markiert"
: >"$T/curl.log"
out=$(BEAMNET_HOUR=23 "$TOOL" watch 2>&1)
lacks "$out" "Heute im Netzwerk" "daily: nur einmal am Tag"
# Eigene Uhrzeit, Einzahl und ein Rekord.
rm -f "$T/watch/daily-$todaydate" "$T"/watch/peak-* "$P"/[2-4].json
echo "{\"tracks\":{\"A\":{\"records\":[{\"name\":\"Sebi\",\"time\":61.2,\"at\":$now}]}}}" >"$T/root/shared/beamnet/races/italy.json"
echo "DAILY_HOUR=8" >>"$T/beamnet.conf"
out=$(BEAMNET_HOUR=09 "$TOOL" watch 2>&1)
contains "$out" "📊 Heute im Netzwerk: 40\\.2 km von 1 Fahrer · Top: 1\\. Sebi \\(40\\.2 km\\) · 1 neuer Streckenrekord$" "daily: DAILY_HOUR, Einzahl"
# Tagesspitze haengt an der Zusammenfassung.
rm -f "$T/watch/daily-$todaydate"
echo 9 >"$T/watch/peak-$todaydate"
out=$(BEAMNET_HOUR=09 "$TOOL" watch 2>&1)
contains "$out" "1 neuer Streckenrekord · Spitze: [0-9]+ Spieler gleichzeitig$" "daily: Tagesspitze"
contains "$("$TOOL" watch status 2>&1)" "Tageszusammenfassung: an \\(täglich ab 8 Uhr\\)" "watch status: Tageszusammenfassung"
# Niemand gefahren: keine Meldung.
rm -f "$T/watch/daily-$todaydate" "$P"/1.json
: >"$T/curl.log"
out=$(BEAMNET_HOUR=22 "$TOOL" watch 2>&1)
lacks "$out" "Heute im Netzwerk" "daily: ohne Fahrer keine Meldung"
[[ ! -f $T/watch/daily-$todaydate ]] && pass || fail "daily: ohne Fahrer nicht als erledigt markiert (spaetere Fahrer zaehlen noch)"
lacks "$(cat "$T/curl.log")" "sendMessage|discord.com" "daily: ohne Fahrer nichts an Discord/Telegram"
# DAILY_SUMMARY=0 schaltet ab.
rm -f "$T/watch/daily-$todaydate"
echo "{\"name\":\"Sebi\",\"day\":$today,\"dayKm\":40.2}" >"$P/1.json"
echo "DAILY_SUMMARY=0" >>"$T/beamnet.conf"
out=$(BEAMNET_HOUR=22 "$TOOL" watch 2>&1)
lacks "$out" "Heute im Netzwerk" "daily: DAILY_SUMMARY=0 schaltet ab"
contains "$("$TOOL" watch status 2>&1)" "Tageszusammenfassung: aus" "watch status: Tageszusammenfassung aus"
# Ohne Webhook: nichts.
sed -i '/^DAILY_SUMMARY=/d; s|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=|; s/^TELEGRAM_TOKEN=.*/TELEGRAM_TOKEN=/; s/^TELEGRAM_CHAT=.*/TELEGRAM_CHAT=/' "$T/beamnet.conf"
out=$(BEAMNET_HOUR=22 "$TOOL" watch 2>&1)
lacks "$out" "Heute im Netzwerk" "daily: ohne Webhook und Telegram keine Zusammenfassung"
rm -rf "$P" "$T/fremd.json" "$T/root/shared/beamnet/races/italy.json" "$T/watch/daily-$todaydate"
[[ -f $T/italy.keep ]] && mv "$T/italy.keep" "$T/root/shared/beamnet/races/italy.json"
mv "$T/players.keep" "$P"
mv "$T/conf.keep" "$T/beamnet.conf"

# --- Spielerrekord (watch_peak) ------------------------------------------------------------------------------------
S="$T/root/shared/beamnet"
mkdir -p "$S/servers"
rm -f "$S"/servers/*.json "$T/watch/peak" "$T"/watch/peak-*
cp "$T/beamnet.conf" "$T/conf.peak"
sed -i 's|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc|' "$T/beamnet.conf"
players_on() {   # players_on <nr> <anzahl>
    echo "{\"port\":$((30813 + $1)),\"players\":$2,\"max\":8,\"updated\":$(date +%s)}" >"$S/servers/$((30813 + $1)).json"
}
players_on 1 3; players_on 2 4
out=$("$TOOL" watch 2>&1)
lacks "$out" "Spielerrekord" "peak: erster Lauf legt den Rekord nur fest"
contains "$(cat "$S/peak.json")" '"allTime":7,' "peak: Rekord gespeichert"
players_on 3 5
: >"$T/curl.log"
out=$("$TOOL" watch 2>&1)
contains "$out" "🎉 Neuer Spielerrekord: 12 Spieler gleichzeitig im Netzwerk \\(bisher 7\\)!" "peak: neuer Rekord gemeldet"
contains "$(cat "$T/curl.log")" "Neuer Spielerrekord" "peak: an Discord"
contains "$out" "^   Server 3 \\(.*\\): 5 Spieler$" "peak: Rekordmeldung zeigt die Server (ohne Namen im Lebenszeichen die Anzahl)"
players_on 4 2
out=$("$TOOL" watch 2>&1)
lacks "$out" "Spielerrekord" "peak: höchstens alle 30 Minuten eine Meldung"
contains "$(cat "$S/peak.json")" '"allTime":14,' "peak: Rekord trotzdem fortgeschrieben"
contains "$(cat "$S/peak.json")" '"today":14,' "peak: Tagesspitze"
players_on 4 0
"$TOOL" watch >/dev/null 2>&1
contains "$(cat "$S/peak.json")" '"allTime":14,.*"online":12,' "peak: weniger online ändert den Rekord nicht"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" "Rekord: 14 gleichzeitig \\([0-9]{2}\\.[0-9]{2}\\.[0-9]{4}\\)" "peak: auf der Statusseite"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["peak"]["allTime"] == 14' "$T/web/api.json" && pass || fail "peak: in api.json"
# Spitze je Stunde (7 Tage) fuer das Diagramm.
hr=$(tail -n1 "$T/watch/hours" | cut -d' ' -f1)      # Stunde aus der Datei (sonst wackelt der Test zur vollen Stunde)
(( hr % 3600 == 0 && $(date +%s) - hr < 7200 )) && pass || fail "hours: Stundenbeginn der laufenden Stunde"
contains "$(cat "$T/watch/hours")" "^$hr 14$" "hours: Spitze der laufenden Stunde"
contains "$(cat "$S/peak.json")" "\\[$hr,14\\]\\]\\}$" "hours: in peak.json (laufende Stunde zuletzt)"
contains "$(cat "$T/web/index.html")" "Spieler je Stunde \\(7 Tage\\)" "hours: Diagramm auf der Statusseite"
contains "$(cat "$T/web/index.html")" "Spitze: <b>14</b> Spieler gleichzeitig" "hours: Wochenspitze unter dem Diagramm"
contains "$(cat "$T/web/index.html")" "<title>[A-Z][a-z] [0-9]{2}\\.[0-9]{2}\\. [0-9]{2} Uhr: 14 Spieler</title>" "hours: Tooltip je Balken"
lacks "$(cat "$T/web/index.html")" "<script" "hours: Diagramm ohne Skripte"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["peak"]["hours"][-1] == [int(sys.argv[2]), 14]' "$T/web/api.json" "$hr" && pass || fail "hours: in api.json"
printf '%s 3\nquatsch\n%s 9 x\n%s 6\n%s 14\n' "$(( hr - 8 * 86400 ))" "$(( hr - 3600 ))" "$(( hr - 7200 ))" "$hr" >"$T/watch/hours"
"$TOOL" watch >/dev/null 2>&1
[[ $(head -n2 "$T/watch/hours") == "$(( hr - 7200 )) 6"$'\n'"$hr 14" ]] && pass || fail "hours: alte Stunden und kaputte Zeilen entfernt"
echo '{"allTime":1,"hours":[[1,2],"x",[true,5],[99999999999,1]]}' >"$S/peak.json"
"$TOOL" web run >/dev/null 2>&1
lacks "$(cat "$T/web/index.html")" "Spieler je Stunde" "hours: ohne gueltige Stunden kein Diagramm"
rm -f "$S"/servers/*.json
cp "$T/conf.peak" "$T/beamnet.conf"

# --- Bestenlisten-Index (watch_index) -------------------------------------------------------------------------------
P="$T/root/shared/beamnet/players"
mkdir -p "$P"
printf '{"id":"901","name":"Tab\\tName\\nZeile","km":12.5,"seconds":60,"bonusXp":5,"week":"2025-W41","weekKm":3,"month":"2025-10","monthXp":40,"topSpeedKmh":231.5}' >"$P/901.json"
echo '{"id":"902","name":"Alt","km":1,"seconds":0,"xp":500,"month":"2025-10","monthStartXp":430}' >"$P/902.json"
echo '{"id":"../böse","name":"Pfad","km":1}' >"$P/903.json"
echo '{"id":"904","name":"Woche","km":1,"week":"x\ty"}' >"$P/904.json"
echo '{kaputt' >"$P/905.json"
echo '{"id":"906","name":"Fremd","km":99999}' >"$T/fremd.json"; ln -sf "$T/fremd.json" "$P/906.json"
"$TOOL" watch >/dev/null 2>&1
idx=$(cat "$T/root/shared/beamnet/players-index.tsv" 2>/dev/null)
contains "$idx" "^# beamnet-index 4 [0-9]+$" "index: Kopfzeile mit Format 4 und Zeitstempel"
contains "$idx" $'^901\tTabNameZeile\t12\.5\t60\t5\t2025-W41\t3\t\t\t2025-10\t40\t\t\t231\.5\t\t\t$' "index: Zeile ohne Tabulatoren und Umbrueche im Namen, mit Spitze"
contains "$idx" $'^902\tAlt\t1\t0\t\t\t\t\t\t2025-10\t70\t\t\t\t\t\t$' "index: Saison-XP fuer Datensaetze von 1.8"
contains "$idx" $'^904\tWoche\t1\t\t\t\t' "index: ungueltige Wochenangabe leer"
lacks "$idx" "Pfad|Fremd|99999|kaputt" "index: unsichere IDs, Symlinks und kaputte Dateien fehlen"
[[ $(stat -c %a "$T/root/shared/beamnet/players-index.tsv") == 644 ]] && pass || fail "index: lesbar fuer das Plugin (644)"
python3 - "$T/root/shared/beamnet/players-index.tsv" <<'PY' && pass || fail "index: jede Zeile hat genau 17 Felder"
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]
sys.exit(0 if lines and all(len(l.split("\t")) == 17 for l in lines) else 1)
PY
rm -f "$P"/90[1-6].json "$T/fremd.json"

# --- Update zuerst auf einem Testserver (install-core mit Testserver) ------------------------------------------------
S="$T/root/shared/beamnet"
newver=$(grep -o 'BN.VERSION = "[0-9.]*"' "$HERE/../server/BeamNetCore/main.lua" | head -n1 | cut -d'"' -f2)
for nr in 1 2 3 4 5 6; do
    mkdir -p "$T/root/$nr/Resources/Server/BeamNetCore"
    echo "-- BeamNetCore alt $nr" >"$T/root/$nr/Resources/Server/BeamNetCore/main.lua"
    touch "$T/state/beammp-$nr.service.active"
done
rm -f "$S"/servers/*.json
hb() { echo "{\"port\":$((30813 + $1)),\"players\":$2,\"max\":8,\"updated\":$(date +%s),\"version\":\"$3\"}" >"$S/servers/$((30813 + $1)).json"; }
hb 1 4 1.0; hb 2 0 1.0; hb 3 2 1.0
out=$(BEAMNET_CANARY=1 BEAMNET_CANARY_WAIT=0 "$TOOL" -y install-core 2>&1); rc=$?
contains "$out" "Teste BeamNetCore $newver zuerst auf Server 2" "canary: Server mit den wenigsten Spielern zuerst"
[[ $rc -ne 0 ]] && pass || fail "canary: meldet sich nicht -> Abbruch mit Fehlercode"
contains "$out" "Server 2 meldet sich nicht mit $newver – alte Version wiederhergestellt" "canary: alte Version zurueck"
[[ $(cat "$T/root/2/Resources/Server/BeamNetCore/main.lua") == "-- BeamNetCore alt 2" ]] && pass || fail "canary: Testserver hat wieder die alte Datei"
[[ $(cat "$T/root/1/Resources/Server/BeamNetCore/main.lua") == "-- BeamNetCore alt 1" && \
   $(cat "$T/root/6/Resources/Server/BeamNetCore/main.lua") == "-- BeamNetCore alt 6" ]] && pass || fail "canary: uebrige Server unveraendert"
hb 2 0 "$newver"
out=$(BEAMNET_CANARY=1 BEAMNET_CANARY_WAIT=0 "$TOOL" -y install-core 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass || fail "canary: meldet sich mit neuer Version -> weiter"
contains "$out" "Server 2 läuft mit BeamNetCore $newver – jetzt die übrigen Server" "canary: Erfolgsmeldung"
same=1; for nr in 1 2 3 4 5 6; do cmp -s "$T/root/$nr/Resources/Server/BeamNetCore/main.lua" "$HERE/../server/BeamNetCore/main.lua" || same=0; done
(( same )) && pass || fail "canary: danach auf allen Servern die neue Version"
# Kein Server mit Lebenszeichen (z. B. erste Installation): gleich ueberall.
rm -f "$S"/servers/*.json
out=$(BEAMNET_CANARY=1 BEAMNET_CANARY_WAIT=0 "$TOOL" -y install-core 2>&1)
lacks "$out" "Teste BeamNetCore" "canary: ohne Lebenszeichen kein Testserver"

# --- Last-Warnung (watch_load) ------------------------------------------------------------------------------------------
touch "$T/state/beammp-1.service.active"
rm -f "$T"/watch/cpu-* "$T"/watch/cpuhigh-* "$T"/watch/memhigh-*
busy() {   # busy <prozent>: Server 1 hat seit dem letzten Lauf (vor 60 s) so viel CPU verbraucht
    echo "0 $(( $(date +%s) - 60 ))" >"$T/watch/cpu-1"
    echo "$(( $1 * 600000000 ))" >"$T/state/beammp-1.service.cpu"
}
for i in 1 2 3 4; do busy 95; out=$("$TOOL" watch 2>&1); done
lacks "$out" "ausgelastet" "load: noch keine Warnung nach 4 Minuten"
busy 95; out=$("$TOOL" watch 2>&1)
contains "$out" "🔥 Server 1 \\(.*\\) ist seit 5 Minuten ausgelastet \\(CPU 9[0-9] %\\)" "load: Warnung nach 5 Minuten"
busy 97; out=$("$TOOL" watch 2>&1)
lacks "$out" "ausgelastet" "load: Warnung nur einmal"
busy 30; out=$("$TOOL" watch 2>&1)
contains "$out" "✅ Server 1 \\(.*\\) ist nicht mehr ausgelastet \\(CPU [23][0-9] %\\)" "load: Entwarnung"
busy 30; out=$("$TOOL" watch 2>&1)
lacks "$out" "ausgelastet" "load: Entwarnung nur einmal"
echo $(( 2000 * 1048576 )) >"$T/state/beammp-1.service.mem"
out=$("$TOOL" watch 2>&1)
contains "$out" "🧠 Server 1 \\(.*\\) belegt 2000 MB RAM \\(Grenze 1500 MB\\)" "load: RAM-Warnung"
lacks "$("$TOOL" watch 2>&1)" "🧠" "load: RAM-Warnung nur einmal"
echo $(( 400 * 1048576 )) >"$T/state/beammp-1.service.mem"
contains "$("$TOOL" watch 2>&1)" "✅ Server 1 \\(.*\\) belegt wieder 400 MB RAM" "load: RAM-Entwarnung"
echo '[not set]' >"$T/state/beammp-1.service.mem"
sed -i 's/^CPU_WARN=.*/CPU_WARN=-/' "$T/beamnet.conf"
rm -f "$T/watch/cpuhigh-1"
for i in 1 2 3 4 5 6; do busy 99; out=$("$TOOL" watch 2>&1); done
lacks "$out" "ausgelastet" "load: CPU_WARN=- schaltet ab"
sed -i 's/^CPU_WARN=.*/CPU_WARN=90/' "$T/beamnet.conf"
rm -f "$T"/state/beammp-1.service.cpu "$T"/state/beammp-1.service.mem "$T"/watch/cpu-* "$T"/watch/cpuhigh-*

# --- Netzwerk fast voll (watch_capacity) ------------------------------------------------------------------------------
S="$T/root/shared/beamnet"
rm -f "$S"/servers/*.json "$T/watch/capacity-high"
cap() { echo "{\"port\":$((30813 + $1)),\"players\":$2,\"max\":$3,\"updated\":$(date +%s)}" >"$S/servers/$((30813 + $1)).json"; }
cap 1 8 8; cap 2 7 8; cap 3 6 8
out=$("$TOOL" watch 2>&1)
lacks "$out" "fast voll" "capacity: unter 90 % keine Meldung"
cap 3 8 8
out=$("$TOOL" watch 2>&1)
contains "$out" "📈 Netzwerk fast voll: 23 von 24 Plätzen belegt \\(95 %\\)\\. Noch Platz: Server 2 \\([a-z_]+\\): 1 frei$" "capacity: Meldung mit freien Servern"
lacks "$("$TOOL" watch 2>&1)" "fast voll" "capacity: nur einmal"
cap 1 2 8; cap 2 2 8; cap 3 2 8
contains "$("$TOOL" watch 2>&1)" "✅ Wieder Platz im Netzwerk: 6 von 24 Plätzen belegt" "capacity: Entwarnung"
cap 1 8 8; cap 2 8 8; cap 3 8 8
contains "$("$TOOL" watch 2>&1)" "Alle Server sind voll – Zeit für einen weiteren Server\\?" "capacity: alle voll"
rm -f "$S"/servers/*.json "$T/watch/capacity-high"

# --- Untergeschobene Symlinks/FIFOs als ServerConfig.toml halten den Waechter nicht an --------------------------------
mkdir -p "$T/root/9"; mkfifo "$T/fifo9"; ln -s "$T/fifo9" "$T/root/9/ServerConfig.toml"
"$REAL_TIMEOUT" 60 "$TOOL" watch >/dev/null 2>&1; rc=$?
[[ $rc != 124 ]] && pass || fail "cfg: Symlink auf eine FIFO haelt den Waechter nicht an"
lacks "$("$REAL_TIMEOUT" 60 "$TOOL" status 2>&1)" "Server 9" "servers: Symlink als ServerConfig.toml zaehlt nicht"
rm -rf "$T/root/9" "$T/fifo9"

# --- Update-Hinweis (watch_update) ------------------------------------------------------------------------------------
rm -f "$T"/watch/updatecheck-* "$T/watch/update-notified"
printf '#!/usr/bin/env bash\n# BeamNet\nVERSION="99.1"\n' >"$T/raw-latest.sh"
out=$("$TOOL" watch 2>&1)
contains "$out" "🆕 BeamNet-Update verfügbar: Werkzeug 99\\.1 \\(installiert: [0-9.]+\\) – auf dem Server: sudo beamnet update" "update: neuere Version gemeldet"
lacks "$("$TOOL" watch 2>&1)" "Update verfügbar" "update: hoechstens einmal am Tag nachsehen"
rm -f "$T"/watch/updatecheck-*
lacks "$("$TOOL" watch 2>&1)" "Update verfügbar" "update: dieselbe Version nur einmal melden"
rm -f "$T"/watch/updatecheck-*
printf 'VERSION="1.0"\n' >"$T/raw-latest.sh"
lacks "$("$TOOL" watch 2>&1)" "Update verfügbar" "update: aeltere Version nicht"
rm -f "$T"/watch/updatecheck-*
printf 'VERSION="99.2"; rm -rf /\n' >"$T/raw-latest.sh"
lacks "$("$TOOL" watch 2>&1)" "Update verfügbar" "update: nur eine saubere VERSION-Zeile zaehlt"
rm -f "$T/raw-latest.sh"

# --- Bonus-Map des Tages (watch_bonusmap) ----------------------------------------------------------------------------
B="$T/root/shared/beamnet/bonusmap.json"
rm -f "$T"/watch/bonusmap-* "$T"/watch/usage-* "$B"
for nr in 1 2 3 4 5 6; do
    m=$(sed -n 's|^Map = "/levels/\([^/]*\)/.*|\1|p' "$T/root/$nr/ServerConfig.toml")
    [[ $m == east_coast_usa ]] || echo "$nr $m 8 600" >>"$T/watch/usage-$(date -d '-1 days' +%Y-%m-%d)"
done
out=$("$TOOL" watch 2>&1)
contains "$out" "🗺️ Bonus-Map heute: east_coast_usa \\(Server 4\\) – \\+50 % XP beim Fahren bis Mitternacht\\." "bonusmap: am wenigsten gefahrene Map"
python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])); assert d["map"]=="east_coast_usa" and d["factor"]==1.5 and time.time() < d["until"] <= time.time()+86400' "$B" \
    && pass || fail "bonusmap: bonusmap.json fuer das Plugin"
lacks "$("$TOOL" watch 2>&1)" "Bonus-Map" "bonusmap: einmal am Tag"
# Leere Tagesdatei (z. B. Schreiben fehlgeschlagen): noch nicht gewaehlt – erneut versuchen.
: >"$T/watch/bonusmap-$(date +%F)"
contains "$("$TOOL" watch 2>&1)" "🗺️ Bonus-Map heute: east_coast_usa" "bonusmap: nach fehlgeschlagenem Versuch erneut"
# Map von Server 4 wechselt (Rotation/Abstimmung): die Bonus-Map laeuft nirgends mehr – neu waehlen.
cp "$T/root/4/ServerConfig.toml" "$T/sc4.bonus"
sed -i 's|^Map = .*|Map = "/levels/gridmap_v2/info.json"|' "$T/root/4/ServerConfig.toml"
out=$("$TOOL" watch 2>&1)
contains "$out" "🗺️ Bonus-Map heute: " "bonusmap: neu gewaehlt, wenn die Map nirgends mehr laeuft"
lacks "$(cat "$B")" "east_coast_usa" "bonusmap: alte Map nicht mehr Bonus-Map"
# Der Dienst darf bonusmap.json schreiben: eine fremde Map dort loest weder neues Waehlen noch Meldungen aus.
printf '{"map":"fremd","factor":1.5,"until":%s}' $(( $(date +%s) + 3600 )) >"$B"
lacks "$("$TOOL" watch 2>&1)" "Bonus-Map" "bonusmap: fremde Map in bonusmap.json loest nichts aus"
# Nur noch eine Map auf allen Servern: alte Bonus-Map nicht mehr zeigen, danach Ruhe (keine Schleife je Minute).
for nr in 1 2 3 4 5 6; do
    cp "$T/root/$nr/ServerConfig.toml" "$T/sc$nr.one"
    sed -i 's|^Map = .*|Map = "/levels/small_island/info.json"|' "$T/root/$nr/ServerConfig.toml"
done
lacks "$("$TOOL" watch 2>&1)" "Bonus-Map" "bonusmap: nur eine Map – keine Meldung"
[[ $(cat "$B") == '{"map":""}' && $(tail -n 1 "$T/watch/bonusmap-$(date +%F)") == - ]] && pass || fail "bonusmap: nur eine Map – alte Bonus-Map geloescht"
n=$(wc -l <"$T/watch/bonusmap-$(date +%F)")
"$TOOL" watch >/dev/null 2>&1
[[ $(wc -l <"$T/watch/bonusmap-$(date +%F)") == "$n" ]] && pass || fail "bonusmap: nur eine Map – danach nicht jede Minute neu"
for nr in 1 2 3 4 5 6; do cp "$T/sc$nr.one" "$T/root/$nr/ServerConfig.toml"; done
# Hoechstens dreimal am Tag neu waehlen.
printf 'a\nb\nweg\n' >"$T/watch/bonusmap-$(date +%F)"
lacks "$("$TOOL" watch 2>&1)" "Bonus-Map" "bonusmap: hoechstens dreimal am Tag"
cp "$T/sc4.bonus" "$T/root/4/ServerConfig.toml"
rm -f "$T"/watch/bonusmap-*
sed -i 's/^BONUS_MAP=.*/BONUS_MAP=0/' "$T/beamnet.conf"
"$TOOL" watch >/dev/null 2>&1
[[ $(cat "$B") == '{"map":""}' ]] && pass || fail "bonusmap: BONUS_MAP=0 schaltet ab"
sed -i 's/^BONUS_MAP=.*/BONUS_MAP=1/' "$T/beamnet.conf"
rm -f "$T"/watch/usage-* "$B"

# --- Spiel-Einstellungen (beamnet config) -----------------------------------------------------------------------------
CJ="$T/root/shared/beamnet/config.json"
cp "$CJ" "$T/config.keep" 2>/dev/null || true
printf '{"publicHost":"a\\u001b]0;boese\\u0007\\u001b[2Jb","xpPerKm":Infinity}' >"$CJ"
out=$("$TOOL" config 2>&1)
lacks "$out" $'\x1b' "config: keine Steuerzeichen aus config.json im Terminal"
contains "$out" "^publicHost +a\\]0;boese\\[2Jb" "config: Text ohne Steuerzeichen"
contains "$out" "^xpPerKm +\\(ungültig\\)" "config: unendlicher Wert stuerzt nicht ab"
if [[ -f $T/config.keep ]]; then cp "$T/config.keep" "$CJ"; else rm -f "$CJ"; fi
out=$("$TOOL" config 2>&1)
contains "$out" "^convoyXp +20 +Konvoi-XP" "config: Liste mit Standardwerten"
contains "$out" "^challengeTypes +km speed time servers" "config: Tagesaufgaben"
contains "$("$TOOL" config comebackXp 100 2>&1)" "comebackXp = 100 – wirksam" "config: Wert setzen"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["comebackXp"] == 100' "$CJ" && pass || fail "config: in config.json geschrieben"
contains "$("$TOOL" config 2>&1)" "^comebackXp +100 .*\(geändert\)" "config: geaenderter Wert markiert"
contains "$("$TOOL" config comebackXp abc 2>&1)" "ganze Zahl von 0 bis 10000" "config: nur Zahlen"
contains "$("$TOOL" config comebackXp 99999 2>&1)" "0 bis 10000" "config: Grenzen"
contains "$("$TOOL" config gibtsnicht 5 2>&1)" "Unbekannter Schlüssel" "config: nur bekannte Schluessel"
"$TOOL" config convoyKm 2,5 >/dev/null 2>&1
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["convoyKm"] == 2.5' "$CJ" && pass || fail "config: Kommazahl"
"$TOOL" config achievements aus >/dev/null 2>&1
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["achievements"] is False' "$CJ" && pass || fail "config: an/aus"
"$TOOL" config aufgaben km jobs mapkm jobs bonus >/dev/null 2>&1
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["challengeTypes"] == ["km", "jobs", "mapkm", "bonus"]' "$CJ" && pass || fail "config: Tagesaufgaben setzen (ohne doppelte, mit Bonus-Map)"
contains "$("$TOOL" config aufgaben km fliegen 2>&1)" "Unbekannte Tagesaufgabe" "config: nur bekannte Tagesaufgaben"
"$TOOL" config comebackXp standard >/dev/null 2>&1
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["comebackXp"] == 50' "$CJ" && pass || fail "config: standard"
contains "$(FAKE_UID=1000 "$TOOL" config comebackXp 10 2>&1)" "Bitte als root" "config: Aendern nur als root"
# Standardwerte im Werkzeug = Standardwerte im Plugin.
python3 - "$TOOL" "$HERE/../server/BeamNetCore/main.lua" <<'PY' && pass || fail "config: Standardwerte wie im Plugin"
import ast, re, sys
tool, lua = open(sys.argv[1], encoding="utf-8").read(), open(sys.argv[2], encoding="utf-8").read()
block = tool[tool.index("KEYS = {"):tool.index("ALIASES =")]
keys = {}
for m in re.finditer(r'^\s+"(\w+)": \((.*)\),\s*$', block, re.M):
    t = ast.literal_eval("(" + m.group(2) + ")")
    keys[m.group(1)] = t[3]
defaults = lua[lua.index("local defaults = {"):]
bad = []
for k, d in keys.items():
    m = re.search(r"^\s+" + k + r" = (.+?),\s*(--.*)?$", defaults, re.M)
    if not m:
        bad.append(k); continue
    v = m.group(1).strip()
    if v.startswith("{"):
        v = [x.strip().strip('"') for x in v.strip("{} ").split(",")]
    elif v in ("true", "false"):
        v = v == "true"
    elif v.startswith('"'):
        v = v.strip('"')
    else:
        v = float(v)
    if (float(d) if isinstance(d, (int, float)) and not isinstance(d, bool) else d) != v:
        bad.append(k)
if bad:
    print("abweichend:", bad); sys.exit(1)
PY
cp "$T/config.keep" "$CJ" 2>/dev/null || true

# --- Ansagen von der Konsole (beamnet ansage) --------------------------------------------------------------------------
A="$T/root/shared/beamnet/announcements.json"
rm -f "$A"
contains "$("$TOOL" ansage 2>&1)" "Keine geplanten Ansagen" "ansage: ohne geplante Ansagen"
out=$("$TOOL" ansage "Neustart in 5 Minuten" 2>&1)
contains "$out" "Ansage gesendet" "ansage: sofort"
python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])); a=d["list"][-1]; assert a["text"]=="Neustart in 5 Minuten" and a["by"]=="Konsole" and abs(a["at"]-time.time())<5' "$A" \
    && pass || fail "ansage: Eintrag fuer BeamNetCore geschrieben"
soon=$(date -d '+2 hours' +%H:%M)
out=$("$TOOL" ansage "$soon" $'Event\tam Hafen' 2>&1)
contains "$out" "Ansage geplant für [0-9.]+ $soon Uhr" "ansage: mit Uhrzeit geplant"
contains "$("$TOOL" ansage 2>&1)" "$soon  Event am Hafen  \\(Konsole\\)" "ansage: geplante Ansagen werden gezeigt (ohne Steuerzeichen)"
for i in $(seq 1 25); do "$TOOL" ansage "Nr $i" >/dev/null 2>&1; done
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d["list"])==20' "$A" && pass || fail "ansage: hoechstens 20 Eintraege"
echo '{"list":[{"id":"x","text":"GEHEIM","at":1}]}' >"$T/fremd-ann.json"; rm -f "$A"; ln -s "$T/fremd-ann.json" "$A"
"$TOOL" ansage "Hallo" >/dev/null 2>&1
lacks "$([[ -L $A ]] || cat "$A")" "GEHEIM" "ansage: liest keine Symlinks"
[[ $(cat "$T/fremd-ann.json") == '{"list":[{"id":"x","text":"GEHEIM","at":1}]}' ]] && pass || fail "ansage: Symlink-Ziel unveraendert"
rm -f "$A" "$T/fremd-ann.json"

# --- XP-Abende (beamnet event, watch_autoevent) ------------------------------------------------------------------------
E="$T/root/shared/beamnet/event.json"
A="$T/root/shared/beamnet/announcements.json"
rm -f "$E" "$A" "$T"/watch/autoevent-*
contains "$("$TOOL" event 2>&1)" "Automatischer XP-Abend: aus" "event: Stand ohne Plan"
contains "$("$TOOL" event auto xx 20:00 2 2h 2>&1)" "Aufruf: beamnet event auto" "event auto: falsche Tage abgelehnt"
contains "$("$TOOL" event auto fr 25:00 2 2h 2>&1)" "Aufruf: beamnet event auto" "event auto: falsche Uhrzeit abgelehnt"
contains "$("$TOOL" event auto fr 20:00 9 2h 2>&1)" "Aufruf: beamnet event auto" "event auto: Faktor hoechstens 5"
contains "$("$TOOL" event auto fr 20:00 2 8h 2>&1)" "Aufruf: beamnet event auto" "event auto: hoechstens 6 Stunden"
"$TOOL" event auto fr,sa 20:00 2 2h >/dev/null 2>&1
contains "$(cat "$T/beamnet.conf")" "^AUTO_EVENT=fr,sa 20:00 2 2h$" "event auto: Plan gespeichert"
contains "$("$TOOL" event 2>&1)" "Automatischer XP-Abend: fr,sa 20:00 2 2h" "event: Plan wird gezeigt"
X="$T/root/shared/beamnet/xpabend.json"
python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])); assert d["factor"]==2 and d["sec"]==7200 and time.time() < d["next"] < time.time() + 8*86400 and time.localtime(d["next"]).tm_hour == 20 and time.localtime(d["next"]).tm_wday in (4, 5)' "$X" \
    && pass || fail "event auto: naechster XP-Abend in xpabend.json (fuer Plugin und Statusseite)"
"$TOOL" web run >/dev/null 2>&1
contains "$(cat "$T/web/index.html")" "🎉 XP-Abend: 2-fache XP auf allen Servern bis 22:00 Uhr" "event auto: XP-Abend unter Demnaechst auf der Statusseite"
fri=$(date -d "next friday" +%F)
start=$(date -d "$fri 20:00" +%s)
out=$(BEAMNET_NOW=$(( start - 86400 * 2 )) BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
lacks "$out" "XP-Abend" "autoevent: an anderen Tagen nichts"
out=$(BEAMNET_NOW=$(( start - 7200 )) BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
lacks "$out" "XP-Abend" "autoevent: zwei Stunden vorher noch nichts"
out=$(BEAMNET_NOW=$(( start - 1800 )) BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
contains "$out" "🎉 Heute 20:00–22:00 Uhr: XP-Abend mit 2-facher XP auf allen BeamNet-Servern" "autoevent: Ankuendigung eine Stunde vorher"
contains "$(cat "$A" 2>/dev/null)" "XP-Abend mit 2-facher XP" "autoevent: Ankuendigung auch im Spiel"
out=$(BEAMNET_NOW=$(( start - 1700 )) BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
lacks "$out" "🎉 Heute" "autoevent: Ankuendigung nur einmal"
out=$(BEAMNET_NOW=$(( start + 60 )) BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
contains "$out" "🚀 XP-Abend läuft: 2-fache XP bis 22:00 Uhr" "autoevent: Start zur Uhrzeit"
python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])); assert d["factor"]==2 and d["by"]=="XP-Abend" and 7000 < d["until"]-time.time() <= 7140' "$E" \
    && pass || fail "autoevent: event.json fuer das Plugin (Faktor, Ende)"
out=$(BEAMNET_NOW=$(( start + 120 )) BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
lacks "$out" "🚀" "autoevent: Start nur einmal"
# Laeuft schon ein Event (z. B. von einem Admin), wird bis zum Ende des Fensters gewartet, dann keins gestartet.
rm -f "$T"/watch/autoevent-start-*
"$TOOL" event start 3 1h >/dev/null 2>&1
out=$(BEAMNET_NOW=$(( start + 60 )) BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
lacks "$out" "XP-Abend" "autoevent: laufendes Event – erst weiter warten"
out=$(BEAMNET_NOW=$(( start + 560 )) BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
contains "$out" "es läuft schon ein XP-Event" "autoevent: kein zweites Event"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["factor"]==3' "$E" && pass || fail "autoevent: laufendes Event bleibt"
# Von Hand: start/stop.
contains "$("$TOOL" event start 9 2h 2>&1)" "Aufruf: beamnet event start" "event start: Faktor geprueft"
contains "$("$TOOL" event start 1,5 90m 2>&1)" "1,5-fache XP für 90 Minuten" "event start: mit Komma"
contains "$("$TOOL" event 2>&1)" "⚡ XP-Event läuft: 1,5-fache XP bis [0-9:]+ Uhr \(von Konsole\)" "event: laufendes Event erkannt (Faktor, Ende, von wem)"
"$TOOL" event stop >/dev/null 2>&1
contains "$("$TOOL" event 2>&1)" "Gerade läuft kein XP-Event" "event stop: beendet"
# Kurz nach Mitternacht: Ankuendigung schon am Vorabend.
"$TOOL" event auto sa 00:30 2 2h >/dev/null 2>&1
sat=$(date -d "$fri + 1 day" +%F)
rm -f "$T"/watch/autoevent-*
out=$(BEAMNET_NOW=$(( $(date -d "$sat 00:30" +%s) - 2400 )) BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
contains "$out" "🎉 Gleich 00:30–02:30 Uhr: XP-Abend" "autoevent: Abend nach Mitternacht am Vorabend angekuendigt"
# Ein Map-Name aus ServerConfig.toml wird bereinigt (nie Befehle in Rechenausdruecken).
cp "$T/root/4/ServerConfig.toml" "$T/sc4.keep"
sed -i 's|^Map = .*|Map = "/levels/a$(id)b[x]/info.json"|' "$T/root/4/ServerConfig.toml"
out=$("$TOOL" status 2>&1)
contains "$out" " aidbx " "map_short: Map-Name nur mit harmlosen Zeichen"
lacks "$out" "uid=" "map_short: kein Befehl aus dem Map-Namen"
cp "$T/sc4.keep" "$T/root/4/ServerConfig.toml"
# Zeitumstellung (Sommerzeit am 28.03.2027): der Sonntag wird nicht uebersprungen.
"$TOOL" event auto so 20:00 2 2h >/dev/null 2>&1
rm -f "$X"
TZ=Europe/Berlin BEAMNET_NOW=$(TZ=Europe/Berlin date -d "2027-03-27 23:30" +%s) BEAMNET_HOUR=12 "$TOOL" watch >/dev/null 2>&1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["next"]==int(sys.argv[2]), d' "$X" "$(TZ=Europe/Berlin date -d "2027-03-28 20:00" +%s)" \
    && pass || fail "autoevent: Sonntag nach der Zeitumstellung gefunden"
# Riesige (duenn belegte) Datei im gemeinsamen Ordner: wird nicht gelesen, kein Absturz.
rm -f "$E"; truncate -s 100M "$E"
contains "$("$TOOL" event 2>&1)" "Gerade läuft kein XP-Event" "safe get: riesige Datei wird nicht geladen"
rm -f "$E"
"$TOOL" event auto aus >/dev/null 2>&1
contains "$("$TOOL" event 2>&1)" "Automatischer XP-Abend: aus" "event auto aus"
[[ $(cat "$X") == '{"next":0}' ]] && pass || fail "event auto aus: xpabend.json ohne naechsten Abend"
rm -f "$E" "$A" "$T"/watch/autoevent-*

# --- Taegliche Datensicherung und Wiederherstellung --------------------------------------------------------------------
S="$T/root/shared/beamnet"
B="$T/backups"
today=$(date +%Y-%m-%d)
rm -f "$B"/daten-*.tgz "$T"/watch/backup-failed-*
mkdir -p "$S/players" "$S/races" "$S/servers" "$S/votes"
echo '{"id":"501","name":"Gesichert","km":42}' >"$S/players/501.json"
echo '{"tracks":{}}' >"$S/races/italy.json"
echo '[]' >"$S/bans.json"
echo '{"x":1}' >"$S/votes/30814.json"
echo 'tmp' >"$S/.beamnet-abc.tmp"
echo '{"id":"502","secret":"root"}' >"$T/geheim2.json"; ln -sf "$T/geheim2.json" "$S/players/502.json"
ln -sfn "$T" "$S/evil"
out=$(BEAMNET_HOUR=03 "$TOOL" watch 2>&1)
[[ ! -f $B/daten-$today.tgz ]] && pass || fail "backup: nicht vor BACKUP_HOUR"
out=$(BEAMNET_HOUR=05 "$TOOL" watch 2>&1)
[[ -f $B/daten-$today.tgz ]] && pass || fail "backup: taeglich angelegt"
[[ $(stat -c %a "$B/daten-$today.tgz") == 600 ]] && pass || fail "backup: nur fuer root lesbar"
list=$(tar -tzf "$B/daten-$today.tgz" | sort)
contains "$list" "^players/501.json$" "backup: Spielerdateien drin"
contains "$list" "^races/italy.json$" "backup: Rekorde drin"
contains "$list" "^bans.json$" "backup: Banns drin"
lacks "$list" "^servers|^votes|502|evil|\\.tmp|players-index" "backup: ohne Lebenszeichen, Auftraege, Symlinks, Zwischendateien"
lacks "$(tar -xzOf "$B/daten-$today.tgz")" "secret" "backup: Symlink-Ziel nicht mitgesichert"
# Harte Links und Namen, die die Wiederherstellung ablehnt, kommen nicht in die Sicherung.
rm -f "$B/daten-$today.tgz"
head -c 200000 /dev/urandom >"$S/players/gross.json"
for i in 1 2 3 4 5; do ln "$S/players/gross.json" "$S/players/link$i.json"; done
echo '{}' >"$S/players/a\b.json"
: >"$B/daten-alt.tgz.tmp"
BEAMNET_HOUR=05 "$TOOL" watch >/dev/null 2>&1
list=$(tar -tzf "$B/daten-$today.tgz" | sort)
lacks "$list" "gross|link|a.b" "backup: harte Links und unbrauchbare Namen nicht gesichert"
(( $(stat -c %s "$B/daten-$today.tgz") < 100000 )) && pass || fail "backup: harte Links blaehen die Sicherung nicht auf"
[[ ! -e $B/daten-alt.tgz.tmp ]] && pass || fail "backup: Reste abgebrochener Sicherungen entfernt"
rm -f "$S/players/gross.json" "$S"/players/link*.json "$S/players/a\b.json"
before=$(stat -c %Y "$B/daten-$today.tgz"); sleep 1
BEAMNET_HOUR=06 "$TOOL" watch >/dev/null 2>&1
[[ $(stat -c %Y "$B/daten-$today.tgz") == "$before" ]] && pass || fail "backup: nur einmal am Tag"
# Aufbewahrung: die BACKUP_KEEP (14) neuesten bleiben.
for d in $(seq -w 1 16); do : >"$B/daten-2000-01-$d.tgz"; done
mv "$B/daten-$today.tgz" "$T/heute.tgz"
BEAMNET_HOUR=05 "$TOOL" watch >/dev/null 2>&1
[[ $(ls "$B"/daten-*.tgz | wc -l) == 14 && -f $B/daten-$today.tgz && ! -f $B/daten-2000-01-03.tgz && -f $B/daten-2000-01-04.tgz ]] \
    && pass || fail "backup: aelteste Sicherungen entfernt (14 bleiben)"
rm -f "$B"/daten-2000-*.tgz; mv "$T/heute.tgz" "$B/daten-$today.tgz"
contains "$("$TOOL" restore 2>&1)" "^  $today  " "restore: listet die Sicherungen"
# Probe-Wiederherstellung: gute Sicherung ok, kaputte Spielerdatei und unsicherer Eintrag fallen auf.
contains "$("$TOOL" restore check 2>&1)" "Sicherung vom $today ist in Ordnung: [0-9]+ Dateien, [0-9]+ Spieler" "restore check: neueste Sicherung ok"
python3 - "$T/kaputt.tgz" "$T/boese.tgz" <<'PY'
import io, sys, tarfile
def add(tar, name, data):
    info = tarfile.TarInfo(name); info.size = len(data); tar.addfile(info, io.BytesIO(data))
with tarfile.open(sys.argv[1], "w:gz") as t:
    add(t, "players/1.json", b'{"id":"1"}'); add(t, "players/2.json", b"{kaputt")
with tarfile.open(sys.argv[2], "w:gz") as t:
    add(t, "../etc/passwd", b"x")
PY
cp "$T/kaputt.tgz" "$B/daten-2000-02-01.tgz"; cp "$T/boese.tgz" "$B/daten-2000-02-02.tgz"
out=$("$TOOL" restore check 2000-02-01 2>&1)
contains "$out" "in Ordnung: 2 Dateien, 2 Spieler" "restore check: Sicherung mit kaputter Spielerdatei ist trotzdem verwendbar"
contains "$out" "1 Spielerdatei\\(en\\) darin sind kaputt" "restore check: kaputte Spielerdatei als Hinweis"
contains "$("$TOOL" restore check 2000-02-02 2>&1)" "NICHT in Ordnung: .*unsicherer Pfad" "restore check: unsicherer Eintrag erkannt"
contains "$("$TOOL" restore check 2000-13-99x 2>&1)" "Aufruf: beamnet restore check" "restore check: Datum geprüft"
rm -f "$B/daten-2000-02-01.tgz" "$B/daten-2000-02-02.tgz"
# Wiederherstellen: Stand von heute zurueck, neuer Spieler weg, alter Stand beiseitegelegt, Server neu gestartet.
echo '{"id":"501","name":"Gesichert","km":9999}' >"$S/players/501.json"
echo '{"id":"503","name":"Neu"}' >"$S/players/503.json"
: >"$T/actions"
out=$(printf 'n\n' | "$TOOL" restore "$today" 2>&1)
contains "$out" "Abgebrochen" "restore: fragt vorher"
contains "$(cat "$S/players/501.json")" '"km":9999' "restore: ohne Zustimmung nichts geaendert"
out=$("$TOOL" -y restore "$today" 2>&1)
contains "$out" "Stand vom $today wiederhergestellt \\([0-9]+ Dateien\\)" "restore: Erfolgsmeldung"
contains "$(cat "$S/players/501.json")" '"km":42' "restore: Spielerdatei auf altem Stand"
[[ ! -e $S/players/503.json && ! -e $S/evil && -d $S/servers ]] && pass || fail "restore: neuer Spieler und Symlink weg, Ordner wieder da"
old_dir=$(ls -d "$S".vor-wiederherstellung-* 2>/dev/null | head -n1)
[[ -f $old_dir/players/503.json ]] && pass || fail "restore: bisheriger Stand beiseitegelegt"
contains "$(cat "$T/actions")" "^stop beammp-1.service$" "restore: Server waehrend der Wiederherstellung gestoppt"
contains "$(cat "$T/actions")" "^start beammp-1.service$" "restore: Server danach wieder gestartet"
[[ ! -f $T/watch/maintenance-1 ]] && pass || fail "restore: keine Wartungsmarker uebrig"
[[ -f $T/geheim2.json && $(cat "$T/geheim2.json") == '{"id":"502","secret":"root"}' ]] && pass || fail "restore: Symlink-Ziel unberuehrt"
# Manipulierte Archive: nichts aendern.
python3 - "$B/daten-2000-02-01.tgz" "$B/daten-2000-02-02.tgz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    i = tarfile.TarInfo("../ausgebrochen.json"); data = b"x"; i.size = 1; t.addfile(i, io.BytesIO(data))
with tarfile.open(sys.argv[2], "w:gz") as t:
    i = tarfile.TarInfo("players/link.json"); i.type = tarfile.SYMTYPE; i.linkname = "/etc/passwd"; t.addfile(i)
PY
cp "$S/players/501.json" "$T/501.vorher"
out=$("$TOOL" -y restore 2000-02-01 2>&1); rc=$?
[[ $rc -ne 0 && ! -e $T/root/shared/ausgebrochen.json ]] && pass || fail "restore: Pfad mit .. abgewiesen"
contains "$out" "nicht lesbar – nichts geändert" "restore: Meldung bei kaputtem Archiv"
out=$("$TOOL" -y restore 2000-02-02 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass || fail "restore: Symlink im Archiv abgewiesen"
cmp -s "$S/players/501.json" "$T/501.vorher" && pass || fail "restore: nach abgewiesenem Archiv unveraendert"
[[ -z $(ls -d "$S".neu-* 2>/dev/null) ]] && pass || fail "restore: keine halben Ordner uebrig"
contains "$("$TOOL" restore 1999-01-01 2>&1)" "Keine Datensicherung vom 1999-01-01" "restore: unbekanntes Datum"
contains "$("$TOOL" restore gestern 2>&1)" "Aufruf: beamnet restore" "restore: falsches Format"
rm -rf "$S".vor-wiederherstellung-* "$B"/daten-*.tgz "$T/geheim2.json" "$T/501.vorher" "$S/players/501.json"

# --- Moderation an Discord/Telegram (watch_modlog) ------------------------------------------------------------------
M="$T/root/shared/beamnet/modlog.jsonl"
port1=$(grep -m1 '^Port' "$T/root/1/ServerConfig.toml" | grep -o '[0-9]*' | head -n1)
rm -f "$T/watch/modlog-pos"
echo '{"action":"kick","by":"Alt","target":"Vorher","at":1,"server":1}' >"$M"
out=$("$TOOL" watch 2>&1)
lacks "$out" "Vorher" "modlog: beim ersten Lauf keine alte Geschichte"
now=$(date +%s)
{
    printf '{"action":"ban","by":"Sebi","target":"Rambo\\nRacer","targetId":"9","reason":"rammt","until":%s,"at":%s,"server":%s}\n' "$((now + 3600))" "$now" "$port1"
    printf '{"action":"ban","by":"Sebi","target":"Troll","reason":"","at":%s,"server":99999}\n' "$now"
    printf '{"action":"spam-mute","target":"Spammer","seconds":60,"at":%s,"server":%s}\n' "$now" "$port1"
    printf '{"action":"warn","by":"Max","target":"Ana","reason":"bitte rechts fahren","at":%s,"server":%s}\n' "$now" "$port1"
    printf '{"action":"ansage","by":"Max","reason":"Event","at":%s}\n' "$now"
    printf '{"action":"event","by":"Orga","factor":1.5,"until":%s,"at":%s,"server":%s}\n' "$((now + 7200))" "$now" "$port1"
    printf '{"action":"event-stop","by":"Orga","at":%s,"server":%s}\n' "$now" "$port1"
    printf '{"action":"join-spam","target":"Hopper","seconds":120,"at":%s,"server":%s}\n' "$now" "$port1"
    printf '{"action":"filter-mute","target":"Pöbler","seconds":300,"at":%s,"server":%s}\n' "$now" "$port1"
    printf '{"action":"ort-vorschlag","by":"Melder","target":"Klinik Nord","kind":"krankenhaus","at":%s,"server":%s}\n' "$now" "$port1"
    printf '{"action":"liga","target":"Sebi","league":"Gold","xp":2100,"at":%s,"server":%s}\n' "$now" "$port1"
    echo 'kaputt'
    printf '{"action":"kick","by":"Max","target":"Halb"'
} >>"$M"
: >"$T/curl.log"
out=$("$TOOL" watch 2>&1)
contains "$out" "🛡️ Sebi hat Rambo Racer gebannt bis [0-9]{2}\\.[0-9]{2}\\. [0-9]{2}:[0-9]{2} – rammt \\(Server 1\\)" "modlog: Bann mit Dauer, Grund und Server"
contains "$out" "🛡️ Sebi hat Troll gebannt dauerhaft \\(Port 99999\\)" "modlog: dauerhafter Bann, unbekannter Port"
contains "$out" "🔇 Spammer wurde wegen Spam für 60 s stummgeschaltet \\(Server 1\\)" "modlog: Spam-Stummschaltung"
contains "$out" "⚠️ Max hat Ana verwarnt – bitte rechts fahren \\(Server 1\\)" "modlog: Verwarnung"
contains "$out" "🎉 Orga startet ein XP-Event: 1,5-fache XP bis [0-9]{2}:[0-9]{2} Uhr – jetzt einsteigen!" "modlog: XP-Event angekuendigt"
contains "$out" "🎉 Orga hat das XP-Event beendet" "modlog: XP-Event beendet"
contains "$out" "🏅 Sebi ist in die Liga Gold aufgestiegen \\(Server 1\\) – Glückwunsch!" "modlog: Liga-Aufstieg an Discord/Telegram"

contains "$out" "🔇 Pöbler wurde wegen Beleidigungen im Chat für 5 min stummgeschaltet \\(Server 1\\)" "modlog: Wortfilter gemeldet"
contains "$out" "🚫 Hopper hat sich zu oft neu verbunden und wird für 2 min abgewiesen \\(Server 1\\)" "modlog: Verbindungs-Spam gemeldet"
contains "$out" "📍 Melder schlägt einen Ort für Aufträge vor: Klinik Nord \\(krankenhaus, Server 1\\) – im Spiel: /ort vorschlaege" "modlog: Ort-Vorschlag gemeldet"
lacks "$out" "Max.*Event|kaputt|Halb" "modlog: Ansage, kaputte und halbe Zeilen nicht gemeldet"
printf ',"server":%s}\n' "$port1" >>"$M"
out=$("$TOOL" watch 2>&1)
contains "$out" "🛡️ Max hat Halb vom Server geworfen \\(Server 1\\)" "modlog: halbe Zeile kommt, sobald sie vollstaendig ist"
# Meilensteine (Level, Kilometer) – abschaltbar mit MILESTONE_NOTIFY=0.
{
    printf '{"action":"level","target":"Ana, die Schnelle","level":25,"at":%s,"server":%s}\n' "$now" "$port1"
    printf '{"action":"neu","target":"Neuling","at":%s,"server":%s}\n' "$now" "$port1"
    printf '{"action":"km","target":"Ana","km":5000,"at":%s,"server":%s}\n' "$now" "$port1"
    printf '{"action":"km","target":"Boese","km":"9e99","at":%s,"server":%s}\n' "$now" "$port1"
} >>"$M"
out=$("$TOOL" watch 2>&1)
contains "$out" "⭐ Ana, die Schnelle hat Level 25 erreicht \\(Server 1\\) – Glückwunsch!" "modlog: Level-Meilenstein"
contains "$out" "👋 Neuling ist zum ersten Mal im BeamNet \\(Server 1\\) – herzlich willkommen!" "modlog: neuer Spieler gemeldet"
contains "$out" "🛣️ Ana hat 5\\.000 km im BeamNet geschafft \\(Server 1\\) – Glückwunsch!" "modlog: Kilometer-Meilenstein"
lacks "$out" "Boese" "modlog: Meilenstein mit unsinnigem Wert nicht gemeldet"
contains "$(cat "$T/beamnet.conf")" "^MILESTONE_NOTIFY=1$" "watch install: Meilensteine standardmaessig an"
sed -i 's/^MILESTONE_NOTIFY=.*/MILESTONE_NOTIFY=0/' "$T/beamnet.conf"
printf '{"action":"level","target":"Leise","level":50,"at":%s,"server":%s}\n' "$now" "$port1" >>"$M"
lacks "$("$TOOL" watch 2>&1)" "Leise" "modlog: MILESTONE_NOTIFY=0 schaltet Meilensteine ab"
sed -i 's/^MILESTONE_NOTIFY=.*/MILESTONE_NOTIFY=1/' "$T/beamnet.conf"
# MODLOG_NOTIFY=0 schaltet nur die Moderation ab, nicht die Erfolge von Spielern.
sed -i 's/^MODLOG_NOTIFY=.*/MODLOG_NOTIFY=0/' "$T/beamnet.conf"
{
    printf '{"action":"level","target":"Laut","level":75,"at":%s,"server":%s}\n' "$now" "$port1"
    printf '{"action":"kick","by":"Max","target":"Stumm","at":%s,"server":%s}\n' "$now" "$port1"
} >>"$M"
out=$("$TOOL" watch 2>&1)
contains "$out" "⭐ Laut hat Level 75 erreicht" "modlog: Meilensteine auch bei MODLOG_NOTIFY=0"
lacks "$out" "Stumm" "modlog: MODLOG_NOTIFY=0 schaltet Moderation ab"
sed -i 's/^MODLOG_NOTIFY=.*/MODLOG_NOTIFY=1/' "$T/beamnet.conf"
lacks "$out" "Rambo|Troll" "modlog: nichts doppelt"
for i in $(seq 1 12); do printf '{"action":"kick","by":"A","target":"K%s","at":%s,"server":%s}\n' "$i" "$now" "$port1"; done >>"$M"
out=$("$TOOL" watch 2>&1)
[[ $(grep -c "vom Server geworfen" <<<"$out") == 10 ]] && pass || fail "modlog: hoechstens 10 je Lauf"
contains "$out" "… und 2 weitere \\(beamnet modlog\\)" "modlog: Rest zusammengefasst"
{ echo '{"action":"kick","by":"Uralt","target":"Geschichte","at":1,"server":1}'
  printf '{"action":"kick","by":"Neu","target":"Datei","at":%s,"server":1}\n' "$(date +%s)"; } >"$M.neu"; mv "$M.neu" "$M"
out=$("$TOOL" watch 2>&1)
contains "$out" "Neu hat Datei vom Server geworfen" "modlog: neue Datei (anderer Inode) von vorn"
lacks "$out" "Uralt" "modlog: neue Datei – alte Geschichte nicht noch einmal (z. B. nach restore)"
python3 -c 'import sys; sys.stdout.write("x" * 300000)' >>"$M"
"$TOOL" watch >/dev/null 2>&1; "$TOOL" watch >/dev/null 2>&1
printf '\n{"action":"kick","by":"Danach","target":"Z","at":%s,"server":1}\n' "$(date +%s)" >>"$M"
contains "$("$TOOL" watch 2>&1; "$TOOL" watch 2>&1)" "Danach hat Z vom Server geworfen" "modlog: Riesenzeile haelt nicht auf"
sed -i 's/^MODLOG_NOTIFY=.*/MODLOG_NOTIFY=0/' "$T/beamnet.conf"
printf '{"action":"kick","by":"Aus","target":"X","at":1,"server":1}\n' >>"$M"
lacks "$("$TOOL" watch 2>&1)" "Aus hat" "modlog: MODLOG_NOTIFY=0 schaltet ab"
sed -i 's/^MODLOG_NOTIFY=.*/MODLOG_NOTIFY=1/' "$T/beamnet.conf"
rm -f "$M" "$T/watch/modlog-pos"

# --- Meldungen aus dem Spiel (watch_reports) --------------------------------------------------------------------------
R="$T/root/shared/beamnet/reports"
mkdir -p "$R"
cp "$T/beamnet.conf" "$T/conf.reports"
sed -i 's|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc|' "$T/beamnet.conf"
now=$(date +%s)
printf '{"at":%s,"port":30814,"server":"BeamNet | Server 1","by":"Petra","target":"Rambo\\nRacer","reason":"rammt @everyone ständig"}' "$now" >"$R/30814-$now-1.json"
printf '{"at":%s,"server":"S","by":"Alt","target":"X","reason":"von vorgestern"}' "$(( now - 2 * 86400 ))" >"$R/30814-1-2.json"
echo '{kaputt' >"$R/30814-$now-3.json"
echo '{"at":1,"secret":"root"}' >"$T/geheim.json"; ln -s "$T/geheim.json" "$R/30814-$now-4.json"
: >"$T/curl.log"
out=$("$TOOL" watch 2>&1)
# shellcheck disable=SC1111   # „…“ gehoeren zum erwarteten Text
contains "$out" "🚩 Meldung auf BeamNet \\| Server 1: Petra meldet Rambo Racer – „rammt @everyone ständig“ \\([0-9]{2}:[0-9]{2} Uhr\\)" "reports: Meldung weitergegeben (ohne Zeilenumbruch)"
contains "$(cat "$T/curl.log")" "Petra meldet" "reports: an Discord"
contains "$(cat "$T/curl.log")" '"allowed_mentions":\{"parse":\[\]\}' "reports: ohne @-Erwaehnungen"
printf '{"at":%s,"server":"S","by":"Phisher","target":"T","reason":"[Admin-Panel](https://evil.example) *klick*"}' "$now" >"$R/30814-$now-7.json"
: >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
contains "$(cat "$T/curl.log")" '\\\\\[Admin-Panel\\\\\]\\\\\(https://evil.example\\\\\) \\\\\*klick' "reports: Discord-Markdown maskiert (kein getarnter Link)"
# Viele lange Meldungen: in Stuecke unter 2000 Zeichen geteilt, nichts verloren.
long=$(printf 'Grund%.0s' $(seq 1 40))
for i in 1 2 3 4 5 6 7 8; do printf '{"at":%s,"server":"S","by":"B%s","target":"T","reason":"%s"}' "$now" "$i" "$long" >"$R/30814-$now-1$i.json"; done
: >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
n=$(grep -c "discord.com/api/webhooks" "$T/curl.log")
(( n >= 2 )) && pass || fail "reports: lange Meldung in mehrere Discord-Nachrichten geteilt (war $n)"
python3 - "$T/curl.log" <<'PY' && pass || fail "reports: jede Discord-Nachricht unter 2000 Zeichen"
import json, re, sys
ok = True
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.search(r"-d (\{.*\}) -K", line)
    if m and "content" in m.group(1):
        ok = ok and len(json.loads(m.group(1))["content"]) <= 2000
sys.exit(0 if ok else 1)
PY
for i in 1 2 3 4 5 6 7 8; do grep -q "B$i meldet" "$T/curl.log" || fail "reports: Meldung B$i fehlt"; done; pass
lacks "$out" "vorgestern|kaputt|secret" "reports: alte, kaputte und Symlink-Dateien nicht gemeldet"
[[ -z $(ls -A "$R") ]] && pass || fail "reports: alle Dateien entfernt"
[[ -f $T/geheim.json && $(cat "$T/geheim.json") == '{"at":1,"secret":"root"}' ]] && pass || fail "reports: Symlink-Ziel unberuehrt"
for i in $(seq 1 12); do printf '{"at":%s,"server":"S","by":"B%s","target":"T","reason":"r"}' "$now" "$i" >"$R/30814-$now-$(printf '%02d' "$i").json"; done
out=$("$TOOL" watch 2>&1)
[[ $(grep -c "🚩" <<<"$out") == 10 && $(ls "$R" | wc -l) == 2 ]] && pass || fail "reports: hoechstens 10 je Lauf, Rest bleibt"
out=$("$TOOL" watch 2>&1)
[[ $(grep -c "🚩" <<<"$out") == 2 && -z $(ls -A "$R") ]] && pass || fail "reports: Rest beim naechsten Lauf"
rm -rf "$R"; ln -s "$T" "$R"
lacks "$("$TOOL" watch 2>&1)" "🚩" "reports: Symlink-Ordner wird ignoriert"
[[ -f $T/geheim.json ]] && pass || fail "reports: Symlink-Ordner – nichts geloescht"
rm -f "$R" "$T/geheim.json"
cp "$T/conf.reports" "$T/beamnet.conf"

# --- Haengende Server (hang_check) -----------------------------------------------------------------------------------
cp "$T/beamnet.conf" "$T/conf.hang"
sed -i 's/^AUTO_RESTART=.*/AUTO_RESTART=1/; s|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=|' "$T/beamnet.conf"
mkdir -p "$T/root/2/Resources/Server/BeamNetCore"; touch "$T/root/2/Resources/Server/BeamNetCore/main.lua"
touch "$T/state/beammp-2.service.active" "$T/state/beammp-2.service.enabled"
rm -f "$T"/watch/restarts-2 "$T"/watch/hang-2 "$T"/watch/maintenance-2 "$T/portdown"
echo up >"$T/watch/state-2"
port2=$(grep -m1 '^Port' "$T/root/2/ServerConfig.toml" | grep -o '[0-9]*' | head -n1)
old=$(( $(date +%s) - 600 ))
hb2() { echo "{\"port\":$port2,\"players\":0,\"max\":8,\"updated\":$1}" >"$T/root/shared/beamnet/servers/$port2.json"; }
hb2 "$old"
date +%s >"$T/watch/upsince-2"
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
lacks "$out" "hängt|meldet sich nicht" "hang: frisch gestarteter Server bekommt Zeit"
echo "$old" >"$T/watch/upsince-2"
out=$("$TOOL" watch 2>&1)
contains "$out" "🟠 Server 2 \(.*\) läuft, aber BeamNetCore meldet sich nicht mehr" "hang: Port antwortet – nur Plugin steht, Meldung"
lacks "$(cat "$T/actions")" "restart beammp-2" "hang: Port antwortet – kein Neustart (Spieler fahren weiter)"
out=$("$TOOL" watch 2>&1)
lacks "$out" "meldet sich nicht" "hang: nur einmal gemeldet"
rm -f "$T/watch/hang-2"; touch "$T/portdown"
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
contains "$out" "🟠 Server 2 \(.*\) hängt: Dienst läuft, aber kein Lebenszeichen und keine Antwort auf Port $port2" "hang: haengender Server gemeldet"
contains "$(cat "$T/actions")" "^restart beammp-2.service$" "hang: mit AUTO_RESTART neu gestartet"
contains "$out" "🟡 Server 2 \(.*\) nach dem Hängen automatisch neu gestartet" "hang: Neustart gemeldet"
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
lacks "$(cat "$T/actions")" "restart beammp-2" "hang: nach dem Neustart wieder Schonfrist"
# Ohne AUTO_RESTART: nur melden.
sed -i 's/^AUTO_RESTART=.*/AUTO_RESTART=0/' "$T/beamnet.conf"
echo "$old" >"$T/watch/upsince-2"; rm -f "$T/watch/hang-2"
: >"$T/actions"
out=$("$TOOL" watch 2>&1)
contains "$out" "hängt" "hang: ohne AUTO_RESTART gemeldet"
lacks "$(cat "$T/actions")" "restart beammp-2" "hang: ohne AUTO_RESTART kein Neustart"
# Frisches Lebenszeichen: alles gut, Marker weg.
hb2 "$(date +%s)"
"$TOOL" watch >/dev/null 2>&1
[[ ! -f $T/watch/hang-2 ]] && pass || fail "hang: frisches Lebenszeichen hebt den Zustand auf"
# Ohne Plugin oder mit HANG_MIN=0: nie.
hb2 "$old"; echo "$old" >"$T/watch/upsince-2"
sed -i 's/^HANG_MIN=.*/HANG_MIN=0/' "$T/beamnet.conf"
lacks "$("$TOOL" watch 2>&1)" "hängt|meldet sich nicht" "hang: HANG_MIN=0 schaltet ab"
sed -i 's/^HANG_MIN=.*/HANG_MIN=3/' "$T/beamnet.conf"
rm -rf "$T/root/2/Resources/Server/BeamNetCore"
lacks "$("$TOOL" watch 2>&1)" "hängt|meldet sich nicht" "hang: ohne BeamNetCore keine Pruefung"
rm -f "$T/portdown" "$T/root/shared/beamnet/servers/$port2.json" "$T"/watch/hang-2
cp "$T/conf.hang" "$T/beamnet.conf"

# --- Telegram und "Wer ist online" ----------------------------------------------------------------------------------
sed -i 's/^TELEGRAM_TOKEN=.*/TELEGRAM_TOKEN=123456:ABCDEFghijklmnop_1234567890/; s/^TELEGRAM_CHAT=.*/TELEGRAM_CHAT=-1001234567890/; s/^NETWORK_REPORT=.*/NETWORK_REPORT=1/' "$T/beamnet.conf"
rm -f "$T"/watch/online-* "$T"/watch/daily-* "$T"/watch/peak*
now=$(date +%s)
echo "{\"name\":\"S1\",\"port\":30814,\"map\":\"gridmap_v2\",\"players\":2,\"max\":8,\"names\":[\"Sebi\",\"Max\\u0007\"],\"updated\":$now}" >"$T/root/shared/beamnet/servers/30814.json"
echo "{\"name\":\"S3\",\"port\":30816,\"map\":\"italy\",\"players\":1,\"max\":8,\"names\":[\"Ana\"],\"updated\":$now}" >"$T/root/shared/beamnet/servers/30816.json"
echo "{\"port\":30815,\"players\":4,\"max\":8,\"names\":[\"Alt\"],\"updated\":$((now - 600))}" >"$T/root/shared/beamnet/servers/30815.json"
: >"$T/curl.log"
out=$(BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
m3=$(sed -n 's|^Map = "/levels/\([^/]*\)/.*|\1|p' "$T/root/3/ServerConfig.toml")   # haengt von der Rotation (Tag) ab
contains "$out" "📊 BeamNet: 3 Spieler · 2 von 6 Servern belegt" "online: Uebersicht mit Gesamtzahl (veraltetes Lebenszeichen zaehlt nicht)"
contains "$out" "Server 1 · gridmap_v2: 2/8 – Max, Sebi$" "online: Spieler/Plaetze und Namen je Server, sortiert, ohne Steuerzeichen"
contains "$out" "Server 3 · $m3: 1/8 – Ana$" "online: zweiter Server"
contains "$out" "Ohne Lebenszeichen: Server 2, 4, 5, 6$" "online: Server ohne aktuelles Lebenszeichen extra"
contains "$out" "🗺️ Maps: gridmap_v2 2/8 \(25 %\) · $m3 1/8 \(13 %\)$" "online: Auslastung je Map, am vollsten zuerst"
contains "$(cat "$T/curl.log")" "https://api.telegram.org/bot123456:ABCDEFghijklmnop_1234567890/sendMessage" "online: an Telegram"
lacks "$(cat "$T/curl.argv")" "ABCDEFghijklmnop" "online: Telegram-Token nie auf der Befehlszeile (ps)"
contains "$(cat "$T/curl.log")" '\{"chat_id":"-1001234567890","text":"📊 BeamNet: 3 Spieler · 2 von 6 Servern belegt\\n   Server 1 · gridmap_v2: 2/8 – Max, Sebi\\n   Server 3 · '"$m3"': 1/8 – Ana\\n   Ohne Lebenszeichen: Server 2, 4, 5, 6\\n   🗺️ Maps: gridmap_v2 2/8 \(25 %\) · '"$m3"' 1/8 \(13 %\)","disable_web_page_preview":true\}' "online: Telegram-JSON (reiner Text)"
contains "$(cat "$T/curl.log")" "https://discord.com/api/webhooks/1/abc" "online: weiterhin an Discord"
: >"$T/curl.log"
echo $(( $(date +%s) - 61 )) >"$T/watch/online-at"
out=$(BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
lacks "$out" "📊 BeamNet" "online: unveraenderte Uebersicht nicht gleich wiederholen"
echo $(( $(date +%s) - 181 )) >"$T/watch/online-at"
out=$(BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
contains "$out" "📊 BeamNet: 3 Spieler" "online: unveraenderte Uebersicht nach dreifachem Abstand wieder"
date +%s >"$T/watch/online-at"
echo "{\"name\":\"S1\",\"port\":30814,\"map\":\"gridmap_v2\",\"players\":1,\"max\":8,\"names\":[\"Sebi\"],\"updated\":$(date +%s)}" >"$T/root/shared/beamnet/servers/30814.json"
out=$(BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
lacks "$out" "📊 BeamNet" "online: Aenderung, aber Abstand noch nicht um"
echo 0 >"$T/watch/online-at"
out=$(BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
contains "$out" "📊 BeamNet: 2 Spieler" "online: nach Abstand und Aenderung erneut"
contains "$out" "Server 1 · gridmap_v2: 1/8 – Sebi$" "online: neue Runde"
# Konten mit Namen, Gaeste nur gezaehlt; volle Server und Maps mit 🔥.
echo "{\"name\":\"S1\",\"port\":30814,\"map\":\"gridmap_v2\",\"players\":7,\"max\":8,\"names\":[\"Sebi\",\"guest123\",\"Max\",\"guest456\",\"Ana\",\"guest789\",\"Ben\"],\"ids\":[\"1\",\"\",\"2\",\"\",\"3\",\"\",\"4\"],\"updated\":$(date +%s)}" >"$T/root/shared/beamnet/servers/30814.json"
echo 0 >"$T/watch/online-at"
out=$(BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
contains "$out" "Server 1 · gridmap_v2: 7/8 🔥 – Ana, Ben, Max, Sebi \+3 Gäste$" "online: Konten mit Namen, Gaeste gezaehlt, voller Server"
lacks "$out" "guest123" "online: keine Gast-Namen"
contains "$out" "🗺️ Maps: gridmap_v2 7/8 \(88 % 🔥\)" "online: volle Map markiert"
lacks "$out" "⭐ Bonus" "online: ohne Bonus-Map keine Markierung"
echo "{\"map\":\"gridmap_v2\",\"factor\":1.5,\"until\":$(( $(date +%s) + 3600 ))}" >"$T/root/shared/beamnet/bonusmap.json"
cp "$T/watch/bonusmap-$(date +%F)" "$T/bm-stamp.keep" 2>/dev/null || : >"$T/bm-stamp.keep"
echo gridmap_v2 >"$T/watch/bonusmap-$(date +%F)"
echo 0 >"$T/watch/online-at"
out=$(BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
contains "$out" "🗺️ Maps: gridmap_v2 7/8 \(88 % 🔥\) ⭐ Bonus" "online: Bonus-Map markiert"
rm -f "$T/root/shared/beamnet/bonusmap.json"
cp "$T/bm-stamp.keep" "$T/watch/bonusmap-$(date +%F)"
# Alle weg: einmal "niemand online", danach Ruhe.
for f in 30814 30816; do echo "{\"port\":$f,\"players\":0,\"max\":8,\"names\":[],\"updated\":$(date +%s)}" >"$T/root/shared/beamnet/servers/$f.json"; done
echo 0 >"$T/watch/online-at"
out=$(BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
contains "$out" "📊 BeamNet: gerade niemand online" "online: leer geworden wird einmal gemeldet"
echo 0 >"$T/watch/online-at"
out=$(BEAMNET_HOUR=12 "$TOOL" watch 2>&1)
lacks "$out" "📊 BeamNet" "online: leer – keine weiteren Meldungen"
echo "{\"name\":\"S1\",\"port\":30814,\"map\":\"gridmap_v2\",\"players\":1,\"max\":8,\"names\":[\"Sebi\"],\"updated\":$(date +%s)}" >"$T/root/shared/beamnet/servers/30814.json"
echo "{\"name\":\"S3\",\"port\":30816,\"map\":\"italy\",\"players\":1,\"max\":8,\"names\":[\"Ana\"],\"updated\":$(date +%s)}" >"$T/root/shared/beamnet/servers/30816.json"
# beamnet players zeigt Namen statt JSON; json liefert weiter die Rohdaten.
out=$("$TOOL" players 2>&1)
contains "$out" "2 Spieler online" "players: Gesamtzahl"
contains "$out" "^Server 1   1/8      gridmap_v2             Sebi$" "players: Namen je Server"
contains "$out" "^Server 2   \?        .*kein Lebenszeichen" "players: ohne Lebenszeichen"
lacks "$out" '"names"' "players: kein rohes JSON"
contains "$("$TOOL" players json 2>&1)" '"names":\["Sebi"\]' "players json: Rohdaten"
# watch status und test mit Telegram.
out=$("$TOOL" watch status 2>&1)
contains "$out" "^Telegram: an$" "watch status: Telegram"
contains "$out" "^Netzwerk-Übersicht: alle 1 Minuten$" "watch status: Netzwerk-Uebersicht"
sed -i 's/^DISCORD_WEBHOOK=.*/DISCORD_WEBHOOK=/' "$T/beamnet.conf"
: >"$T/curl.log"
"$TOOL" watch test >/dev/null 2>&1 && pass || fail "watch test: nur Telegram reicht"
contains "$(cat "$T/curl.log")" "Testnachricht" "watch test: Testnachricht an Telegram"
lacks "$(cat "$T/curl.log")" "discord" "watch test: ohne Webhook nichts an Discord"
# Falscher Token: nichts senden, deutliche Meldung.
sed -i 's/^TELEGRAM_TOKEN=.*/TELEGRAM_TOKEN=kaputt/' "$T/beamnet.conf"
: >"$T/curl.log"
out=$("$TOOL" watch test 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass || fail "watch test: falscher Token meldet Fehler"
contains "$out" "sieht nicht wie ein Bot-Token" "watch test: Hinweis auf falschen Token"
[[ ! -s $T/curl.log ]] && pass || fail "watch test: mit falschem Token wird nichts gesendet"
# Telegram-Befehle: nur aus dem eingetragenen Chat, Antworten per sendMessage, Offset gemerkt.
sed -i 's/^TELEGRAM_TOKEN=.*/TELEGRAM_TOKEN=123456:ABCDEFghijklmnop_1234567890/; s/^TELEGRAM_CHAT=.*/TELEGRAM_CHAT=-1001234567890/; s/^NETWORK_REPORT=.*/NETWORK_REPORT=0/' "$T/beamnet.conf"
sed -i 's|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=|' "$T/beamnet.conf"
# (Index und Rekord schreibt der Waechter im selben Lauf selbst – aus den Spielerdateien bzw. den Lebenszeichen.)
echo '{"id":"9001","name":"Vorn","km":99999,"seconds":3600}' >"$T/root/shared/beamnet/players/9001.json"
cat >"$T/tg-updates.json" <<'JSON'
{"ok":true,"result":[
 {"update_id":10,"message":{"chat":{"id":-1001234567890},"text":"/online"}},
 {"update_id":11,"message":{"chat":{"id":555},"text":"/top"}},
 {"update_id":12,"message":{"chat":{"id":-1001234567890},"text":"/top@BeamNetBot"}},
 {"update_id":13,"message":{"chat":{"id":-1001234567890},"text":"/rekord"}},
 {"update_id":14,"message":{"chat":{"id":-1001234567890},"text":"hallo zusammen"}},
 {"update_id":15,"message":{"chat":{"id":-1001234567890},"text":"/hilfe"}},
 {"update_id":16,"message":{"chat":{"id":-1001234567890},"text":"/server"}},
 {"update_id":17,"message":{"chat":{"id":-1001234567890},"text":"/online@AndererBot"}},
 {"update_id":18,"message":{"chat":{"id":-1001234567890},"text":"/online"}}
]}
JSON
rm -f "$T/watch/telegram-offset" "$T/watch/telegram-commands" "$T/watch/telegram-commands-try"
echo "BeamNetBot" >"$T/watch/telegram-bot"
: >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
log=$(cat "$T/curl.log")
contains "$log" "getUpdates\\?offset=0" "telegram: holt neue Nachrichten"
contains "$log" '"text":"👥 Gerade online: [0-9]+ Spieler' "telegram: /online beantwortet"
contains "$log" '"text":"🏁 Bestenliste \(XP\):\\n1\. Vorn – 1000050 XP · 99999 km"' "telegram: /top aus dem Index"
contains "$log" '"text":"🏆 Rekord: [0-9]+ Spieler gleichzeitig \([0-9.]+\) · heute bisher: [0-9]+"' "telegram: /rekord"
contains "$log" '"text":"BeamNet-Bot: /online · /top · /rekord · /server · /event · /spieler <Name> · /plaetze · /woche · /heute"' "telegram: /hilfe"
contains "$log" '"text":"📊 BeamNet: [0-9]+ Spieler · [0-9]+ von [0-9]+ Servern belegt' "telegram: /server mit Netzwerk-Uebersicht"
[[ $(grep -c "sendMessage" <<<"$log") == 5 ]] && pass || fail "telegram: genau 5 Antworten (fremder Chat, anderer Bot und normaler Text ignoriert)"
[[ $(cat "$T/watch/telegram-offset") == 18 ]] && pass || fail "telegram: Offset gemerkt (der 6. Befehl bleibt für den nächsten Lauf)"
lacks "$log" "getMe" "telegram: Bot-Name nur einmal am Tag abgefragt"
contains "$log" 'setMyCommands' "telegram: Befehlsliste fuer die Vorschlaege hinterlegt"
contains "$log" '"command":"woche","description":"Wochenbeste und Wochenziel"' "telegram: Befehlsliste mit /woche"
: >"$T/curl.log"; "$TOOL" watch >/dev/null 2>&1
contains "$(cat "$T/curl.log")" "getUpdates\\?offset=18" "telegram: naechster Abruf ab dem Offset"
lacks "$(cat "$T/curl.log")" "setMyCommands" "telegram: Befehlsliste nur einmal je Version"
lacks "$(cat "$T/curl.argv")" "ABCDEFghijklmnop" "telegram: Token auch beim Abruf nie auf der Befehlszeile"
# /ansage aus Telegram: nur fuer Konten aus TELEGRAM_ADMINS.
now=$(date +%s)
cat >"$T/tg-updates.json" <<JSON
{"ok":true,"result":[
 {"update_id":30,"message":{"chat":{"id":-1001234567890},"from":{"id":42},"date":$now,"text":"/ansage Heute 20 Uhr Gruppenrennen!\tTab"}},
 {"update_id":31,"message":{"chat":{"id":-1001234567890},"from":{"id":43},"date":$now,"text":"/ansage Fremder Text"}},
 {"update_id":32,"message":{"chat":{"id":-1001234567890},"from":{"id":42,"is_bot":true},"date":$now,"text":"/ansage Bot"}},
 {"update_id":33,"message":{"chat":{"id":-1001234567890},"from":{"id":42},"date":$now,"forward_origin":{"type":"user"},"text":"/ansage Weitergeleitet"}},
 {"update_id":34,"message":{"chat":{"id":-1001234567890},"from":{"id":42},"date":$((now - 3600)),"text":"/ansage Uralt"}}
]}
JSON
sed -i 's/^TELEGRAM_ADMINS=.*/TELEGRAM_ADMINS=42/' "$T/beamnet.conf"
rm -f "$T/watch/telegram-offset" "$T/root/shared/beamnet/announcements.json"
: >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
log=$(cat "$T/curl.log")
contains "$(cat "$T/root/shared/beamnet/announcements.json" 2>/dev/null)" '"text": "Heute 20 Uhr Gruppenrennen! Tab"' "telegram /ansage: Admin schickt eine Ansage an alle Server"
contains "$log" '"text":"📢 Ansage an alle Server: Heute 20 Uhr Gruppenrennen! Tab"' "telegram /ansage: Bestätigung"
contains "$log" '"text":"Nur für Admins' "telegram /ansage: Fremde werden abgewiesen"
lacks "$(cat "$T/root/shared/beamnet/announcements.json" 2>/dev/null)" "Fremder Text|\"Bot\"|Weitergeleitet|Uralt" "telegram /ansage: nur von Admins, nicht von Bots, nicht weitergeleitet, nicht alt"
contains "$(cat "$T/root/shared/beamnet/announcements.json" 2>/dev/null)" '"by": "Telegram 42"' "telegram /ansage: Absender im Protokoll"
# Geplant: /ansage 18:00 Text
cat >"$T/tg-updates.json" <<JSON
{"ok":true,"result":[{"update_id":40,"message":{"chat":{"id":-1001234567890},"from":{"id":42},"date":$now,"text":"/ansage 18:00 Turnier"}},
 {"update_id":41,"message":{"chat":{"id":-1001234567890},"from":{"id":42},"date":$now,"text":"/ansage 18:00"}}]}
JSON
rm -f "$T/watch/telegram-offset" "$T/root/shared/beamnet/announcements.json"; : >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
contains "$(cat "$T/curl.log")" '"text":"📢 Ansage für 18:00 Uhr geplant: Turnier"' "telegram /ansage: mit Uhrzeit geplant"
contains "$(cat "$T/curl.log")" '"text":"Aufruf: /ansage \[HH:MM\] <Text>"' "telegram /ansage: Uhrzeit ohne Text"
contains "$(cat "$T/root/shared/beamnet/announcements.json" 2>/dev/null)" '"text": "Turnier"' "telegram /ansage: Text ohne die Uhrzeit"
# /event aus Telegram: Stand fuer alle, Starten und Beenden nur fuer Admins.
E="$T/root/shared/beamnet/event.json"
rm -f "$E"
cat >"$T/tg-updates.json" <<JSON
{"ok":true,"result":[{"update_id":50,"message":{"chat":{"id":-1001234567890},"from":{"id":43},"date":$now,"text":"/event"}},
 {"update_id":51,"message":{"chat":{"id":-1001234567890},"from":{"id":43},"date":$now,"text":"/event 2 2h"}},
 {"update_id":52,"message":{"chat":{"id":-1001234567890},"from":{"id":42},"date":$now,"text":"/event 9 2h"}},
 {"update_id":53,"message":{"chat":{"id":-1001234567890},"from":{"id":42},"date":$now,"text":"/event 2 2h"}}]}
JSON
rm -f "$T/watch/telegram-offset"; : >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
log=$(cat "$T/curl.log")
contains "$log" '"text":"Gerade läuft kein XP-Event."' "telegram /event: Stand fuer alle"
contains "$log" '"text":"Nur für Admins' "telegram /event: Starten nur fuer Admins"
contains "$log" '"text":"Aufruf: /event <Faktor' "telegram /event: Faktor geprueft"
contains "$log" '"text":"⚡ XP-Event gestartet: 2-fache XP für 120 Minuten auf allen Servern."' "telegram /event: Admin startet"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["factor"]==2 and d["by"]=="Telegram 42"' "$E" && pass || fail "telegram /event: event.json mit Absender"
cat >"$T/tg-updates.json" <<JSON
{"ok":true,"result":[{"update_id":60,"message":{"chat":{"id":-1001234567890},"from":{"id":43},"date":$now,"text":"/event"}},
 {"update_id":61,"message":{"chat":{"id":-1001234567890},"from":{"id":42},"date":$now,"text":"/event stop"}}]}
JSON
rm -f "$T/watch/telegram-offset"; : >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
log=$(cat "$T/curl.log")
contains "$log" '"text":"⚡ XP-Event läuft: 2-fache XP bis [0-9:]+ Uhr \(von Telegram 42\)"' "telegram /event: laufendes Event"
contains "$log" '"text":"XP-Event beendet."' "telegram /event stop"
contains "$("$TOOL" event 2>&1)" "Gerade läuft kein XP-Event" "telegram /event stop: beendet"
echo "{\"map\":\"gridmap_v2\",\"factor\":2,\"until\":$(( $(date +%s) + 3600 ))}" >"$T/root/shared/beamnet/bonusmap.json"
cp "$T/watch/bonusmap-$(date +%F)" "$T/bm-stamp.keep" 2>/dev/null || : >"$T/bm-stamp.keep"
echo fremd >"$T/watch/bonusmap-$(date +%F)"
lacks "$("$TOOL" event 2>&1)" "Bonus-Map" "event: Bonus-Map nur, wenn der Waechter sie gewaehlt hat"
echo gridmap_v2 >"$T/watch/bonusmap-$(date +%F)"
contains "$("$TOOL" event 2>&1)" "🗺️ Bonus-Map heute: gridmap_v2 \(\+100 % XP beim Fahren\)" "event: Bonus-Map im Stand"
echo "{\"map\":\"gridmap_v2\",\"factor\":2,\"until\":$(( $(date +%s) - 1 ))}" >"$T/root/shared/beamnet/bonusmap.json"
lacks "$("$TOOL" event 2>&1)" "Bonus-Map" "event: abgelaufene Bonus-Map nicht"
rm -f "$T/root/shared/beamnet/bonusmap.json"
cp "$T/bm-stamp.keep" "$T/watch/bonusmap-$(date +%F)"
rm -f "$E"
# Flutschutz: veraltete Befehle (Rueckstau) werden nicht beantwortet, hoechstens 3 je Absender und Lauf.
cat >"$T/tg-updates.json" <<JSON
{"ok":true,"result":[{"update_id":90,"message":{"chat":{"id":-1001234567890},"from":{"id":77},"date":$(( now - 600 )),"text":"/online"}},
 {"update_id":91,"message":{"chat":{"id":-1001234567890},"from":{"id":78},"date":$now,"text":"/rekord"}},
 {"update_id":92,"message":{"chat":{"id":-1001234567890},"from":{"id":78},"date":$now,"text":"/rekord"}},
 {"update_id":93,"message":{"chat":{"id":-1001234567890},"from":{"id":78},"date":$now,"text":"/rekord"}},
 {"update_id":94,"message":{"chat":{"id":-1001234567890},"from":{"id":78},"date":$now,"text":"/rekord"}},
 {"update_id":95,"message":{"chat":{"id":-1001234567890},"from":{"id":78},"date":$now,"text":"/rekord"}}]}
JSON
rm -f "$T/watch/telegram-offset"; : >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
log=$(cat "$T/curl.log")
lacks "$log" "Gerade online" "telegram: veraltete Befehle nicht beantwortet"
[[ $(grep -c "🏆 Rekord" <<<"$log") == 3 ]] && pass || fail "telegram: hoechstens 3 Befehle je Absender und Lauf"
[[ $(cat "$T/watch/telegram-offset") == 96 ]] && pass || fail "telegram: uebersprungene Befehle trotzdem abgehakt"
# /plaetze: Auslastung der letzten 30 Tage und Vorschlag der Automatik.
for d in 1 2 3 4 5; do echo "1 gridmap_v2 8 480" >"$T/watch/usage-$(date -d "-$d days" +%Y-%m-%d)"; done
cat >"$T/tg-updates.json" <<JSON
{"ok":true,"result":[{"update_id":80,"message":{"chat":{"id":-1001234567890},"from":{"id":43},"date":$now,"text":"/plaetze"}}]}
JSON
rm -f "$T/watch/telegram-offset"; : >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
contains "$(cat "$T/curl.log")" '"text":"📊 Spielerplätze – letzte 30 Tage:\\nServer 1 · gridmap_v2: 8 Plätze, Spitze 8, [0-9]+ Tage voll → 📈 [0-9]+ Plätze' "telegram /plaetze: Auslastung und Vorschlag"
rm -f "$T/watch/usage-"*
# /heute: Tagesaufgabe aus dem frischesten Lebenszeichen, Bonus-Map (vom Waechter gewaehlt), Wochenziel.
echo "{\"name\":\"S1\",\"port\":30814,\"map\":\"gridmap_v2\",\"players\":1,\"max\":8,\"names\":[\"Sebi\"],\"updated\":$(date +%s),\"challenge\":\"Fahre heute 15 km\"}" >"$T/root/shared/beamnet/servers/30814.json"
echo "{\"name\":\"S2\",\"port\":30815,\"map\":\"italy\",\"players\":0,\"max\":8,\"names\":[],\"updated\":$(( $(date +%s) + 1 )),\"challenge\":\"Gratis-VIP: http://boese.example\"}" >"$T/root/shared/beamnet/servers/30815.json"
echo "{\"map\":\"gridmap_v2\",\"factor\":1.5,\"until\":$(( $(date +%s) + 3600 ))}" >"$T/root/shared/beamnet/bonusmap.json"
cp "$T/watch/bonusmap-$(date +%F)" "$T/bm-stamp.keep" 2>/dev/null || : >"$T/bm-stamp.keep"
echo gridmap_v2 >"$T/watch/bonusmap-$(date +%F)"
cat >"$T/tg-updates.json" <<JSON
{"ok":true,"result":[{"update_id":86,"message":{"chat":{"id":-1001234567890},"from":{"id":43},"date":$now,"text":"/heute"}}]}
JSON
rm -f "$T/watch/telegram-offset"; : >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
log=$(cat "$T/curl.log")
contains "$log" '"text":"☀️ Heute im BeamNet:\\n✅ Tagesaufgabe: Fahre heute 15 km \(/aufgabe im Spiel\)\\n🗺️ Bonus-Map heute: gridmap_v2 \(\+50 % XP beim Fahren\)' "telegram /heute: Tagesaufgabe und Bonus-Map"
lacks "$log" "Gratis-VIP" "telegram /heute: nur Tagesaufgaben in bekannter Form (kein fremder Text)"
rm -f "$T/root/shared/beamnet/servers/30815.json"
rm -f "$T/root/shared/beamnet/bonusmap.json"
cp "$T/bm-stamp.keep" "$T/watch/bonusmap-$(date +%F)"
# /woche: Top 5 der Kalenderwoche aus dem Index und das Wochenziel; alte Wochen zaehlen nicht.
wk=$(python3 -c 'import datetime; y, w, _ = datetime.datetime.now(datetime.timezone.utc).isocalendar(); print("%04d-W%02d" % (y, w))')
echo "{\"id\":\"9101\",\"name\":\"Wochenheld\",\"km\":80,\"week\":\"$wk\",\"weekKm\":42.5}" >"$T/root/shared/beamnet/players/9101.json"
echo "{\"id\":\"9102\",\"name\":\"Zweiter\",\"km\":30,\"week\":\"$wk\",\"weekKm\":7.5}" >"$T/root/shared/beamnet/players/9102.json"
echo '{"id":"9103","name":"Altwoche","km":500,"week":"2000-W01","weekKm":400}' >"$T/root/shared/beamnet/players/9103.json"
echo "{\"week\":\"$wk\",\"goal\":100}" >"$T/root/shared/beamnet/community.json"
cat >"$T/tg-updates.json" <<JSON
{"ok":true,"result":[{"update_id":85,"message":{"chat":{"id":-1001234567890},"from":{"id":43},"date":$now,"text":"/woche"}}]}
JSON
rm -f "$T/watch/telegram-offset"; : >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
log=$(cat "$T/curl.log")
contains "$log" '"text":"📅 KW [0-9]+: [0-9]+ Fahrer, zusammen [0-9]+,[0-9] km\\n1\. Wochenheld – 42,5 km\\n' "telegram /woche: Wochenbeste"
contains "$log" 'Zweiter – 7,5 km' "telegram /woche: zweiter Fahrer"
lacks "$log" "Altwoche" "telegram /woche: alte Wochen zaehlen nicht"
contains "$log" '🎯 Wochenziel für alle: [0-9]+,[0-9] km von 100,0 km \([0-9]+ %\)' "telegram /woche: Wochenziel"
rm -f "$T/root/shared/beamnet/players/910"[123].json "$T/root/shared/beamnet/community.json"
# /spieler <Name>: Werte aus dem Bestenlisten-Index, fuer alle.
cat >"$T/tg-updates.json" <<JSON
{"ok":true,"result":[{"update_id":70,"message":{"chat":{"id":-1001234567890},"from":{"id":43},"date":$now,"text":"/spieler vorn"}},
 {"update_id":71,"message":{"chat":{"id":-1001234567890},"from":{"id":43},"date":$now,"text":"/spieler Gibtsnicht"}},
 {"update_id":72,"message":{"chat":{"id":-1001234567890},"from":{"id":43},"date":$now,"text":"/spieler"}}]}
JSON
rm -f "$T/watch/telegram-offset"; : >"$T/curl.log"
"$TOOL" watch >/dev/null 2>&1
log=$(cat "$T/curl.log")
contains "$log" '"text":"👤 Vorn – Level [0-9]+ · [A-Za-z]+ · 1000050 XP · Platz 1 von [0-9]+\\n🚗 99999 km · 1 h unterwegs' "telegram /spieler: Werte aus dem Index"
contains "$log" '"text":"Keinen Spieler „Gibtsnicht“ gefunden."' "telegram /spieler: unbekannter Name"
contains "$log" '"text":"Aufruf: /spieler <Name>' "telegram /spieler: ohne Name"
sed -i 's/^TELEGRAM_ADMINS=.*/TELEGRAM_ADMINS=/' "$T/beamnet.conf"
rm -f "$T/root/shared/beamnet/announcements.json"
sed -i 's/^TELEGRAM_COMMANDS=.*/TELEGRAM_COMMANDS=0/' "$T/beamnet.conf"
: >"$T/curl.log"; "$TOOL" watch >/dev/null 2>&1
lacks "$(cat "$T/curl.log")" "getUpdates" "telegram: TELEGRAM_COMMANDS=0 schaltet ab"
sed -i 's/^TELEGRAM_COMMANDS=.*/TELEGRAM_COMMANDS=1/' "$T/beamnet.conf"
rm -f "$T/tg-updates.json" "$T/root/shared/beamnet/players/9001.json"
sed -i 's/^TELEGRAM_TOKEN=.*/TELEGRAM_TOKEN=/; s/^TELEGRAM_CHAT=.*/TELEGRAM_CHAT=/; s/^NETWORK_REPORT=.*/NETWORK_REPORT=0/; s|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc|' "$T/beamnet.conf"
contains "$("$TOOL" watch status 2>&1)" "^Netzwerk-Übersicht: aus$" "watch status: Netzwerk-Uebersicht aus"

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
# Lesen als root: Symlinks auf fremde JSON-Dateien (z. B. Zugangsdaten unter /root) werden nie gelesen.
echo '{"id":"7","name":"GEHEIMNIS-ROOT","km":5,"secret":"tok","week":"x","weekKm":1}' >"$victim/creds.json"; chmod 600 "$victim/creds.json"
mkdir -p "$S/players" "$S/servers"
ln -sf "$victim/creds.json" "$S/players/77.json"
"$TOOL" web run >/dev/null 2>&1
lacks "$(cat "$T/web/index.html" "$T/web/api.json")" "GEHEIMNIS-ROOT" "Sicherheit: Statusseite liest keine Symlinks (oeffentlich!)"
rm -f "$S/players/77.json"
cp "$S/bans.json" "$T/bans.keep" 2>/dev/null
ln -sf "$victim/creds.json" "$S/bans.json"
"$TOOL" -y unban irgendwer >/dev/null 2>&1
lacks "$([[ -L $S/bans.json ]] || cat "$S/bans.json" 2>/dev/null)" "tok|GEHEIMNIS" "Sicherheit: unban kopiert keine fremde Datei nach bans.json"
lacks "$("$TOOL" bans 2>&1)" "GEHEIMNIS|tok" "Sicherheit: bans liest keine Symlinks"
rm -f "$S/bans.json"; [[ -f $T/bans.keep ]] && mv "$T/bans.keep" "$S/bans.json"
ln -sf "$victim/creds.json" "$S/config.json"
"$TOOL" admin add Testadmin >/dev/null 2>&1
lacks "$([[ -L $S/config.json ]] || cat "$S/config.json" 2>/dev/null)" "GEHEIMNIS|tok" "Sicherheit: admin kopiert keine fremde Datei nach config.json"
rm -f "$S/config.json"
echo "{\"port\":30814,\"players\":1,\"max\":8,\"names\":[\"GEHEIMNIS-ROOT\"],\"updated\":$(date +%s)}" >"$victim/hb.json"
mv "$S/servers/30814.json" "$T/hb.keep" 2>/dev/null; ln -sf "$victim/hb.json" "$S/servers/30814.json"
lacks "$("$TOOL" players 2>&1)" "GEHEIMNIS" "Sicherheit: Namen aus dem Lebenszeichen nur ohne Symlink"
rm -f "$S/servers/30814.json"; [[ -f $T/hb.keep ]] && mv "$T/hb.keep" "$S/servers/30814.json"
[[ $(stat -c %a "$victim/creds.json") == 600 ]] && pass || fail "Sicherheit: fremde Datei unveraendert"
mv "$S/servers/30814.json" "$T/hb.keep" 2>/dev/null; ln -sf "$victim/creds.json" "$S/servers/30814.json"
lacks "$("$TOOL" players json 2>&1)" "GEHEIMNIS|tok" "Sicherheit: players json folgt keinem Symlink"
rm -f "$S/servers/30814.json"
# Lebenszeichen mit fuehrender Null und Zeit aus der Zukunft: Waechter stuerzt nicht ab, "fuer immer frisch" gibt es nicht.
echo '{"port":30814,"players":08,"max":8,"updated":99999999999}' >"$S/servers/30814.json"
out=$("$REAL_TIMEOUT" 60 "$TOOL" watch 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass || fail "Sicherheit: Lebenszeichen mit 08 bringt den Waechter nicht zum Absturz (rc=$rc)"
lacks "$out" "value too great|Syntaxfehler|syntax error" "Sicherheit: keine Rechenfehler durch Spielerdaten"
echo "{\"port\":30814,\"players\":3,\"max\":8,\"updated\":99999999999}" >"$S/servers/30814.json"
contains "$("$TOOL" players 2>&1)" "^Server 1   \\?" "Sicherheit: Lebenszeichen aus der Zukunft gilt nicht"
# FIFO statt Lebenszeichen: Waechter, Statusseite und players haengen nicht.
rm -f "$S/servers/30814.json"; mkfifo "$S/servers/30814.json"
"$REAL_TIMEOUT" 60 "$TOOL" watch >/dev/null 2>&1; rc=$?
[[ $rc -ne 124 ]] && pass || fail "Sicherheit: Waechter haengt nicht an einer FIFO"
"$REAL_TIMEOUT" 60 "$TOOL" players >/dev/null 2>&1; rc=$?
[[ $rc -ne 124 ]] && pass || fail "Sicherheit: players haengt nicht an einer FIFO"
"$REAL_TIMEOUT" 60 "$TOOL" web run >/dev/null 2>&1; rc=$?
[[ $rc -ne 124 ]] && pass || fail "Sicherheit: Statusseite haengt nicht an einer FIFO"
rm -f "$S/servers/30814.json"; [[ -f $T/hb.keep ]] && mv "$T/hb.keep" "$S/servers/30814.json"
# peak.json mit absurder Zeit: Statusseite wird trotzdem erzeugt.
cp "$S/peak.json" "$T/peak.keep" 2>/dev/null
echo '{"allTime":5,"allTimeAt":1e300,"today":2,"hours":[[1,1e300]]}' >"$S/peak.json"
contains "$("$TOOL" web run 2>&1)" "Statusseite erzeugt" "Sicherheit: peak.json mit absurder Zeit bricht die Statusseite nicht"
rm -f "$S/peak.json"; [[ -f $T/peak.keep ]] && mv "$T/peak.keep" "$S/peak.json"
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
# Hardlink auf eine fremde Datei (bei fs.protected_hardlinks=0 moeglich): safe get liest sie nicht.
ln "$victim/creds.json" "$S/servers/30899.json"
lacks "$("$TOOL" players json 2>&1)" "GEHEIMNIS-ROOT" "Sicherheit: Hardlink im gemeinsamen Ordner wird nicht gelesen"
rm -f "$S/servers/30899.json"
# Zwischenordner als Symlink (Resources/Server -> fremder Ordner): install-core schreibt nicht hindurch.
mkdir -p "$victim/srv/BeamNetCore"
mv "$T/root/2/Resources/Server" "$T/server2.keep"
ln -s "$victim/srv" "$T/root/2/Resources/Server"
"$TOOL" install-core -y >/dev/null 2>&1
[[ ! -e $victim/srv/BeamNetCore/main.lua ]] && pass || fail "Sicherheit: install-core folgt keinem Symlink in einem Zwischenordner"
rm -f "$T/root/2/Resources/Server"; mv "$T/server2.keep" "$T/root/2/Resources/Server"
# Wiederholungstaeter: 3 Vorfaelle in 7 Tagen werden gemeldet (einmal je Woche), alte zaehlen nicht.
now=$(date +%s)
{
    echo "{\"action\":\"melden\",\"by\":\"A\",\"target\":\"Stoerer\",\"targetId\":\"7777\",\"at\":$((now - 3600))}"
    echo "{\"action\":\"melden\",\"by\":\"B\",\"target\":\"Stoerer\",\"targetId\":\"7777\",\"at\":$((now - 7200))}"
    echo "{\"action\":\"filter-mute\",\"target\":\"Stoerer\",\"targetId\":\"7777\",\"at\":$((now - 600))}"
    echo "{\"action\":\"warn\",\"by\":\"Admin\",\"target\":\"Brav\",\"targetId\":\"8888\",\"at\":$((now - 600))}"
    echo "{\"action\":\"kick\",\"by\":\"Admin\",\"target\":\"Brav\",\"targetId\":\"8888\",\"at\":$((now - 9 * 86400))}"
    echo "{\"action\":\"melden\",\"target\":\"Brav\",\"targetId\":\"8888\",\"at\":$((now - 8 * 86400))}"
    for i in 1 2 3; do echo "{\"action\":\"melden\",\"by\":\"Neider\",\"byId\":\"5555\",\"target\":\"Opfer\",\"targetId\":\"6666\",\"at\":$((now - i * 60))}"; done
    for i in 1 2 3; do echo "{\"action\":\"melden\",\"by\":\"X$i\",\"target\":\"Fantasie\",\"at\":$((now - i * 60))}"; done
} >>"$S/modlog.jsonl"
rm -f "$T/watch/repeat-at" "$T/watch/repeat.json"
out=$("$TOOL" watch 2>&1)
contains "$out" "⚠️ Wiederholt aufgefallen: Stoerer – 2× gemeldet · 1× stumm \\(Wortfilter\\) in 7 Tagen" "repeat: Wiederholungstäter gemeldet"
lacks "$out" "aufgefallen: Brav" "repeat: alte Vorfälle zählen nicht"
lacks "$out" "aufgefallen: Opfer" "repeat: ein einzelner Melder reicht nicht"
lacks "$out" "aufgefallen: Fantasie" "repeat: Meldungen ohne Konto zählen nicht"
rm -f "$T/watch/repeat-at"
lacks "$("$TOOL" watch 2>&1)" "aufgefallen: Stoerer" "repeat: nur einmal je Woche"
# Neue Streckenrekorde: erster Lauf merkt sich nur den Stand, danach Meldung bei neuem Rekord und neuer Strecke.
mkdir -p "$S/races"
echo '{"tracks":{"sprint":{"records":[{"name":"Max","time":51.0}]}}}' >"$S/races/italy.json"
rm -f "$T/watch/records.json"
lacks "$("$TOOL" watch 2>&1)" "Streckenrekord" "records: erster Lauf meldet nichts"
echo '{"tracks":{"sprint":{"records":[{"name":"Sebi\u001b[31m","time":49.06},{"name":"Max","time":51.0}]},"neu":{"records":[{"name":"Ana","time":80}]}}}' >"$S/races/italy.json"
out=$("$TOOL" watch 2>&1)
contains "$out" "🏆 Neuer Streckenrekord auf sprint \\(Italy\\): Sebi \\[31m 0:49\\.1 \\(vorher Max 0:51\\.0\\)" "records: neuer Rekord gemeldet (ohne Steuerzeichen)"
contains "$out" "🏁 Erste Zeit auf neu \\(Italy\\): Ana 1:20\\.0 – wer ist schneller\\?" "records: neue Strecke gemeldet"
lacks "$("$TOOL" watch 2>&1)" "Streckenrekord|Erste Zeit" "records: nur einmal"
sed -i 's/^RECORD_NOTIFY=.*/RECORD_NOTIFY=0/' "$T/beamnet.conf"
echo '{"tracks":{"sprint":{"records":[{"name":"Zoe","time":40}]},"neu":{"records":[{"name":"Ana","time":80}]}}}' >"$S/races/italy.json"
lacks "$("$TOOL" watch 2>&1)" "Streckenrekord" "records: RECORD_NOTIFY=0 schaltet ab"
sed -i 's/^RECORD_NOTIFY=.*/RECORD_NOTIFY=1/' "$T/beamnet.conf"
# Viele neue Strecken auf einmal: hoechstens 5 Zeilen (wichtige Meldungen duerfen nicht verdraengt werden).
python3 - "$S/races/italy.json" <<'PY'
import json, sys
json.dump({"tracks": {f"t{i}": {"records": [{"name": "Spam", "time": 10 + i}]} for i in range(40)}}, open(sys.argv[1], "w"))
PY
out=$("$TOOL" watch 2>&1)
[[ $(grep -c "Erste Zeit auf" <<<"$out") == 5 ]] && pass || fail "records: höchstens 5 Zeilen je Lauf"
contains "$out" "… und 35 weitere neue Zeiten" "records: Rest zusammengefasst"
echo '{"tracks":{}}' >"$S/races/italy.json"
# Rotation: doppelte Maps und "all" werden abgelehnt.
contains "$("$TOOL" rotation 5 italy utah italy 2>&1)" "Jede Map nur einmal" "rotation: doppelte Maps abgelehnt"
contains "$("$TOOL" rotation all italy utah 2>&1)" "eine Server-Nummer" "rotation: nur eine Server-Nummer"

# Nicht als root: Aenderungen verweigert.
out=$(FAKE_UID=1000 "$TOOL" restart all 2>&1)
contains "$out" "Bitte als root" "restart verlangt root"

printf '\n%d Prüfungen bestanden, %d fehlgeschlagen\n' "$PASSES" "$FAILS"
[[ $FAILS -eq 0 ]]
