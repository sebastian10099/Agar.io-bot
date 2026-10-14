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
contains "$(ls "$T/root/6")" "ServerConfig.toml.bak-" "set-map sichert vorher"
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
echo "{\"server\":1,\"port\":30814,\"players\":3,\"max\":8,\"updated\":$now}" >"$T/root/shared/beamnet/servers/30814.json"
echo "{\"server\":2,\"port\":30815,\"players\":5,\"max\":8,\"updated\":$((now - 600))}" >"$T/root/shared/beamnet/servers/30815.json"
out=$("$TOOL" status)
contains "$out" "^1 +läuft .* 30814 +3/8 " "Status zeigt Spieler"
contains "$out" "^2 +läuft .* 30815 +\\? " "Status ignoriert veraltete Spielerzahl"

# Plugin-Check im doctor: Server 1 meldet sich frisch, Server 3 nie, Server 2 veraltet.
echo "[LUA] [BeamNetCore] Fehler im Takt: attempt to index a nil value" >>"$T/root/2/Server.log"
out=$("$TOOL" doctor)
contains "$out" "Server 1 .*BeamNetCore aktiv" "doctor: Plugin aktiv"
contains "$out" "Server 2 .*BeamNetCore meldet sich seit 10 min nicht mehr" "doctor: Plugin veraltet"
contains "$out" "Server 3 .*BeamNetCore ist installiert, hat sich aber noch nie gemeldet" "doctor: Plugin nie gemeldet"
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

# Nicht als root: Aenderungen verweigert.
out=$(FAKE_UID=1000 "$TOOL" restart all 2>&1)
contains "$out" "Bitte als root" "restart verlangt root"

printf '\n%d Prüfungen bestanden, %d fehlgeschlagen\n' "$PASSES" "$FAILS"
[[ $FAILS -eq 0 ]]
