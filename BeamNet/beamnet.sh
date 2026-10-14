#!/usr/bin/env bash
# BeamNet – Werkzeug fuer die BeamMP-Server (Status, Diagnose, Reparatur, Maps, Sicherung, Plugin).
#
# Einrichten (einmal, als root in der Web-Konsole):
#   curl -fsSL https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/friendly-goldberg-31l8fp/BeamNet/beamnet.sh \
#     -o /usr/local/bin/beamnet && chmod +x /usr/local/bin/beamnet
# Danach:  beamnet status   ·   beamnet doctor   ·   beamnet hilfe
#
# Alles, was etwas veraendert (stop, restart, fix, set-map, install-core, openclaw pause), fragt vorher nach.
# Mit -y wird ohne Rueckfrage ausgefuehrt.

set -uo pipefail

VERSION="1.1"
ROOT="${BEAMNET_ROOT:-/srv/beammp}"
UNIT_PREFIX="${BEAMNET_UNIT_PREFIX:-beammp-}"
SERVICE_USER="${BEAMNET_USER:-beammp}"
SHARED="${BEAMNET_SHARED:-$ROOT/shared/beamnet}"
BACKUP_DIR="${BEAMNET_BACKUP_DIR:-/root/beamnet-backups}"
AUTH_KEYS="${BEAMNET_AUTH_KEYS:-/root/.ssh/authorized_keys}"
AGENT_USER="${BEAMNET_AGENT_USER:-openclaw}"
WAIT_SECONDS="${BEAMNET_WAIT:-15}"
RAW_BASE="${BEAMNET_RAW:-https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/friendly-goldberg-31l8fp/BeamNet}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Vanilla-Maps (jeder Spieler hat sie ohne Mods). Andere Maps nur mit --force.
KNOWN_MAPS="gridmap_v2 smallgrid west_coast_usa east_coast_usa italy utah jungle_rock_island small_island hirochi_raceway johnson_valley industrial derby automation_test_track"

YES=0
WARNINGS=0
PROBLEMS=0

if [[ -t 1 ]]; then
    GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
fi

ok()    { printf '%s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$YELLOW" "$RESET" "$*"; WARNINGS=$((WARNINGS + 1)); }
bad()   { printf '%s✖%s %s\n' "$RED" "$RESET" "$*"; PROBLEMS=$((PROBLEMS + 1)); }
hint()  { printf '    → %s\n' "$*"; }
title() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
# pad <text> <breite>: fuellt nach Zeichen (nicht Bytes) auf, damit Umlaute und Farben die Spalten nicht verschieben.
# Gezaehlt wird in Bytes ohne UTF-8-Folgebytes – das stimmt unabhaengig von der Spracheinstellung der Konsole.
pad() {
    local LC_ALL=C
    local text=$1 cont n
    cont=${text//[^$'\x80'-$'\xbf']/}
    n=$(( $2 - ${#text} + ${#cont} ))
    (( n < 1 )) && n=1
    printf '%s%*s' "$text" "$n" ""
}
die()   { printf '%sFehler:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

confirm() {
    [[ $YES -eq 1 ]] && return 0
    local answer=""
    read -r -p "$1 [j/N] " answer || return 1
    [[ $answer =~ ^[jJyY]$ ]]
}

need_root() {
    [[ ${BEAMNET_SKIP_ROOT_CHECK:-0} == 1 || $(id -u) -eq 0 ]] || die "Bitte als root ausführen (sudo beamnet $*)."
}

# ---------------------------------------------------------------------------------------------------------------------
# Server, Konfiguration, Prozesse

# Nummern aller Server (Ordner mit ServerConfig.toml), aufsteigend.
servers() {
    local dir name
    for dir in "$ROOT"/*/; do
        name=$(basename "$dir")
        [[ $name =~ ^[0-9]+$ && -f $dir/ServerConfig.toml ]] && echo "$name"
    done | sort -n
}

# cfg <nr> <Schluessel>: Wert aus ServerConfig.toml (ohne Anfuehrungszeichen und Kommentar).
cfg() {
    local file="$ROOT/$1/ServerConfig.toml" line
    line=$(grep -m1 -E "^[[:space:]]*$2[[:space:]]*=" "$file" 2>/dev/null) || return 0
    line=${line#*=}
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ $line == \"* ]]; then
        line=${line#\"}
        line=${line%%\"*}
    else
        line=${line%%#*}
        line="${line%"${line##*[![:space:]]}"}"
    fi
    printf '%s' "$line"
}

map_short() {
    local m=$1
    m=${m#/levels/}
    printf '%s' "${m%%/*}"
}

unit() { printf '%s%s.service' "$UNIT_PREFIX" "$1"; }

unit_exists() { systemctl cat "$(unit "$1")" >/dev/null 2>&1; }
unit_active() { [[ $(systemctl is-active "$(unit "$1")" 2>/dev/null) == active ]]; }
unit_enabled() { [[ $(systemctl is-enabled "$(unit "$1")" 2>/dev/null) == enabled ]]; }
main_pid() { systemctl show -p MainPID --value "$(unit "$1")" 2>/dev/null || echo 0; }

# Alle BeamMP-Server-Prozesse: "pid benutzer arbeitsordner" je Zeile.
procs() {
    if [[ -n ${BEAMNET_FAKE_PROCS:-} ]]; then
        cat "$BEAMNET_FAKE_PROCS"
        return
    fi
    local pid user cwd
    while read -r pid user; do
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd="?"
        echo "$pid $user $cwd"
    done < <(ps -eo pid=,user=,comm= 2>/dev/null | awk '$3 ~ /^BeamMP-Server/ {print $1, $2}')
}

# Prozesse eines Servers, die NICHT von systemd gestartet wurden (z. B. per nohup als root).
strays() {
    local nr=$1 dir="$ROOT/$1" mainpid pid user cwd
    mainpid=$(main_pid "$nr")
    while read -r pid user cwd; do
        [[ -z ${pid:-} ]] && continue
        [[ $cwd == "$dir" && $pid != "$mainpid" ]] && echo "$pid $user"
    done < <(procs)
}

proc_user() {
    local nr=$1 dir="$ROOT/$1" pid user cwd
    while read -r pid user cwd; do
        [[ $cwd == "$dir" ]] && { echo "$user"; return; }
    done < <(procs)
}

# Spielerzahl aus dem Status, den das Plugin BeamNetCore alle 15 s schreibt ("?" ohne Plugin oder veraltet).
players_of() {
    local file="$SHARED/servers/$1.json" players max updated now
    [[ -f $file ]] || { echo "?"; return; }
    players=$(grep -o '"players"[[:space:]]*:[[:space:]]*[0-9]*' "$file" | grep -o '[0-9]*$')
    max=$(grep -o '"max"[[:space:]]*:[[:space:]]*[0-9]*' "$file" | grep -o '[0-9]*$')
    updated=$(grep -o '"updated"[[:space:]]*:[[:space:]]*[0-9]*' "$file" | grep -o '[0-9]*$')
    now=$(date +%s)
    if [[ -z $updated || $((now - updated)) -gt 90 ]]; then echo "?"; return; fi
    echo "${players:-0}/${max:-?}"
}

targets() {
    if [[ $# -eq 0 || ${1:-} == all || ${1:-} == alle ]]; then
        servers
        return
    fi
    local a
    for a in "$@"; do
        [[ -f $ROOT/$a/ServerConfig.toml ]] || die "Server $a gibt es nicht (vorhanden: $(servers | tr '\n' ' '))."
        echo "$a"
    done
}

# ---------------------------------------------------------------------------------------------------------------------
# Befehle

cmd_status() {
    local list nr state enabled process user port map players name
    list=$(servers)
    [[ -n $list ]] || die "Keine Server unter $ROOT gefunden (Ordner mit ServerConfig.toml)."
    printf '%s%s%s%s%s%s%s%s%s%s\n' "$BOLD" "$(pad Nr 4)" "$(pad Dienst 8)" "$(pad Autostart 10)" "$(pad Prozess 18)" \
        "$(pad Port 7)" "$(pad Spieler 9)" "$(pad Map 24)" "Name" "$RESET"
    for nr in $list; do
        if unit_active "$nr"; then state="$GREEN$(pad läuft 8)$RESET"; else state="$RED$(pad aus 8)$RESET"; fi
        if unit_enabled "$nr"; then enabled="an"; else enabled="aus"; fi
        user=$(proc_user "$nr")
        if [[ -n $(strays "$nr") ]]; then
            if [[ $user == root ]]; then process="$RED$(pad "root/nohup!" 18)$RESET"; else process="$RED$(pad "ohne systemd!" 18)$RESET"; fi
        elif [[ -n $user ]]; then
            process=$(pad "systemd ($user)" 18)
        else
            process=$(pad "–" 18)
        fi
        port=$(cfg "$nr" Port)
        map=$(map_short "$(cfg "$nr" Map)")
        players=$(players_of "$port")
        name=$(cfg "$nr" Name)
        printf '%s%s%s%s%s%s%s%s\n' "$(pad "$nr" 4)" "$state" "$(pad "$enabled" 10)" "$process" "$(pad "$port" 7)" \
            "$(pad "$players" 9)" "$(pad "$map" 24)" "$name"
    done
    [[ -d $SHARED/servers ]] || printf '\nSpielerzahlen erscheinen, sobald das Plugin BeamNetCore läuft (beamnet install-core).\n'
}

cmd_doctor() {
    local list nr port map name count stray user owner seen_ports="" seen_maps="" dup
    title "BeamNet-Diagnose $(date '+%d.%m.%Y %H:%M') · Werkzeug $VERSION"
    if [[ $(id -u) -eq 0 ]]; then ok "Läuft als root"; else warn "Nicht als root – manche Prüfungen sind unvollständig (sudo beamnet doctor)."; fi

    list=$(servers)
    count=$(wc -w <<<"$list")
    if [[ $count -eq 0 ]]; then bad "Keine Server unter $ROOT gefunden."; summary; return; fi
    ok "$count Server unter $ROOT"

    title "Server"
    for nr in $list; do
        port=$(cfg "$nr" Port)
        map=$(map_short "$(cfg "$nr" Map)")
        name="Server $nr (Port $port, $map)"
        if ! unit_exists "$nr"; then
            bad "$name: kein systemd-Dienst $(unit "$nr")"
            hint "Dienst anlegen (Vorlage: /etc/systemd/system/$(unit 1)), dann: systemctl daemon-reload"
            continue
        fi
        stray=$(strays "$nr")
        if [[ -n $stray ]]; then
            user=$(awk '{print $2}' <<<"$stray" | sort -u | tr '\n' ' ')
            bad "$name: läuft außerhalb von systemd (Prozess $(awk '{print $1}' <<<"$stray" | tr '\n' ' ')als ${user% })"
            hint "beamnet fix   (beendet den wilden Prozess und startet sauber über systemd)"
        fi
        if unit_active "$nr"; then
            ok "$name läuft"
        else
            bad "$name ist aus"
            hint "beamnet start $nr   – geht er sofort wieder aus: beamnet logs $nr"
        fi
        unit_enabled "$nr" || { warn "$name startet nach einem Neustart nicht automatisch"; hint "systemctl enable $(unit "$nr")"; }
        owner=$(find "$ROOT/$nr" ! -user "$SERVICE_USER" -print -quit 2>/dev/null)
        if [[ -n $owner ]]; then
            warn "$name: Dateien gehören nicht $SERVICE_USER (z. B. ${owner#"$ROOT"/}) – der Dienst kann daran scheitern"
            hint "beamnet fix   (setzt die Rechte zurück)"
        fi
        if [[ -z $(cfg "$nr" AuthKey) ]]; then
            bad "$name: kein AuthKey – der Server erscheint nicht in der Serverliste"
            hint "AuthKey von https://keymaster.beammp.com in $ROOT/$nr/ServerConfig.toml eintragen"
        fi
        check_core "$nr" "$port" "$name"
        if [[ " $seen_ports " == *" $port "* ]]; then bad "$name: Port $port ist doppelt vergeben"; fi
        seen_ports+=" $port"
        seen_maps+=" $map"
        if [[ $(id -u) -eq 0 ]] && command -v ss >/dev/null && unit_active "$nr"; then
            ss -tln 2>/dev/null | grep -q ":$port " || warn "$name: Dienst läuft, aber Port $port ist nicht offen (startet noch oder hängt)"
        fi
    done
    dup=$(tr ' ' '\n' <<<"$seen_maps" | grep -v '^$' | sort | uniq -d | tr '\n' ' ')
    [[ -n $dup ]] && warn "Mehrere Server mit derselben Map: $dup" && hint "beamnet maps   ·   beamnet set-map <nr> <map>"

    title "Andere Programme, die an den Servern drehen"
    check_agent
    check_cron

    title "SSH-Zugang"
    check_keys

    title "System"
    check_system

    summary
}

# Laeuft BeamNetCore auf diesem Server? (nur wenn installiert und der Server laeuft)
check_core() {
    local nr=$1 port=$2 name=$3 updated now err
    [[ -f $ROOT/$nr/Resources/Server/BeamNetCore/main.lua ]] || return 0
    unit_active "$nr" || return 0
    updated=$(grep -o '"updated"[[:space:]]*:[[:space:]]*[0-9]*' "$SHARED/servers/$port.json" 2>/dev/null | grep -o '[0-9]*$')
    now=$(date +%s)
    if [[ -n $updated && $((now - updated)) -le 90 ]]; then
        ok "$name: BeamNetCore aktiv"
    elif [[ -n $updated ]]; then
        warn "$name: BeamNetCore meldet sich seit $(( (now - updated) / 60 )) min nicht mehr"
        hint "beamnet logs $nr   (steht dort ein Fehler von BeamNetCore?)"
    else
        warn "$name: BeamNetCore ist installiert, hat sich aber noch nie gemeldet"
        hint "Erst nach einem Neustart aktiv: beamnet restart $nr"
    fi
    err=$(tail -n 400 "$ROOT/$nr/Server.log" 2>/dev/null | grep -F "[BeamNetCore] Fehler" | tail -n 1)
    [[ -n $err ]] && warn "$name: Fehlermeldung von BeamNetCore: ${err:0:160}"
    return 0
}

check_agent() {
    local pids lines
    if ! id "$AGENT_USER" >/dev/null 2>&1; then
        ok "Kein Benutzer $AGENT_USER (kein OpenClaw-Agent)"
        return
    fi
    pids=$(pgrep -u "$AGENT_USER" -f openclaw 2>/dev/null | paste -sd' ' -)
    if [[ -n $pids ]]; then
        warn "OpenClaw-Agent läuft (Benutzer $AGENT_USER, Prozess $pids)"
    else
        ok "OpenClaw-Agent läuft nicht"
    fi
    lines=$(journalctl --since "24 hours ago" --no-pager 2>/dev/null | grep -E "$AGENT_USER : .*COMMAND=.*(beammp|BeamMP)" | grep -E "stop|kill|restart|disable" | tail -n 5)
    if [[ -n $lines ]]; then
        bad "OpenClaw hat in den letzten 24 h BeamMP-Server gestoppt oder beendet:"
        sed -E 's/^.*COMMAND=/      /' <<<"$lines"
        hint "Solange er das tut, gehen Server immer wieder aus. Anhalten: beamnet openclaw pause"
    fi
    if grep -rqs "$AGENT_USER" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
        warn "$AGENT_USER hat sudo-Rechte (Eintrag in /etc/sudoers.d) – damit kann er alles als root"
    fi
}

check_cron() {
    local lines
    lines=$( { crontab -l -u root 2>/dev/null; cat /etc/cron.d/* 2>/dev/null; } | grep -v '^[[:space:]]*#' | grep -iE "beammp|beamnet|auto_install" )
    if [[ -n $lines ]]; then
        warn "Zeitgesteuerte Aufgaben (cron), die BeamMP betreffen:"
        sed 's/^/      /' <<<"$lines"
        hint "Prüfen, was sie tun – z. B. auto_install.py läuft als root und kann Dateien überschreiben"
    else
        ok "Keine cron-Aufgaben, die BeamMP betreffen"
    fi
}

check_keys() {
    local count modified age
    if [[ ! -f $AUTH_KEYS ]]; then
        warn "$AUTH_KEYS fehlt – Anmeldung per SSH-Schlüssel ist nicht möglich"
        return
    fi
    count=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$AUTH_KEYS" 2>/dev/null)
    modified=$(stat -c %Y "$AUTH_KEYS" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - modified ))
    ok "$count Schlüssel in $AUTH_KEYS (zuletzt geändert $(date -d "@$modified" '+%d.%m.%Y %H:%M' 2>/dev/null || echo "?"))"
    if command -v ssh-keygen >/dev/null; then
        ssh-keygen -lf "$AUTH_KEYS" 2>/dev/null | sed 's/^/      /'
    fi
    if [[ $age -lt 86400 ]]; then
        warn "Die Schlüsseldatei wurde in den letzten 24 h geändert – war das gewollt?"
        hint "Im Juli verschwand ein frisch eingetragener Schlüssel nach wenigen Minuten wieder."
    fi
}

check_system() {
    local free_kb mem
    free_kb=$(df -Pk "$ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n $free_kb ]]; then
        if [[ $free_kb -lt 1048576 ]]; then bad "Weniger als 1 GB frei auf der Platte"; else ok "$((free_kb / 1048576)) GB frei auf der Platte"; fi
    fi
    if command -v free >/dev/null; then
        mem=$(free -m | awk '/^Mem:/ {print $7}')
        [[ -n $mem ]] && { if [[ $mem -lt 512 ]]; then warn "Nur $mem MB Arbeitsspeicher frei"; else ok "$mem MB Arbeitsspeicher frei"; fi; }
    fi
}

summary() {
    printf '\n'
    if [[ $PROBLEMS -eq 0 && $WARNINGS -eq 0 ]]; then
        printf '%sAlles in Ordnung.%s\n' "$GREEN" "$RESET"
    else
        printf '%s%d Problem(e)%s, %s%d Hinweis(e)%s. Reparieren: %sbeamnet fix%s\n' "$RED" "$PROBLEMS" "$RESET" "$YELLOW" "$WARNINGS" "$RESET" "$BOLD" "$RESET"
    fi
}

cmd_start() {
    need_root start
    local list nr
    list=$(targets "$@") || exit 1
    for nr in $list; do
        systemctl enable "$(unit "$nr")" >/dev/null 2>&1
        if systemctl start "$(unit "$nr")"; then echo "Server $nr gestartet"; else echo "Server $nr: Start fehlgeschlagen (beamnet logs $nr)"; fi
    done
    # shellcheck disable=SC2086
    verify_running $list
}

cmd_stop() {
    need_root stop
    local list nr
    list=$(targets "$@") || exit 1
    confirm "Server $(tr '\n' ' ' <<<"$list")stoppen? Spieler darauf fliegen raus." || { echo "Abgebrochen."; return 1; }
    for nr in $list; do systemctl stop "$(unit "$nr")" && echo "Server $nr gestoppt"; done
}

cmd_restart() {
    need_root restart
    local list nr
    list=$(targets "$@") || exit 1
    confirm "Server $(tr '\n' ' ' <<<"$list")neu starten? Spieler darauf fliegen kurz raus." || { echo "Abgebrochen."; return 1; }
    for nr in $list; do systemctl restart "$(unit "$nr")" && echo "Server $nr neu gestartet"; done
    # shellcheck disable=SC2086
    verify_running $list
}

# Prueft nach einer Wartezeit, ob die Server noch laufen – und wer sie gegebenenfalls gestoppt hat.
verify_running() {
    [[ $# -gt 0 ]] || return 0
    echo "Warte $WAIT_SECONDS s und prüfe, ob alle laufen …"
    sleep "$WAIT_SECONDS"
    local nr down=""
    for nr in "$@"; do unit_active "$nr" || down+="$nr "; done
    if [[ -z $down ]]; then
        ok "Alle laufen."
        return 0
    fi
    bad "Wieder aus: Server $down"
    local culprit
    culprit=$(journalctl --since "-2min" --no-pager 2>/dev/null | grep -E "COMMAND=.*(systemctl stop|pkill|kill).*(beammp|BeamMP)" | tail -n 3)
    if [[ -n $culprit ]]; then
        echo "Gestoppt von:"
        sed -E 's/^.*sudo\[[0-9]+\]: */      /' <<<"$culprit"
        hint "Erst den Verursacher anhalten (z. B. beamnet openclaw pause), dann erneut starten."
    else
        hint "Ursache im Protokoll: beamnet logs ${down%% *}"
    fi
    return 1
}

cmd_fix() {
    need_root fix
    local list nr stray pid owner started=""
    list=$(servers)
    [[ -n $list ]] || die "Keine Server gefunden."
    title "1. Wilde Prozesse (außerhalb von systemd)"
    for nr in $list; do
        stray=$(strays "$nr")
        [[ -z $stray ]] && continue
        echo "Server $nr: $(tr '\n' ' ' <<<"$stray")"
        if confirm "  Beenden und später sauber über systemd starten?"; then
            for pid in $(awk '{print $1}' <<<"$stray"); do kill "$pid" 2>/dev/null; done
            sleep 3
            for pid in $(awk '{print $1}' <<<"$stray"); do kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null; done
            ok "  beendet"
        fi
    done
    title "2. Dateirechte"
    for nr in $list; do
        owner=$(find "$ROOT/$nr" ! -user "$SERVICE_USER" -print -quit 2>/dev/null)
        [[ -z $owner ]] && continue
        if confirm "Server $nr: Dateien gehören nicht $SERVICE_USER. Rechte zurücksetzen?"; then
            chown -hR "$SERVICE_USER:$SERVICE_USER" "$ROOT/$nr" && ok "  Rechte gesetzt"
        fi
    done
    title "3. Autostart und Start"
    for nr in $list; do
        unit_exists "$nr" || { bad "Server $nr hat keinen Dienst $(unit "$nr") – übersprungen"; continue; }
        unit_enabled "$nr" || { systemctl enable "$(unit "$nr")" >/dev/null 2>&1 && ok "Server $nr: Autostart an"; }
        if ! unit_active "$nr"; then
            systemctl start "$(unit "$nr")" && started+="$nr "
        fi
    done
    if [[ -n $started ]]; then
        echo "Gestartet: $started"
        # shellcheck disable=SC2086
        verify_running $started
    else
        ok "Alle Server liefen bereits."
    fi
}

cmd_maps() {
    local nr
    printf '%s%-4s %-6s %s%s\n' "$BOLD" "Nr" "Port" "Map" "$RESET"
    for nr in $(servers); do printf '%-4s %-6s %s\n' "$nr" "$(cfg "$nr" Port)" "$(map_short "$(cfg "$nr" Map)")"; done
    printf '\nVanilla-Maps (ohne Mods): %s\n' "$KNOWN_MAPS"
    printf 'Ändern: beamnet set-map <nr> <map>\n'
}

cmd_set_map() {
    need_root set-map
    local force=0
    [[ ${1:-} == --force ]] && { force=1; shift; }
    [[ $# -eq 2 ]] || die "Aufruf: beamnet set-map <nr> <map>   (z. B. beamnet set-map 5 utah)"
    local nr=$1 map=$2 file
    targets "$nr" >/dev/null
    [[ $map =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]] || die "Ungültiger Map-Name: $map"
    if [[ $force -eq 0 && " $KNOWN_MAPS " != *" $map "* ]]; then
        die "$map ist keine bekannte Vanilla-Map. Für Mod-Maps: beamnet set-map --force $nr $map"
    fi
    file="$ROOT/$nr/ServerConfig.toml"
    cp -p "$file" "$file.bak-$(date +%Y%m%d-%H%M%S)"
    if grep -qE '^[[:space:]]*Map[[:space:]]*=' "$file"; then
        sed -i -E "s|^([[:space:]]*)Map[[:space:]]*=.*|\\1Map = \"/levels/$map/info.json\"|" "$file"
    else
        die "In $file steht keine Map-Zeile."
    fi
    ok "Server $nr: Map = $map (Sicherung der alten Konfiguration daneben)"
    echo "BeamMP liest die Map nur beim Start."
    if confirm "Server $nr jetzt neu starten?"; then
        systemctl restart "$(unit "$nr")" && verify_running "$nr"
    fi
}

cmd_backup() {
    need_root backup
    local ts file nr items=() units=()
    ts=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    file="$BACKUP_DIR/beamnet-$ts.tgz"
    for nr in $(servers); do
        items+=("$nr/ServerConfig.toml")
        [[ -d $ROOT/$nr/Resources/Server ]] && items+=("$nr/Resources/Server")
        [[ -f /etc/systemd/system/$(unit "$nr") ]] && units+=("$(unit "$nr")")
    done
    [[ -d $SHARED ]] && items+=("${SHARED#"$ROOT"/}")
    [[ ${#items[@]} -gt 0 ]] || die "Nichts zu sichern."
    if [[ ${#units[@]} -gt 0 ]]; then
        tar -czf "$file" -C "$ROOT" "${items[@]}" -C /etc/systemd/system "${units[@]}" || die "Sicherung fehlgeschlagen"
    else
        tar -czf "$file" -C "$ROOT" "${items[@]}" || die "Sicherung fehlgeschlagen"
    fi
    chmod 600 "$file"
    ok "Gesichert: $file ($(du -h "$file" | cut -f1))"
    echo "Enthält die AuthKeys – nicht weitergeben."
    # Nur die 20 neuesten behalten.
    find "$BACKUP_DIR" -maxdepth 1 -name 'beamnet-*.tgz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +21 | cut -d' ' -f2- | xargs -r rm -f
}

cmd_logs() {
    [[ $# -ge 1 ]] || die "Aufruf: beamnet logs <nr> [zeilen]"
    local nr=$1 lines=${2:-60}
    targets "$nr" >/dev/null
    [[ $lines =~ ^[0-9]+$ ]] || die "Zeilenzahl muss eine Zahl sein"
    if [[ -f $ROOT/$nr/Server.log ]]; then
        tail -n "$lines" "$ROOT/$nr/Server.log"
    else
        journalctl -u "$(unit "$nr")" -n "$lines" --no-pager
    fi
}

cmd_plugins() {
    local nr dir names off
    for nr in $(servers); do
        dir="$ROOT/$nr/Resources/Server"
        names=$(find "$dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -printf '%f ' 2>/dev/null)
        off=$(find "$ROOT/$nr/Resources/Server.disabled" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)
        printf 'Server %-3s %s%s\n' "$nr" "${names:-(keine)}" "${off:+  · abgeschaltet: $off}"
    done
}

# Plugin auf allen Servern ab- oder wieder einschalten. Abgeschaltete Plugins liegen in Resources/Server.disabled,
# von dort laedt BeamMP nichts. Es wird nichts geloescht.
cmd_plugin_toggle() {
    need_root "plugin-$1"
    local action=$1 name=${2:-} nr from to moved=0
    [[ $name =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]] || die "Aufruf: beamnet plugin-$action <name>   (Namen zeigt: beamnet plugins)"
    if [[ $action == disable ]]; then from="Server"; to="Server.disabled"; else from="Server.disabled"; to="Server"; fi
    confirm "Plugin $name auf allen Servern $([[ $action == disable ]] && echo ab || echo ein)schalten?" || { echo "Abgebrochen."; return 1; }
    for nr in $(servers); do
        [[ -e $ROOT/$nr/Resources/$from/$name ]] || continue
        if [[ -e $ROOT/$nr/Resources/$to/$name ]]; then
            warn "Server $nr: $to/$name gibt es schon – übersprungen"
            continue
        fi
        mkdir -p "$ROOT/$nr/Resources/$to"
        mv "$ROOT/$nr/Resources/$from/$name" "$ROOT/$nr/Resources/$to/$name" && moved=$((moved + 1))
    done
    if [[ $moved -eq 0 ]]; then
        echo "Plugin $name wurde auf keinem Server gefunden (beamnet plugins)."
        return 1
    fi
    ok "Plugin $name auf $moved Server(n) $([[ $action == disable ]] && echo abgeschaltet || echo eingeschaltet)."
    echo "Wirksam nach einem Neustart: beamnet restart all"
}

cmd_players() {
    local file
    if [[ ! -d $SHARED/servers ]]; then
        echo "Noch keine Daten – das Plugin BeamNetCore ist nicht installiert (beamnet install-core)."
        return
    fi
    for file in "$SHARED"/servers/*.json; do
        [[ -f $file ]] || continue
        printf '%s\n' "$(cat "$file")"
    done
}

# Holt das Plugin aus dem Ordner neben diesem Skript oder von GitHub.
core_source() {
    local local_file="$SCRIPT_DIR/server/BeamNetCore/main.lua" tmp
    if [[ -f $local_file ]]; then
        echo "$local_file"
        return
    fi
    tmp=$(mktemp)
    curl -fsSL "$RAW_BASE/server/BeamNetCore/main.lua" -o "$tmp" || { rm -f "$tmp"; die "Plugin konnte nicht geladen werden ($RAW_BASE)"; }
    echo "$tmp"
}

cmd_install_core() {
    need_root install-core
    local src nr dest list
    src=$(core_source)
    grep -q 'BeamNetCore' "$src" || die "$src ist kein BeamNetCore-Plugin"
    list=$(servers)
    confirm "BeamNetCore auf allen Servern ($(tr '\n' ' ' <<<"$list"))installieren?" || { echo "Abgebrochen."; return 1; }
    mkdir -p "$SHARED/players" "$SHARED/servers" "$SHARED/races"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$SHARED"
    chmod 775 "$SHARED" "$SHARED/players" "$SHARED/servers" "$SHARED/races"
    for nr in $list; do
        dest="$ROOT/$nr/Resources/Server/BeamNetCore"
        mkdir -p "$dest"
        [[ -f $dest/main.lua ]] && cp -p "$dest/main.lua" "$dest/main.lua.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$src" "$dest/main.lua"
        chown -R "$SERVICE_USER:$SERVICE_USER" "$ROOT/$nr/Resources/Server/BeamNetCore"
        ok "Server $nr: BeamNetCore installiert"
    done
    echo "Gemeinsame Daten: $SHARED"
    echo "Aktiv nach einem Neustart der Server: beamnet restart all"
}

cmd_openclaw() {
    local action=${1:-status} pids
    if ! id "$AGENT_USER" >/dev/null 2>&1; then
        echo "Kein Benutzer $AGENT_USER – kein OpenClaw auf diesem Server."
        return
    fi
    pids=$(pgrep -u "$AGENT_USER" -f openclaw 2>/dev/null | paste -sd' ' -)
    case $action in
        status)
            if [[ -n $pids ]]; then
                ps -o pid,stat,etime,args -p "${pids// /,}" 2>/dev/null | sed 's/^/  /'
                echo "(Status T = angehalten)"
            else
                echo "OpenClaw läuft nicht."
            fi
            echo "Letzte Befehle von $AGENT_USER als root:"
            journalctl --since "24 hours ago" --no-pager 2>/dev/null | grep "$AGENT_USER : " | tail -n 10 | sed -E 's/^.*COMMAND=/  /'
            ;;
        pause)
            need_root openclaw
            [[ -n $pids ]] || { echo "OpenClaw läuft nicht."; return; }
            confirm "OpenClaw anhalten (einfrieren, nichts wird gelöscht)? Fortsetzen jederzeit mit: beamnet openclaw resume" || return 1
            # shellcheck disable=SC2086
            kill -STOP $pids && ok "OpenClaw angehalten (Prozess $pids). Er kann jetzt keine Server mehr stoppen."
            ;;
        resume)
            need_root openclaw
            [[ -n $pids ]] || { echo "OpenClaw läuft nicht."; return; }
            # shellcheck disable=SC2086
            kill -CONT $pids && ok "OpenClaw läuft wieder (Prozess $pids)."
            ;;
        *) die "Aufruf: beamnet openclaw status|pause|resume" ;;
    esac
}

# Entfernt IP-Adressen und AuthKeys, damit der Bericht gefahrlos geteilt werden kann.
sanitize() {
    sed -E -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/x.x.x.x/g' -e 's/(AuthKey[[:space:]]*=[[:space:]]*).*/\1***/I'
}

# Ein Bericht zum Hineinkopieren in den Chat: Status, Diagnose, Plugins, auffaellige Protokollzeilen.
cmd_report() {
    GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
    local nr log lines
    {
        printf '=== BeamNet-Bericht %s · Werkzeug %s ===\n\n' "$(date '+%d.%m.%Y %H:%M')" "$VERSION"
        echo "=== Status ==="
        cmd_status
        cmd_doctor
        printf '\n=== Plugins ===\n'
        cmd_plugins
        printf '\n=== Auffällige Protokollzeilen (je Server höchstens 5) ===\n'
        for nr in $(servers); do
            log="$ROOT/$nr/Server.log"
            [[ -f $log ]] || continue
            lines=$(tail -n 400 "$log" | grep -iE "error|fehler|exception|failed|crash" | tail -n 5)
            [[ -n $lines ]] && { echo "Server $nr:"; sed 's/^/  /' <<<"$lines"; }
        done
        printf '\n=== System ===\n'
        uname -sr 2>/dev/null
        uptime 2>/dev/null
    } 2>&1 | sanitize
    printf '\n(IP-Adressen und AuthKeys sind unkenntlich gemacht.)\n'
}

cmd_self_update() {
    need_root self-update
    local target tmp
    target=$(readlink -f "${BASH_SOURCE[0]}")
    tmp=$(mktemp)
    curl -fsSL "$RAW_BASE/beamnet.sh" -o "$tmp" || { rm -f "$tmp"; die "Download fehlgeschlagen"; }
    bash -n "$tmp" || { rm -f "$tmp"; die "Heruntergeladene Datei ist fehlerhaft"; }
    install -m 755 "$tmp" "$target" && rm -f "$tmp"
    ok "Aktualisiert: $target (jetzt Version $(grep -m1 '^VERSION=' "$target" | cut -d'"' -f2))"
}

cmd_help() {
    cat <<EOF
${BOLD}BeamNet $VERSION${RESET} – Werkzeug für die BeamMP-Server unter $ROOT

  beamnet status                 Übersicht: läuft?, Autostart, Prozess, Port, Spieler, Map
  beamnet doctor                 Diagnose mit Erklärung und Lösung je Problem
  beamnet report                 Bericht zum Teilen (Status, Diagnose, Plugins, Fehlerzeilen; ohne IPs und AuthKeys)
  beamnet fix                    Repariert: wilde root-Prozesse, Dateirechte, Autostart, Start
  beamnet start|stop|restart [nr …|all]
  beamnet maps                   Maps aller Server und verfügbare Vanilla-Maps
  beamnet set-map <nr> <map>     Map ändern (sichert die Konfiguration, fragt vor dem Neustart)
  beamnet logs <nr> [zeilen]     Letzte Zeilen des Server-Protokolls
  beamnet plugins                Installierte Server-Plugins je Server
  beamnet plugin-disable <name>  Plugin auf allen Servern abschalten (verschiebt nach Server.disabled)
  beamnet plugin-enable <name>   … und wieder einschalten
  beamnet players                Spieler je Server (mit Plugin BeamNetCore)
  beamnet backup                 Sichert Konfigurationen, Plugins und Dienste nach $BACKUP_DIR
  beamnet install-core           Installiert das Plugin BeamNetCore (km, XP, Liga, Rennen, /server) auf allen Servern
  beamnet openclaw status|pause|resume   OpenClaw-Agent ansehen, anhalten (einfrieren), fortsetzen
  beamnet self-update            Neueste Version dieses Werkzeugs laden

  Option -y: ohne Rückfrage ausführen.
EOF
}

main() {
    local args=() a
    for a in "$@"; do
        if [[ $a == -y || $a == --yes ]]; then YES=1; else args+=("$a"); fi
    done
    set -- "${args[@]+"${args[@]}"}"
    local cmd=${1:-hilfe}
    [[ $# -gt 0 ]] && shift
    case $cmd in
        status|st) cmd_status ;;
        doctor|diagnose) cmd_doctor ;;
        report|bericht) cmd_report ;;
        fix|reparieren) cmd_fix ;;
        start) cmd_start "$@" ;;
        stop) cmd_stop "$@" ;;
        restart|neustart) cmd_restart "$@" ;;
        maps) cmd_maps ;;
        set-map) cmd_set_map "$@" ;;
        logs|log) cmd_logs "$@" ;;
        plugins) cmd_plugins ;;
        plugin-disable) cmd_plugin_toggle disable "$@" ;;
        plugin-enable) cmd_plugin_toggle enable "$@" ;;
        players|spieler) cmd_players ;;
        backup|sicherung) cmd_backup ;;
        install-core) cmd_install_core ;;
        openclaw) cmd_openclaw "$@" ;;
        self-update|update) cmd_self_update ;;
        version|--version) echo "BeamNet $VERSION" ;;
        hilfe|help|-h|--help) cmd_help ;;
        *) cmd_help; exit 1 ;;
    esac
}

main "$@"
