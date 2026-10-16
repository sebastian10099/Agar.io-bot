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

VERSION="1.30"
ROOT="${BEAMNET_ROOT:-/srv/beammp}"
UNIT_PREFIX="${BEAMNET_UNIT_PREFIX:-beammp-}"
SERVICE_USER="${BEAMNET_USER:-beammp}"
SHARED="${BEAMNET_SHARED:-$ROOT/shared/beamnet}"
BACKUP_DIR="${BEAMNET_BACKUP_DIR:-/root/beamnet-backups}"
AUTH_KEYS="${BEAMNET_AUTH_KEYS:-/root/.ssh/authorized_keys}"
AGENT_USER="${BEAMNET_AGENT_USER:-openclaw}"
WAIT_SECONDS="${BEAMNET_WAIT:-15}"
CONF="${BEAMNET_CONF:-/etc/beamnet.conf}"
STATE_DIR="${BEAMNET_STATE:-/var/lib/beamnet}"
SYSTEMD_DIR="${BEAMNET_SYSTEMD_DIR:-/etc/systemd/system}"
WEB_DIR="${BEAMNET_WEB_DIR:-/var/www/beamnet}"
# Hoechstens so viele automatische Neustarts je Server und Stunde (Schutz vor Endlosschleifen).
MAX_RESTARTS_PER_HOUR=3
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
        # "if" statt "&&": sonst liefert die Liste wegen pipefail einen Fehler, wenn der letzte Ordner kein Server ist.
        if [[ $name =~ ^[0-9]+$ && -f $dir/ServerConfig.toml ]]; then echo "$name"; fi
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

# ---------------------------------------------------------------------------------------------------------------------
# Sicheres Schreiben als root in Ordner, die dem Dienst-Benutzer gehoeren (gemeinsamer Ordner, Server-Ordner):
# nie einem Symlink folgen (sonst koennte beammp root dazu bringen, z. B. /etc/passwd zu ueberschreiben).
#   safe put <Datei> <Modus> [<Besitzer>]   – stdin atomar schreiben (exklusive Zwischendatei, dann rename)
#   safe get <Datei>                        – Inhalt ausgeben, nur wenn regulaere Datei und kein Symlink
#   safe mapline <Datei> <Map> <Sicherungsordner> – Map-Zeile ersetzen, Sicherung im root-Ordner (letzte 20)
#   safe chmoddir <Modus> <Ordner …>         – Rechte setzen, ohne Symlinks zu folgen
read -r -d '' SAFE_PY <<'PY'
import os, pwd, re, stat, sys, time

def opendir(path):
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

def put(dest, data, mode, uid=-1, gid=-1):
    d, base = os.path.split(os.path.abspath(dest))
    dfd = opendir(d)
    try:
        name = ".beamnet-%s.tmp" % os.urandom(8).hex()
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            with os.fdopen(fd, "wb", closefd=False) as f:
                f.write(data)
                f.flush()
                if uid >= 0:
                    os.fchown(fd, uid, gid)
                os.fchmod(fd, mode)
                os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(name, base, src_dir_fd=dfd, dst_dir_fd=dfd)
    finally:
        os.close(dfd)

def get(path):
    d, base = os.path.split(os.path.abspath(path))
    dfd = opendir(d)
    try:
        fd = os.open(base, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
    finally:
        os.close(dfd)
    with os.fdopen(fd, "rb") as f:
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise OSError("keine regulaere Datei: " + path)
        return f.read(), st

cmd = sys.argv[1]
try:
    if cmd == "put":
        uid = gid = -1
        if len(sys.argv) > 4 and sys.argv[4]:
            pw = pwd.getpwnam(sys.argv[4])
            uid, gid = pw.pw_uid, pw.pw_gid
        put(sys.argv[2], sys.stdin.buffer.read(), int(sys.argv[3], 8), uid, gid)
    elif cmd == "get":
        sys.stdout.buffer.write(get(sys.argv[2])[0])
    elif cmd == "mapline":
        path, mp, bdir = sys.argv[2], sys.argv[3], sys.argv[4]
        data, st = get(path)
        text = data.decode("utf-8", "surrogateescape")
        pattern = re.compile(r"^([ \t]*)Map[ \t]*=.*$", re.M)
        if not pattern.search(text):
            sys.exit(3)
        os.makedirs(bdir, mode=0o700, exist_ok=True)
        os.chmod(bdir, 0o700)
        prefix = os.path.basename(path) + "."
        with open(os.path.join(bdir, prefix + time.strftime("%Y%m%d-%H%M%S")), "wb") as f:
            f.write(data)
        olds = sorted(n for n in os.listdir(bdir) if n.startswith(prefix))
        for n in olds[:-20]:
            os.remove(os.path.join(bdir, n))
        new = pattern.sub(lambda m: m.group(1) + 'Map = "/levels/%s/info.json"' % mp, text)
        put(path, new.encode("utf-8", "surrogateescape"), stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid)
    elif cmd == "chmoddir":
        mode = int(sys.argv[2], 8)
        for path in sys.argv[3:]:
            fd = opendir(path)
            try:
                os.fchmod(fd, mode)
            finally:
                os.close(fd)
except OSError as e:
    print("beamnet: " + str(e), file=sys.stderr)
    sys.exit(2)
PY
safe() { python3 -I -c "$SAFE_PY" "$@"; }

# Datensicherung des gemeinsamen Ordners (Spieler, Rekorde, Banns, Protokoll …) und ihre Wiederherstellung.
#   data save <Ordner> <Archiv>   – nur regulaere Dateien, ueber Ordner-Deskriptoren ohne Symlinks (der Ordner gehoert
#                                   beammp); ohne servers/, votes/, reports/ und Zwischendateien
#   data restore <Archiv> <Ziel>  – prueft jedes Mitglied (nur Dateien/Ordner, keine absoluten Pfade, kein ..) und
#                                   legt alles exklusiv im leeren, root-eigenen Zielordner an
read -r -d '' DATA_PY <<'PY'
import io, os, stat, sys, tarfile, time

SKIP_DIRS = {"servers", "votes", "reports"}
FLAGS_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW

def skip_file(name):
    return name.startswith(".") or name.endswith(".tmp") or name == "players-index.tsv" or ".kaputt-" in name

def save(src, dest):
    tmp = dest + ".tmp"
    count = 0
    with tarfile.open(tmp, "w:gz") as tar:
        def walk(dfd, rel, depth):
            nonlocal count
            for name in sorted(os.listdir(dfd)):
                try:
                    st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISDIR(st.st_mode):
                    if depth >= 4 or (rel == "" and name in SKIP_DIRS) or name.startswith("."):
                        continue
                    sub = os.open(name, FLAGS_DIR, dir_fd=dfd)
                    try:
                        info = tarfile.TarInfo(rel + name)
                        info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, int(st.st_mtime)
                        tar.addfile(info)
                        walk(sub, rel + name + "/", depth + 1)
                    finally:
                        os.close(sub)
                elif stat.S_ISREG(st.st_mode) and not skip_file(name):
                    try:
                        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
                    except OSError:
                        continue
                    with os.fdopen(fd, "rb") as f:
                        fst = os.fstat(f.fileno())
                        if not stat.S_ISREG(fst.st_mode) or fst.st_size > 64 * 1024 * 1024:
                            continue
                        data = f.read()
                    info = tarfile.TarInfo(rel + name)
                    info.size, info.mode, info.mtime = len(data), 0o644, int(fst.st_mtime)
                    tar.addfile(info, io.BytesIO(data))
                    count += 1
        top = os.open(src, FLAGS_DIR)
        try:
            walk(top, "", 0)
        finally:
            os.close(top)
    os.chmod(tmp, 0o600)
    os.replace(tmp, dest)
    print(count)

def safe_parts(name):
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if not parts or name.startswith("/") or any(p == ".." or "\\" in p for p in parts) or len(parts) > 5:
        raise ValueError("unsicherer Pfad im Archiv: " + name)
    return parts

def restore(archive, target):
    if os.listdir(target):
        raise ValueError("Zielordner ist nicht leer")
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        total = 0
        for m in members:
            safe_parts(m.name)
            if not (m.isreg() or m.isdir()):
                raise ValueError("unerlaubter Eintrag im Archiv: " + m.name)
            total += m.size
        if total > 4 * 1024 * 1024 * 1024:
            raise ValueError("Archiv zu gross")
        top = os.open(target, FLAGS_DIR)
        count = 0
        try:
            def dir_for(parts):
                fd = os.dup(top)
                for p in parts:
                    try:
                        os.mkdir(p, 0o755, dir_fd=fd)
                    except FileExistsError:
                        pass
                    nfd = os.open(p, FLAGS_DIR, dir_fd=fd)
                    os.close(fd)
                    fd = nfd
                return fd
            for m in members:
                parts = safe_parts(m.name)
                if m.isdir():
                    os.close(dir_for(parts))
                    continue
                dfd = dir_for(parts[:-1])
                try:
                    fd = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=dfd)
                    with os.fdopen(fd, "wb") as out:
                        out.write(tar.extractfile(m).read())
                    count += 1
                finally:
                    os.close(dfd)
        finally:
            os.close(top)
    print(count)

try:
    if sys.argv[1] == "save":
        save(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "restore":
        restore(sys.argv[2], sys.argv[3])
    else:
        raise ValueError("unbekannter Befehl")
except Exception as e:
    print(f"Fehler: {e}", file=sys.stderr)
    sys.exit(1)
PY
data_tool() { python3 -I -c "$DATA_PY" "$@"; }

unit() { printf '%s%s.service' "$UNIT_PREFIX" "$1"; }

unit_exists() { systemctl cat "$(unit "$1")" >/dev/null 2>&1; }
unit_active() { [[ $(systemctl is-active "$(unit "$1")" 2>/dev/null) == active ]]; }
unit_enabled() { [[ $(systemctl is-enabled "$(unit "$1")" 2>/dev/null) == enabled ]]; }
main_pid() { systemctl show -p MainPID --value "$(unit "$1")" 2>/dev/null || echo 0; }

# Alle BeamMP-Server-Prozesse: "pid benutzer arbeitsordner dienst" je Zeile (dienst aus der cgroup, sonst "-").
procs() {
    if [[ -n ${BEAMNET_FAKE_PROCS:-} ]]; then
        cat "$BEAMNET_FAKE_PROCS"
        return
    fi
    local pid user cwd svc
    while read -r pid user; do
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd="?"
        svc=$(grep -o '[^/]*\.service' "/proc/$pid/cgroup" 2>/dev/null | tail -n 1)
        echo "$pid $user $cwd ${svc:--}"
    done < <(ps -eo pid=,user=,comm= 2>/dev/null | awk '$3 ~ /^BeamMP-Server/ {print $1, $2}')
}

# Prozesse eines Servers, die NICHT von seinem systemd-Dienst stammen (z. B. per nohup als root gestartet).
# Entscheidend ist die cgroup: auch ein Kindprozess eines Start-Skripts gehoert zum Dienst.
strays() {
    local nr=$1 dir="$ROOT/$1" mainpid pid user cwd svc
    mainpid=$(main_pid "$nr")
    while read -r pid user cwd svc; do
        [[ -z ${pid:-} ]] && continue
        if [[ $cwd == "$dir" && $pid != "$mainpid" && ${svc:--} != "$(unit "$nr")" ]]; then echo "$pid $user"; fi
    done < <(procs)
}

proc_user() {
    local nr=$1 dir="$ROOT/$1" pid user cwd svc
    while read -r pid user cwd svc; do
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

# Spielernamen eines Servers aus dem Lebenszeichen des Plugins: bereinigt (keine Steuerzeichen, hoechstens 32
# Zeichen je Name), alphabetisch, hoechstens 30 Namen – leer, wenn das Lebenszeichen fehlt oder veraltet ist.
names_of() {
    local file="$SHARED/servers/$1.json"
    [[ -f $file && ! -L $file ]] || return 0
    command -v python3 >/dev/null || return 0
    python3 -I - "$file" <<'EOF' 2>/dev/null
import json, re, sys, time
def read_nofollow(path, limit=16 * 1024 * 1024):
    """Inhalt einer regulaeren Datei, ohne einem Symlink zu folgen (Ordner gehoeren beammp)."""
    import os as _os, stat as _stat
    fd = _os.open(path, _os.O_RDONLY | _os.O_NOFOLLOW | _os.O_NONBLOCK)
    with _os.fdopen(fd, "rb") as fh:
        if not _stat.S_ISREG(_os.fstat(fh.fileno()).st_mode):
            raise OSError("keine regulaere Datei: " + path)
        return fh.read(limit).decode("utf-8")
try:
    st = json.loads(read_nofollow(sys.argv[1]))
except Exception:
    sys.exit(0)
if not isinstance(st, dict) or not isinstance(st.get("names"), list):
    sys.exit(0)
upd = st.get("updated")
if not isinstance(upd, (int, float)) or time.time() - upd > 90:
    sys.exit(0)
clean = []
for n in st["names"]:
    n = re.sub(r"[\x00-\x1f\x7f]", "", str(n)).strip()[:32]
    if n:
        clean.append(n)
clean.sort(key=str.lower)
more = len(clean) - 30
print(", ".join(clean[:30]) + (f" +{more} weitere" if more > 0 else ""))
EOF
}

# Eine Zeile je Server mit Spielern: "Server 3 (italy): Sebi, Max" – fuer Meldungen und "beamnet players".
online_lines() {
    local nr pl names map
    for nr in $(servers); do
        pl=$(players_of "$(cfg "$nr" Port)")
        [[ $pl =~ ^([0-9]+)/ ]] || continue
        (( BASH_REMATCH[1] > 0 )) || continue
        names=$(names_of "$(cfg "$nr" Port)")
        map=$(map_short "$(cfg "$nr" Map)")
        printf 'Server %s (%s): %s\n' "$nr" "${map:-?}" "${names:-${BASH_REMATCH[1]} Spieler}"
    done
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
    if (( ${#CORE_VERSIONS[@]} > 0 )); then
        local versions
        versions=$(printf '%s\n' "${CORE_VERSIONS[@]}" | cut -d: -f1 | sort -u | tr '\n' ' ')
        if [[ $(wc -w <<<"$versions") -gt 1 ]]; then
            warn "Unterschiedliche BeamNetCore-Versionen auf den Servern: ${versions% }"
            hint "beamnet update   (bringt alle Server auf den neuesten Stand)"
        fi
    fi
    dup=$(tr ' ' '\n' <<<"$seen_maps" | grep -v '^$' | sort | uniq -d | tr '\n' ' ')
    [[ -n $dup ]] && warn "Mehrere Server mit derselben Map: $dup" && hint "beamnet maps   ·   beamnet set-map <nr> <map>"

    title "BeamNet-Dienste"
    check_watch

    title "Andere Programme, die an den Servern drehen"
    check_agent
    check_cron

    title "SSH-Zugang"
    check_keys

    title "System"
    check_system

    summary
}

# Laeuft der Waechter wirklich? (Lebenszeichen watch.json; ohne ihn keine Ausfallmeldungen, Abstimmungen, Rotation)
check_watch() {
    local at age
    if [[ ! -f $SYSTEMD_DIR/beamnet-watch.timer ]]; then
        echo "  Wächter nicht eingerichtet – Ausfallmeldungen, Map-Abstimmung und Map-Rotation brauchen ihn."
        hint "beamnet watch install"
        return 0
    fi
    at=$(grep -o '"at":[0-9]*' "$SHARED/watch.json" 2>/dev/null | head -n1 | cut -d: -f2)
    if [[ -z $at ]]; then
        warn "Wächter eingerichtet, hat aber noch nie gemeldet"
        hint "systemctl status beamnet-watch.timer   ·   beamnet watch (einmal von Hand)"
        return 0
    fi
    age=$(( $(date +%s) - at ))
    if (( age > 300 )); then
        warn "Wächter eingerichtet, letztes Lebenszeichen vor $(( age / 60 )) Minuten – er läuft nicht mehr"
        hint "systemctl enable --now beamnet-watch.timer   ·   journalctl -u beamnet-watch -n 20"
    else
        ok "Wächter läuft (zuletzt vor ${age} s)"
    fi
    [[ $(conf_get MAP_VOTE) == 0 ]] || ok "Map-Abstimmung an ($(vote_maps | wc -w) Maps)"
    local nr list
    for nr in $(servers); do
        list=$(conf_get "ROTATE_$nr")
        [[ -n $list ]] && ok "Server $nr: tägliche Map-Rotation ($list)"
    done
    return 0
}

# Laeuft BeamNetCore auf diesem Server? (nur wenn installiert und der Server laeuft)
CORE_VERSIONS=()
check_core() {
    local nr=$1 port=$2 name=$3 updated now err ver
    [[ -f $ROOT/$nr/Resources/Server/BeamNetCore/main.lua ]] || return 0
    unit_active "$nr" || return 0
    updated=$(grep -o '"updated"[[:space:]]*:[[:space:]]*[0-9]*' "$SHARED/servers/$port.json" 2>/dev/null | grep -o '[0-9]*$')
    ver=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[0-9.]*"' "$SHARED/servers/$port.json" 2>/dev/null | grep -o '[0-9.]*"$' | tr -d '"')
    now=$(date +%s)
    if [[ -n $updated && $((now - updated)) -le 90 ]]; then
        ok "$name: BeamNetCore ${ver:+$ver }aktiv"
        [[ -n $ver ]] && CORE_VERSIONS+=("$ver:$nr")
    elif [[ -n $updated ]]; then
        warn "$name: BeamNetCore meldet sich seit $(( (now - updated) / 60 )) min nicht mehr"
        hint "beamnet logs $nr   (steht dort ein Fehler von BeamNetCore?)"
    else
        warn "$name: BeamNetCore ist installiert, hat sich aber noch nie gemeldet"
        hint "BeamMP lädt Plugins normalerweise selbst; sonst hilft: beamnet restart $nr"
    fi
    err=$(tail -n 400 "$ROOT/$nr/Server.log" 2>/dev/null | grep -F "[BeamNetCore] Fehler" | tail -n 1)
    [[ -n $err ]] && warn "$name: Fehlermeldung von BeamNetCore: ${err:0:160}"
    if grep -q '"positions"[[:space:]]*:[[:space:]]*false' "$SHARED/servers/$port.json" 2>/dev/null; then
        bad "$name: BeamMP-Server zu alt – Kilometer und Rennen funktionieren nicht (MP.GetPositionRaw fehlt)"
        hint "BeamMP-Server aktualisieren: https://beammp.com"
    fi
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
        clear_maintenance "$nr"
        systemctl enable "$(unit "$nr")" >/dev/null 2>&1
        if systemctl start "$(unit "$nr")"; then echo "Server $nr gestartet"; else echo "Server $nr: Start fehlgeschlagen (beamnet logs $nr)"; fi
    done
    # shellcheck disable=SC2086
    verify_running $list
}

# Wartung: Mit "beamnet stop" gestoppte Server startet der Waechter nicht neu und meldet sie nicht als Ausfall.
set_maintenance() { mkdir -p "$STATE_DIR" 2>/dev/null && : >"$STATE_DIR/maintenance-$1"; }
clear_maintenance() { rm -f "$STATE_DIR/maintenance-$1" 2>/dev/null; return 0; }

cmd_stop() {
    need_root stop
    local list nr
    list=$(targets "$@") || exit 1
    confirm "Server $(tr '\n' ' ' <<<"$list")stoppen? Spieler darauf fliegen raus." || { echo "Abgebrochen."; return 1; }
    for nr in $list; do
        systemctl stop "$(unit "$nr")" && echo "Server $nr gestoppt"
        set_maintenance "$nr"
    done
}

cmd_restart() {
    need_root restart
    local list nr
    list=$(targets "$@") || exit 1
    confirm "Server $(tr '\n' ' ' <<<"$list")neu starten? Spieler darauf fliegen kurz raus." || { echo "Abgebrochen."; return 1; }
    for nr in $list; do
        clear_maintenance "$nr"
        systemctl restart "$(unit "$nr")" && echo "Server $nr neu gestartet"
    done
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
            clear_maintenance "$nr"
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

# write_map <nr> <map>: Map-Zeile in ServerConfig.toml ersetzen; die alte Datei kommt nach $BACKUP_DIR/config/<nr>
# (nur root, die letzten 20). Folgt keinen Symlinks – der Server-Ordner gehoert dem Dienst-Benutzer.
write_map() {
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    safe mapline "$ROOT/$1/ServerConfig.toml" "$2" "$BACKUP_DIR/config/$1"
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
    write_map "$nr" "$map" || die "In $file steht keine Map-Zeile."
    ok "Server $nr: Map = $map (alte Konfiguration gesichert in $BACKUP_DIR/config/$nr)"
    echo "BeamMP liest die Map nur beim Start."
    if confirm "Server $nr jetzt neu starten?"; then
        clear_maintenance "$nr"
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
    # Waehrend der Sicherung schreiben die Server weiter; GNU tar meldet das mit Code 1 – das Archiv ist trotzdem gut.
    local rc=0
    if [[ ${#units[@]} -gt 0 ]]; then
        tar --warning=no-file-changed --ignore-failed-read -czf "$file" -C "$ROOT" "${items[@]}" \
            -C /etc/systemd/system "${units[@]}" || rc=$?
    else
        tar --warning=no-file-changed --ignore-failed-read -czf "$file" -C "$ROOT" "${items[@]}" || rc=$?
    fi
    (( rc <= 1 )) || die "Sicherung fehlgeschlagen (tar Code $rc)"
    chmod 600 "$file"
    ok "Gesichert: $file ($(du -h "$file" | cut -f1))"
    echo "Enthält die AuthKeys – nicht weitergeben."
    # Nur die 20 neuesten behalten.
    find "$BACKUP_DIR" -maxdepth 1 -name 'beamnet-*.tgz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +21 | cut -d' ' -f2- | xargs -r rm -f
}

# Datensicherungen (taeglich vom Waechter): auflisten oder einen Stand zuruecksetzen.
cmd_restore() {
    need_root restore
    local want=${1:-} file ts new old nr running=() f
    if [[ -z $want ]]; then
        echo "Tägliche Datensicherungen in $BACKUP_DIR (Spieler, Rekorde, Banns, Protokoll):"
        f=""
        for file in "$BACKUP_DIR"/daten-*.tgz; do
            [[ -f $file ]] || continue
            f=1
            printf '  %s  %s\n' "$(basename "$file" .tgz | sed 's/^daten-//')" "$(du -h "$file" | cut -f1)"
        done
        [[ -n $f ]] || echo "  (noch keine – der Wächter legt sie täglich ab $(backup_hour) Uhr an: beamnet watch install)"
        echo "Zurücksetzen: beamnet restore <JJJJ-MM-TT>"
        return 0
    fi
    [[ $want =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "Aufruf: beamnet restore [JJJJ-MM-TT]"
    file="$BACKUP_DIR/daten-$want.tgz"
    [[ -f $file && ! -L $file ]] || die "Keine Datensicherung vom $want (Liste: beamnet restore)."
    [[ -L $SHARED ]] && die "$SHARED ist ein Symlink – bitte prüfen, nichts geändert."
    command -v python3 >/dev/null || die "python3 fehlt (apt install python3)."
    confirm "Spielerdaten auf den Stand vom $want zurücksetzen? Alle Server werden dafür kurz gestoppt." \
        || { echo "Abgebrochen."; return 1; }
    ts=$(date +%Y%m%d-%H%M%S)
    new="$SHARED.neu-$ts"
    old="$SHARED.vor-wiederherstellung-$ts"
    mkdir -m 700 "$new" || die "Konnte $new nicht anlegen."
    if ! f=$(data_tool restore "$file" "$new" 2>&1); then
        rm -rf "$new"
        die "Sicherung vom $want ist nicht lesbar – nichts geändert. ($f)"
    fi
    for nr in $(servers); do unit_active "$nr" && running+=("$nr"); done
    for nr in "${running[@]}"; do set_maintenance "$nr"; systemctl stop "$(unit "$nr")"; done
    if [[ -d $SHARED ]]; then mv -T "$SHARED" "$old" || { rm -rf "$new"; die "Konnte den alten Stand nicht beiseitelegen."; }; fi
    mv -T "$new" "$SHARED"
    ensure_shared
    for nr in "${running[@]}"; do systemctl start "$(unit "$nr")"; clear_maintenance "$nr"; done
    ok "Stand vom $want wiederhergestellt ($f Dateien). Server wieder gestartet: ${running[*]:-keine}."
    [[ -d $old ]] && echo "Der bisherige Stand liegt in $old (löschen, wenn alles passt)."
    return 0
}

backup_hour() {
    local h
    h=$(conf_get BACKUP_HOUR)
    if [[ $h =~ ^[0-9]{1,2}$ ]] && (( 10#$h <= 23 )); then echo $(( 10#$h )); else echo 4; fi
}

# Taegliche Datensicherung des gemeinsamen Ordners ab BACKUP_HOUR (Standard 4 Uhr); BACKUP_KEEP (Standard 14) Tage
# aufbewahren. Nur bei einem Fehler eine Meldung (einmal am Tag).
watch_backup() {
    local -n bout=$1
    local hour today keep err
    [[ $(conf_get DATA_BACKUP) == 0 ]] && return 0
    [[ -d $SHARED && ! -L $SHARED ]] || return 0
    command -v python3 >/dev/null || return 0
    hour=${BEAMNET_HOUR:-$(date +%H)}
    (( 10#$hour >= $(backup_hour) )) || return 0
    today=$(date +%Y-%m-%d)
    [[ -f $BACKUP_DIR/daten-$today.tgz || -f $STATE_DIR/backup-failed-$today ]] && return 0
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    if ! err=$(data_tool save "$SHARED" "$BACKUP_DIR/daten-$today.tgz" 2>&1); then
        : >"$STATE_DIR/backup-failed-$today"
        bout+=("⚠️ Tägliche Datensicherung fehlgeschlagen: ${err:0:200}")
        return 0
    fi
    keep=$(conf_get BACKUP_KEEP)
    [[ $keep =~ ^[0-9]{1,3}$ ]] && (( 10#$keep >= 1 )) || keep=14
    find "$BACKUP_DIR" -maxdepth 1 -name 'daten-*.tgz' -printf '%f\n' 2>/dev/null | sort -r | tail -n +$(( 10#$keep + 1 )) \
        | while read -r f; do rm -f "$BACKUP_DIR/$f"; done
    find "$STATE_DIR" -maxdepth 1 -name 'backup-failed-*' -mtime +3 -delete 2>/dev/null
    return 0
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
    local file nr pl names map total=0 lines=""
    if [[ ! -d $SHARED/servers ]]; then
        echo "Noch keine Daten – das Plugin BeamNetCore ist nicht installiert (beamnet install-core)."
        return
    fi
    if [[ ${1:-} == json ]]; then
        for file in "$SHARED"/servers/*.json; do
            [[ -f $file ]] || continue
            printf '%s\n' "$(cat "$file")"
        done
        return
    fi
    for nr in $(servers); do
        pl=$(players_of "$(cfg "$nr" Port)")
        map=$(map_short "$(cfg "$nr" Map)")
        if [[ $pl =~ ^([0-9]+)/ ]]; then
            total=$(( total + BASH_REMATCH[1] ))
            names=$(names_of "$(cfg "$nr" Port)")
            (( BASH_REMATCH[1] > 0 )) && lines+="$(printf 'Server %-3s %-8s %-22s %s' "$nr" "$pl" "$map" "${names:-(Namen erst mit Plugin 1.2+)}")"$'\n'
        else
            lines+="$(printf 'Server %-3s %-8s %-22s %s' "$nr" "?" "$map" "(kein Lebenszeichen – Plugin läuft nicht?)")"$'\n'
        fi
    done
    printf '%s%s Spieler online%s\n' "$BOLD" "$total" "$RESET"
    printf '%s' "$lines"
}

# Gemeinsamer Datenordner mit Rechten fuer den Dienst-Benutzer (sonst kann das Plugin nichts speichern).
ensure_shared() {
    local d
    for d in "$SHARED" "$SHARED/players" "$SHARED/servers" "$SHARED/races" "$SHARED/votes" "$SHARED/reports"; do
        [[ -L $d ]] && rm -f "$d"       # Symlinks hier nie folgen
        mkdir -p "$d"
    done
    chown -hR "$SERVICE_USER:$SERVICE_USER" "$SHARED"
    safe chmoddir 775 "$SHARED" "$SHARED/players" "$SHARED/servers" "$SHARED/races" "$SHARED/votes" "$SHARED/reports"
}

# Holt das Plugin aus dem Ordner neben diesem Skript oder von GitHub
# (BEAMNET_FORCE_DOWNLOAD=1: immer von GitHub, z. B. bei "beamnet update").
core_source() {
    local local_file="$SCRIPT_DIR/server/BeamNetCore/main.lua" tmp
    if [[ -f $local_file && ${BEAMNET_FORCE_DOWNLOAD:-0} != 1 ]]; then
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
    ensure_shared
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    for nr in $list; do
        dest="$ROOT/$nr/Resources/Server/BeamNetCore"
        if [[ -L $ROOT/$nr/Resources || -L $ROOT/$nr/Resources/Server || -L $dest ]]; then
            bad "Server $nr: Plugin-Ordner ist ein Symlink – übersprungen (bitte prüfen)"
            continue
        fi
        mkdir -p "$dest"
        if [[ -f $dest/main.lua ]]; then
            mkdir -p "$BACKUP_DIR/plugins/$nr"
            safe get "$dest/main.lua" >"$BACKUP_DIR/plugins/$nr/main.lua.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
        fi
        if safe put "$dest/main.lua" 644 "$SERVICE_USER" <"$src"; then
            chown -h "$SERVICE_USER:$SERVICE_USER" "$dest"
            ok "Server $nr: BeamNetCore installiert"
        else
            bad "Server $nr: BeamNetCore konnte nicht geschrieben werden"
        fi
    done
    echo "Gemeinsame Daten: $SHARED"
    echo "BeamMP lädt das Plugin innerhalb weniger Sekunden selbst neu – ein Neustart ist nicht nötig."
    echo "Prüfen: beamnet doctor (BeamNetCore aktiv?)"
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

# ---------------------------------------------------------------------------------------------------------------------
# Waechter (systemd-Timer, jede Minute)

conf_get() {
    [[ -f $CONF ]] || return 0
    grep -m1 -E "^[[:space:]]*$1=" "$CONF" | cut -d= -f2- | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//'
}

json_escape() {
    local text=$1
    text=${text//\\/\\\\}
    text=${text//\"/\\\"}
    text=${text//$'\n'/\\n}
    text=${text//$'\r'/}
    text=${text//$'\t'/ }
    printf '%s' "$text" | tr -d '\000-\010\013-\037\177'
}

# Ist mindestens ein Meldeweg (Discord-Webhook oder Telegram-Bot) eingetragen?
notify_configured() {
    [[ -n $(conf_get DISCORD_WEBHOOK) || ( -n $(conf_get TELEGRAM_TOKEN) && -n $(conf_get TELEGRAM_CHAT) ) ]]
}

# Nachricht an Discord und/oder Telegram (nur die eingetragenen Wege). Telegram bekommt reinen Text (kein Markdown,
# damit Spielernamen mit Sonderzeichen nichts kaputt machen).
notify() {
    local hook token chat rc=0 text=$1
    hook=$(conf_get DISCORD_WEBHOOK)
    if [[ -n $hook ]]; then
        if [[ ! $hook =~ ^https://(discord|discordapp)\.com/api/webhooks/[A-Za-z0-9/_-]+$ ]]; then
            echo "DISCORD_WEBHOOK in $CONF sieht nicht wie ein Discord-Webhook aus – nichts gesendet." >&2
            rc=1
        else
            # Die Adresse (enthaelt das Geheimnis) ueber -K statt auf der Befehlszeile: die sieht jeder Benutzer mit ps.
            curl -fsS -m 10 -H "Content-Type: application/json" \
                -d "{\"content\":\"$(json_escape "$text")\",\"allowed_mentions\":{\"parse\":[]}}" \
                -K <(printf 'url = "%s"\n' "$hook") >/dev/null \
                || { echo "Discord-Meldung fehlgeschlagen" >&2; rc=1; }
        fi
    fi
    token=$(conf_get TELEGRAM_TOKEN)
    chat=$(conf_get TELEGRAM_CHAT)
    if [[ -n $token || -n $chat ]]; then
        if [[ ! $token =~ ^[0-9]{5,}:[A-Za-z0-9_-]{20,}$ ]]; then
            echo "TELEGRAM_TOKEN in $CONF sieht nicht wie ein Bot-Token von @BotFather aus (123456:ABC…) – nichts gesendet." >&2
            rc=1
        elif [[ ! $chat =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,})$ ]]; then
            echo "TELEGRAM_CHAT in $CONF muss eine Chat-ID (Zahl, bei Gruppen negativ) oder @Kanalname sein – nichts gesendet." >&2
            rc=1
        else
            curl -fsS -m 10 -H "Content-Type: application/json" \
                -d "{\"chat_id\":\"$chat\",\"text\":\"$(json_escape "${text:0:4000}")\",\"disable_web_page_preview\":true}" \
                -K <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token") >/dev/null \
                || { echo "Telegram-Meldung fehlgeschlagen" >&2; rc=1; }
        fi
    fi
    return $rc
}

# Nimmt der Server auf seinem Port Verbindungen an? (TCP auf 127.0.0.1, hoechstens 3 s)
port_open() {
    [[ $1 =~ ^[0-9]+$ ]] || return 0
    timeout 3 bash -c ': </dev/tcp/127.0.0.1/'"$1" 2>/dev/null
}

# Sekunden seit dem letzten Lebenszeichen des Plugins (leer, wenn es keins gibt).
heartbeat_age() {
    local file="$SHARED/servers/$1.json" updated
    [[ -f $file && ! -L $file ]] || return 0
    updated=$(grep -o '"updated"[[:space:]]*:[[:space:]]*[0-9]*' "$file" | grep -o '[0-9]*$')
    [[ -n $updated ]] && echo $(( $(date +%s) - updated ))
}

# Haengt ein laufender Server? Nur wenn BeamNetCore dort installiert ist, der Dienst schon HANG_MIN Minuten
# (Standard 3) laeuft und das Lebenszeichen so lange fehlt. Neu gestartet wird nur, wenn er zusaetzlich auf seinem
# Port nicht mehr antwortet (sonst koennen die Spieler noch fahren und nur das Plugin steht – das wird gemeldet).
# Gibt "hung", "plugin" oder nichts aus.
hang_check() {
    local nr=$1 port age since now limit min
    [[ -f $ROOT/$nr/Resources/Server/BeamNetCore/main.lua ]] || return 0
    min=$(conf_get HANG_MIN)
    [[ $min =~ ^[0-9]{1,3}$ ]] || min=3
    (( 10#$min > 0 )) || return 0
    limit=$(( 10#$min * 60 ))
    now=$(date +%s)
    since=$(cat "$STATE_DIR/upsince-$nr" 2>/dev/null)
    [[ $since =~ ^[0-9]+$ ]] || return 0
    (( now - since >= limit )) || return 0
    port=$(cfg "$nr" Port)
    age=$(heartbeat_age "$port")
    [[ -n $age ]] && (( age >= limit )) || return 0
    if port_open "$port"; then echo plugin; else echo hung; fi
}

# Wurde der Server in den letzten 15 Minuten vom Agenten gestoppt oder beendet?
stopped_by_agent() {
    journalctl --since "-15min" --no-pager 2>/dev/null \
        | grep -E "$AGENT_USER : .*COMMAND=.*(stop|kill).*(beammp-$1([^0-9]|\$)|/$1/BeamMP)" >/dev/null
}

# Zaehlt automatische Neustarts der letzten Stunde; gibt 1 zurueck, wenn das Limit erreicht ist.
restart_allowed() {
    local file="$STATE_DIR/restarts-$1" now kept=() t
    now=$(date +%s)
    if [[ -f $file ]]; then
        while read -r t; do [[ $t =~ ^[0-9]+$ ]] && (( now - t < 3600 )) && kept+=("$t"); done <"$file"
    fi
    if (( ${#kept[@]} >= MAX_RESTARTS_PER_HOUR )); then
        printf '%s\n' "${kept[@]}" >"$file"
        return 1
    fi
    kept+=("$now")
    printf '%s\n' "${kept[@]}" >"$file"
    return 0
}

# Maps fuer Abstimmungen: Vanilla-Maps plus VOTE_MAPS aus der Einstellungsdatei (z. B. Mod-Maps, die alle haben).
vote_maps() {
    local m list=$KNOWN_MAPS
    for m in $(conf_get VOTE_MAPS | tr ',' ' '); do
        [[ $m =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ && " $list " != *" $m "* ]] && list+=" $m"
    done
    printf '%s' "$list"
}

# Lebenszeichen fuer das Plugin: Waechter laeuft, Abstimmungen an/aus, erlaubte Maps.
watch_heartbeat() {
    [[ -d $SHARED ]] || return 0
    local enabled=true maps="" m
    [[ $(conf_get MAP_VOTE) == 0 ]] && enabled=false
    for m in $(vote_maps); do maps+="${maps:+,}\"$m\""; done
    printf '{"at":%s,"mapVote":%s,"maps":[%s]}\n' "$(date +%s)" "$enabled" "$maps" | safe put "$SHARED/watch.json" 644
}

# Auftraege aus Map-Abstimmungen (votes/<Port>.json vom Plugin) ausfuehren: Map pruefen, umstellen, neu starten.
watch_votes() {
    local -n vout=$1
    local file data port map at now nr n old
    now=$(date +%s)
    [[ -d $SHARED/votes && ! -L $SHARED/votes ]] || return 0
    for file in "$SHARED"/votes/*.json; do
        [[ -f $file ]] || continue
        data=$(safe get "$file" 2>/dev/null | head -c 4096)
        rm -f "$file"     # jeder Auftrag nur einmal, auch wenn er nicht ausgefuehrt wird
        port=$(grep -o '"port":[0-9]*' <<<"$data" | head -n1 | cut -d: -f2)
        map=$(grep -o '"map":"[^"]*"' <<<"$data" | head -n1 | cut -d'"' -f4)
        at=$(grep -o '"at":[0-9]*' <<<"$data" | head -n1 | cut -d: -f2)
        [[ -n $port && -n $map && -n $at ]] || continue
        [[ $(conf_get MAP_VOTE) == 0 ]] && continue
        (( now - at <= 600 )) || continue                     # zu alt (Waechter lief nicht)
        if [[ ! $map =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ || " $(vote_maps) " != *" $map "* ]]; then
            vout+=("⚠️ Map-Abstimmung auf Port $port: Map nicht erlaubt – ignoriert.")
            continue
        fi
        nr=""
        for n in $(servers); do [[ $(cfg "$n" Port) == "$port" ]] && nr=$n; done
        [[ -n $nr ]] || continue
        if [[ -f $STATE_DIR/maintenance-$nr ]] || ! unit_active "$nr"; then
            vout+=("ℹ️ Map-Abstimmung auf Server $nr nicht umgesetzt: Server ist gestoppt oder in Wartung.")
            continue
        fi
        # Hoechstens ein Wechsel je Server in 5 Minuten.
        if [[ -f $STATE_DIR/mapvote-$nr ]] && (( now - $(cat "$STATE_DIR/mapvote-$nr" 2>/dev/null || echo 0) < 300 )); then
            vout+=("ℹ️ Map-Abstimmung auf Server $nr nicht umgesetzt: erst vor Kurzem gewechselt.")
            continue
        fi
        old=$(map_short "$(cfg "$nr" Map)")
        [[ $old == "$map" ]] && continue
        write_map "$nr" "$map" || { vout+=("⚠️ Server $nr: Konfiguration nicht änderbar – Abstimmung nicht umgesetzt."); continue; }
        echo "$now" >"$STATE_DIR/mapvote-$nr"
        if systemctl restart "$(unit "$nr")"; then
            vout+=("🗺️ Server $nr: Map per Abstimmung von $old auf $map gewechselt.")
        else
            vout+=("⚠️ Server $nr: Neustart nach der Map-Abstimmung fehlgeschlagen (beamnet logs $nr).")
        fi
    done
    return 0
}

# Meldungen aus dem Spiel (/melden, BeamNetCore 1.16+): reports/*.json an Discord/Telegram weitergeben und loeschen.
# Der Ordner gehoert beammp: nur ueber einen Ordner-Deskriptor ohne Symlinks lesen und loeschen; hoechstens 10 je Lauf
# (der Rest beim naechsten Mal), aelter als ein Tag wird verworfen.
watch_reports() {
    local -n repout=$1
    local line
    [[ -d $SHARED/reports && ! -L $SHARED/reports && ! -L $SHARED ]] || return 0
    command -v python3 >/dev/null || return 0
    while IFS= read -r line; do
        [[ -n $line ]] && repout+=("$line")
    done < <(python3 -I - "$SHARED/reports" <<'PY' 2>/dev/null
import json, os, re, stat, sys, time
try:
    dfd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError:
    sys.exit(0)

def clean(v, n):
    v = re.sub(r"[\x00-\x1f\x7f]", " ", str(v if v is not None else "?")).strip()
    return (v[:n] + "…") if len(v) > n else v

now, shown = time.time(), 0
for name in sorted(os.listdir(dfd)):
    if not name.endswith(".json") or shown >= 10:
        continue
    data = None
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
        with os.fdopen(fd, "rb") as f:
            if stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                data = json.loads(f.read(16384).decode("utf-8"))
    except Exception:
        data = None
    try:
        os.unlink(name, dir_fd=dfd)
    except OSError:
        pass
    if not isinstance(data, dict):
        continue
    at = data.get("at")
    if not isinstance(at, (int, float)) or now - at > 86400:
        continue
    shown += 1
    print(f"🚩 Meldung auf {clean(data.get('server'), 60)}: {clean(data.get('by'), 40)} meldet "
          f"{clean(data.get('target'), 40)} – „{clean(data.get('reason'), 200)}“ ({time.strftime('%H:%M', time.localtime(at))} Uhr)")
PY
)
    return 0
}

# Moderation an Discord/Telegram: neue Zeilen aus modlog.jsonl (Bann, Kick, Stummschaltung, Verwarnung). Position
# im Zustand (Inode + Byte); beim ersten Lauf ab dem Ende (keine alte Geschichte). MODLOG_NOTIFY=0 schaltet ab.
watch_modlog() {
    local -n modout=$1
    local line nr map=()
    [[ $(conf_get MODLOG_NOTIFY) == 0 ]] && return 0
    [[ -f $SHARED/modlog.jsonl && ! -L $SHARED/modlog.jsonl && ! -L $SHARED ]] || return 0
    command -v python3 >/dev/null || return 0
    for nr in $(servers); do map+=("$(cfg "$nr" Port)=$nr"); done
    while IFS= read -r line; do
        [[ -n $line ]] && modout+=("$line")
    done < <(python3 -I - "$SHARED/modlog.jsonl" "$STATE_DIR/modlog-pos" "${map[@]}" <<'PY' 2>/dev/null
import json, os, re, stat, sys, time
path, state = sys.argv[1], sys.argv[2]
servers = dict(a.split("=", 1) for a in sys.argv[3:] if "=" in a)
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    sys.exit(0)
with os.fdopen(fd, "rb") as f:
    st = os.fstat(f.fileno())
    if not stat.S_ISREG(st.st_mode):
        sys.exit(0)
    try:
        ino, pos = (int(x) for x in open(state).read().split()[:2])
    except Exception:
        ino, pos = st.st_ino, st.st_size          # erster Lauf: ab dem Ende
    if ino != st.st_ino or pos > st.st_size:
        pos = 0                                   # neue oder gekuerzte Datei
    f.seek(pos)
    chunk = f.read(256 * 1024)
end = chunk.rfind(b"\n") + 1                    # nur vollstaendige Zeilen
with open(state + ".tmp", "w") as out:
    out.write(f"{st.st_ino} {pos + end}\n")
os.replace(state + ".tmp", state)

def c(v, n=40):
    v = re.sub(r"[\x00-\x1f\x7f]", " ", str(v if v is not None else "?")).strip()
    return (v[:n] + "…") if len(v) > n else v

def where(e):
    port = str(e.get("server", ""))
    return f"Server {servers[port]}" if port in servers else f"Port {c(port, 6)}"

lines = []
for raw in chunk[:end].splitlines():
    try:
        e = json.loads(raw.decode("utf-8"))
    except Exception:
        continue
    if not isinstance(e, dict):
        continue
    a, by, who = e.get("action"), c(e.get("by", "System")), c(e.get("target"))
    reason = f" – {c(e['reason'], 150)}" if e.get("reason") else ""
    if a == "ban":
        u = e.get("until")
        span = f" bis {time.strftime('%d.%m. %H:%M', time.localtime(u))}" if isinstance(u, (int, float)) and u > 0 else " dauerhaft"
        lines.append(f"🛡️ {by} hat {who} gebannt{span}{reason} ({where(e)})")
    elif a == "unban":
        lines.append(f"🛡️ {by} hat den Bann von {who} aufgehoben")
    elif a == "kick":
        lines.append(f"🛡️ {by} hat {who} vom Server geworfen{reason} ({where(e)})")
    elif a == "mute":
        m = e.get("minutes")
        span = f" für {int(m)} min" if isinstance(m, (int, float)) and m > 0 else ""
        lines.append(f"🔇 {by} hat {who} stummgeschaltet{span} ({where(e)})")
    elif a == "spam-mute":
        sec = e.get("seconds")
        span = f" für {int(sec)} s" if isinstance(sec, (int, float)) and sec > 0 else ""
        lines.append(f"🔇 {who} wurde wegen Spam{span} stummgeschaltet ({where(e)})")
    elif a == "warn":
        lines.append(f"⚠️ {by} hat {who} verwarnt{reason} ({where(e)})")
for l in lines[:10]:
    print(l)
if len(lines) > 10:
    print(f"   … und {len(lines) - 10} weitere (beamnet modlog)")
PY
)
    return 0
}

# Taegliche Map-Rotation (ROTATE_<nr>="italy utah ..."): ab ROTATE_HOUR (Ortszeit, Standard 6) einmal am Tag zur
# naechsten Map der Liste – nur wenn der Server leer ist (laut BeamNetCore), sonst beim naechsten Lauf erneut.
watch_rotation() {
    local -n rout=$1
    local nr list hour start today cur next pl m maps i
    hour=${BEAMNET_HOUR:-$(date +%H)}
    start=$(conf_get ROTATE_HOUR)
    [[ $start =~ ^[0-9]+$ ]] || start=6
    (( 10#$hour >= 10#$start )) || return 0
    today=$(date +%Y-%m-%d)
    for nr in $(servers); do
        list=$(conf_get "ROTATE_$nr" | tr ',' ' ')
        [[ -n $list ]] || continue
        [[ $(cat "$STATE_DIR/rotate-$nr" 2>/dev/null) == "$today" ]] && continue
        [[ -f $STATE_DIR/maintenance-$nr ]] && continue
        unit_active "$nr" || continue
        pl=$(players_of "$(cfg "$nr" Port)")
        [[ $pl == 0/* ]] || continue        # nur leer – und nur mit aktuellen Plugin-Daten
        maps=()
        for m in $list; do [[ $m =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]] && maps+=("$m"); done
        (( ${#maps[@]} > 0 )) || continue
        cur=$(map_short "$(cfg "$nr" Map)")
        next=${maps[0]}
        for i in "${!maps[@]}"; do
            if [[ ${maps[$i]} == "$cur" ]]; then next=${maps[$(( (i + 1) % ${#maps[@]} ))]}; break; fi
        done
        echo "$today" >"$STATE_DIR/rotate-$nr"
        [[ $next == "$cur" ]] && continue
        write_map "$nr" "$next" || continue
        if systemctl restart "$(unit "$nr")"; then
            rout+=("🔄 Server $nr: Map des Tages ist jetzt $next (vorher $cur).")
        else
            rout+=("⚠️ Server $nr: Neustart nach dem Map-Wechsel fehlgeschlagen (beamnet logs $nr).")
        fi
    done
    return 0
}

# beamnet rotation [<nr> <map> <map> … | <nr> aus]: taegliche Map-Rotation festlegen oder anzeigen.
cmd_rotation() {
    local nr m list
    if [[ $# -eq 0 ]]; then
        for nr in $(servers); do
            list=$(conf_get "ROTATE_$nr")
            [[ -n $list ]] && echo "Server $nr: $list"
        done
        echo "Wechsel täglich ab $(conf_get ROTATE_HOUR | grep -E '^[0-9]+$' || echo 6) Uhr, sobald der Server leer ist (braucht beamnet watch)."
        return 0
    fi
    need_root rotation
    nr=$1; shift
    [[ $nr =~ ^[0-9]+$ ]] || die "Aufruf: beamnet rotation <nr> <map> <map> …   (eine Server-Nummer, nicht \"all\")"
    targets "$nr" >/dev/null
    if [[ ${1:-} == aus || ${1:-} == off ]]; then
        conf_set "ROTATE_$nr" ""
        ok "Server $nr: keine Map-Rotation mehr."
        return 0
    fi
    [[ $# -ge 2 ]] || die "Aufruf: beamnet rotation <nr> <map> <map> …   (mindestens zwei Maps) oder: beamnet rotation <nr> aus"
    [[ $(printf '%s\n' "$@" | sort | uniq -d) == "" ]] || die "Jede Map nur einmal angeben."
    for m in "$@"; do
        [[ $m =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]] || die "Ungültiger Map-Name: $m"
        [[ " $(vote_maps) " == *" $m "* ]] || die "$m ist weder Vanilla-Map noch in VOTE_MAPS eingetragen."
    done
    conf_set "ROTATE_$nr" "$*"
    ok "Server $nr: täglich wechselnd $*"
    [[ -f $SYSTEMD_DIR/beamnet-watch.timer ]] || echo "Hinweis: Der Wechsel braucht den Wächter – beamnet watch install"
}

# Spielerrekord: wie viele sind gleichzeitig im ganzen Netzwerk? Neuer Rekord -> Discord (hoechstens alle 30 min),
# Tagesspitze fuer die Tageszusammenfassung, peak.json fuer die Statusseite.
watch_peak() {
    local -n pout=$1
    local nr pl online=0 now today best=0 best_at=0 day_best=0 last_note=0 line
    now=$(date +%s)
    today=$(date +%Y-%m-%d)
    for nr in $(servers); do
        pl=$(players_of "$(cfg "$nr" Port)")
        [[ $pl =~ ^([0-9]+)/ ]] && online=$(( online + BASH_REMATCH[1] ))
    done
    read -r best best_at last_note < <(cat "$STATE_DIR/peak" 2>/dev/null; echo)
    [[ $best =~ ^[0-9]+$ ]] || best=0
    [[ $best_at =~ ^[0-9]+$ ]] || best_at=0
    [[ $last_note =~ ^[0-9]+$ ]] || last_note=0
    day_best=$(cat "$STATE_DIR/peak-$today" 2>/dev/null)
    [[ $day_best =~ ^[0-9]+$ ]] || day_best=0
    if (( online > day_best )); then
        day_best=$online
        echo "$day_best" >"$STATE_DIR/peak-$today"
        find "$STATE_DIR" -maxdepth 1 -name 'peak-*' -mtime +7 -delete 2>/dev/null
    fi
    if (( online > best )); then
        # Erst ab 5 Spielern und mit einem bisherigen Rekord melden (der erste Lauf legt ihn nur fest).
        if (( best > 0 && online >= 5 && now - last_note >= 1800 )); then
            pout+=("🎉 Neuer Spielerrekord: $online Spieler gleichzeitig im Netzwerk (bisher $best)!")
            while IFS= read -r line; do [[ -n $line ]] && pout+=("   $line"); done < <(online_lines)
            last_note=$now
        fi
        best=$online
        best_at=$now
    fi
    echo "$best $best_at $last_note" >"$STATE_DIR/peak"
    # Spitze je Stunde der letzten 7 Tage (fuer das Diagramm auf der Statusseite): "Stundenbeginn Spitze" je Zeile.
    local hour=$(( now / 3600 * 3600 )) hours="" h m found=0
    if [[ -f $STATE_DIR/hours ]]; then
        while read -r h m; do
            [[ $h =~ ^[0-9]+$ && $m =~ ^[0-9]+$ ]] || continue
            (( h > now - 7 * 86400 && h <= hour )) || continue
            if (( h == hour )); then (( online > m )) && m=$online; found=1; fi
            hours+="$h $m"$'\n'
        done <"$STATE_DIR/hours"
    fi
    (( found )) || hours+="$hour $online"$'\n'
    printf '%s' "$hours" >"$STATE_DIR/hours"
    if [[ -d $SHARED && ! -L $SHARED ]]; then
        printf '{"allTime":%s,"allTimeAt":%s,"today":%s,"online":%s,"updated":%s,"hours":[%s]}\n' \
            "$best" "$best_at" "$day_best" "$online" "$now" \
            "$(printf '%s' "$hours" | awk 'NF == 2 { printf "%s[%s,%s]", (n++ ? "," : ""), $1, $2 }')" \
            | safe put "$SHARED/peak.json" 644
    fi
    return 0
}

watch_run() {
    mkdir -p "$STATE_DIR"
    local nr state last name msgs=() auto hang
    auto=$(conf_get AUTO_RESTART)
    watch_heartbeat
    watch_votes msgs
    watch_reports msgs
    watch_modlog msgs
    for nr in $(servers); do
        unit_exists "$nr" || continue
        if unit_active "$nr"; then state=up; else state=down; fi
        last=$(cat "$STATE_DIR/state-$nr" 2>/dev/null || echo "$state")
        name="Server $nr ($(map_short "$(cfg "$nr" Map)"))"
        if [[ $state == up ]]; then
            [[ $last == down ]] && msgs+=("🟢 $name ist wieder online.")
            rm -f "$STATE_DIR/limit-$nr"
            clear_maintenance "$nr"   # laeuft wieder (egal wie gestartet) – Wartung vorbei
            [[ $last == down || ! -f $STATE_DIR/upsince-$nr ]] && date +%s >"$STATE_DIR/upsince-$nr"
            hang=$(hang_check "$nr")
            if [[ -z $hang ]]; then
                rm -f "$STATE_DIR/hang-$nr"
            elif [[ $hang == plugin ]]; then
                [[ -f $STATE_DIR/hang-$nr ]] || msgs+=("🟠 $name läuft, aber BeamNetCore meldet sich nicht mehr (Spieler können weiterfahren; Kilometer und Bestenliste stehen) – beamnet logs $nr.")
                : >"$STATE_DIR/hang-$nr"
            else
                [[ -f $STATE_DIR/hang-$nr ]] || msgs+=("🟠 $name hängt: Dienst läuft, aber kein Lebenszeichen und keine Antwort auf Port $(cfg "$nr" Port).")
                : >"$STATE_DIR/hang-$nr"
                if [[ $auto == 1 ]] && restart_allowed "$nr"; then
                    systemctl restart "$(unit "$nr")"
                    date +%s >"$STATE_DIR/upsince-$nr"
                    rm -f "$STATE_DIR/hang-$nr"
                    if unit_active "$nr"; then msgs+=("🟡 $name nach dem Hängen automatisch neu gestartet.")
                    else state=down; msgs+=("   Neustart von $name fehlgeschlagen (beamnet logs $nr)."); fi
                fi
            fi
        elif [[ -f $STATE_DIR/maintenance-$nr ]] || ! unit_enabled "$nr"; then
            :   # bewusst gestoppt oder ohne Autostart: kein Ausfall
        else
            [[ $last == up ]] && msgs+=("🔴 $name ist ausgefallen.")
            if [[ $auto == 1 ]]; then
                if stopped_by_agent "$nr"; then
                    [[ $last == up ]] && msgs+=("   $name wurde von OpenClaw gestoppt – kein automatischer Neustart.")
                elif restart_allowed "$nr"; then
                    systemctl restart "$(unit "$nr")"
                    if unit_active "$nr"; then
                        state=up
                        msgs+=("🟡 $name automatisch neu gestartet.")
                    else
                        msgs+=("   Neustart von $name fehlgeschlagen (beamnet logs $nr).")
                    fi
                elif [[ ! -f $STATE_DIR/limit-$nr ]]; then
                    : >"$STATE_DIR/limit-$nr"
                    msgs+=("⚠️ $name: zu viele Neustarts in einer Stunde – bitte prüfen (beamnet logs $nr).")
                fi
            fi
        fi
        echo "$state" >"$STATE_DIR/state-$nr"
    done
    watch_rotation msgs
    watch_index
    watch_backup msgs
    watch_peak msgs
    watch_online msgs
    watch_weekly msgs
    watch_season msgs
    watch_daily msgs
    if (( ${#msgs[@]} > 0 )); then
        printf '%s\n' "${msgs[@]}"
        notify "$(printf '%s\n' "${msgs[@]}")"
    fi
    return 0
}

# Bestenlisten-Index fuer das Plugin (ab 1.13): eine Zeile je Spieler in players-index.tsv. So liest jeder Server
# einmal pro Minute eine kleine Datei statt aller Spielerdateien (bei 10 000 Spielern 0,07 s statt 1,4 s je Liste).
# Nur regulaere Dateien, keinen Symlinks folgen; Namen ohne Tabulatoren und Steuerzeichen.
watch_index() {
    [[ -d $SHARED/players && ! -L $SHARED/players && ! -L $SHARED ]] || return 0
    command -v python3 >/dev/null || return 0
    local idx
    idx=$(python3 -I - "$SHARED" <<'PY'
import glob, json, math, os, re, stat, sys, time
shared = sys.argv[1]
ID_OK = re.compile(r"[A-Za-z0-9_-]{1,64}")
KEY_OK = re.compile(r"[A-Za-z0-9-]{1,16}")

def load(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                return None
            r = json.loads(f.read(4 * 1024 * 1024).decode("utf-8"))
    except Exception:
        return None
    return r if isinstance(r, dict) else None

def num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        return ""
    return repr(v) if isinstance(v, float) else str(v)

def key(v):
    return v if isinstance(v, str) and KEY_OK.fullmatch(v) else ""

def text(v):
    return re.sub(r"[\x00-\x1f\x7f]", "", str(v))[:64]

out = [f"# beamnet-index 1 {int(time.time())}"]
for path in sorted(glob.glob(os.path.join(shared, "players", "*.json"))):
    r = load(path)
    if not r or not isinstance(r.get("id"), str) or not ID_OK.fullmatch(r["id"]):
        continue
    month_xp = r.get("monthXp")
    if month_xp is None and all(isinstance(r.get(k), (int, float)) for k in ("xp", "monthStartXp")):
        month_xp = r["xp"] - r["monthStartXp"]       # Datensatz von 1.8
    out.append("\t".join([r["id"], text(r.get("name", "?")), num(r.get("km")), num(r.get("seconds")),
                          num(r.get("bonusXp")), key(r.get("week")), num(r.get("weekKm")), key(r.get("lastWeek")),
                          num(r.get("lastWeekKm")), key(r.get("month")), num(month_xp), key(r.get("lastMonth")),
                          num(r.get("lastMonthXp"))]))
sys.stdout.write("\n".join(out) + "\n")
PY
)
    # Nur einen vollstaendigen Index schreiben (bei einem Fehler bleibt der alte; das Plugin erkennt veraltete).
    [[ $idx == "# beamnet-index 1 "* ]] && printf '%s\n' "$idx" | safe put "$SHARED/players-index.tsv" 644
    return 0
}

# Abstand der "Wer ist online"-Meldung in Minuten (ONLINE_REPORT; 0 = aus, fehlt = 60).
online_report_min() {
    local m
    m=$(conf_get ONLINE_REPORT)
    if [[ $m =~ ^[0-9]{1,4}$ ]]; then echo $(( 10#$m )); else echo 60; fi
}

# "Wer ist online": alle ONLINE_REPORT Minuten die Spieler je Server mit Namen melden – nur, wenn jemand faehrt und
# sich die Runde seit der letzten Meldung geaendert hat (sonst wiederholt sich die Meldung nur).
watch_online() {
    local -n oout=$1
    local every now last=0 lines total=0 nr pl fingerprint line
    every=$(online_report_min)
    (( every > 0 )) || return 0
    notify_configured || return 0
    now=$(date +%s)
    last=$(cat "$STATE_DIR/online-at" 2>/dev/null)
    [[ $last =~ ^[0-9]+$ ]] || last=0
    (( now - last >= every * 60 )) || return 0
    for nr in $(servers); do
        pl=$(players_of "$(cfg "$nr" Port)")
        [[ $pl =~ ^([0-9]+)/ ]] && total=$(( total + BASH_REMATCH[1] ))
    done
    (( total > 0 )) || return 0
    lines=$(online_lines)
    [[ -n $lines ]] || return 0
    fingerprint=$(printf '%s' "$lines" | cksum)
    [[ $fingerprint == "$(cat "$STATE_DIR/online-who" 2>/dev/null)" ]] && return 0
    oout+=("👥 Gerade online: $total Spieler")
    while IFS= read -r line; do [[ -n $line ]] && oout+=("   $line"); done <<<"$lines"
    echo "$now" >"$STATE_DIR/online-at"
    echo "$fingerprint" >"$STATE_DIR/online-who"
    return 0
}

# Montags einmal die Wochensieger der Vorwoche nach Discord (braucht python3 und BeamNetCore-Daten).
watch_weekly() {
    local -n out=$1
    local week dow
    dow=${BEAMNET_DOW:-$(date -u +%u)}
    [[ $dow == 1 && -d $SHARED/players ]] && notify_configured || return 0
    command -v python3 >/dev/null || return 0
    week=$(date -u -d '7 days ago' +%G-W%V)
    [[ -f $STATE_DIR/weekly-$week ]] && return 0
    : >"$STATE_DIR/weekly-$week"
    # Zeile 1: Sieger; Zeile 2: Zahlen der Woche (Fahrer, km, Spitze gleichzeitig, Neue). Nur regulaere Dateien,
    # keinen Symlinks folgen (der Ordner gehoert beammp).
    local lines=() l
    while IFS= read -r l; do lines+=("$l"); done < <(python3 -I - "$week" "$SHARED/players" "$STATE_DIR/hours" <<'PY'
import datetime, glob, json, os, stat, sys, time
week, folder, hours_file = sys.argv[1], sys.argv[2], sys.argv[3]
year, wk = (int(x) for x in week.split("-W"))
start = datetime.datetime.fromisocalendar(year, wk, 1).replace(tzinfo=datetime.timezone.utc).timestamp()
end = start + 7 * 86400

def load(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                return None
            r = json.loads(f.read(4 * 1024 * 1024).decode("utf-8"))
    except Exception:
        return None
    return r if isinstance(r, dict) else None

def number(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None

rows, new = [], 0
for path in glob.glob(folder + "/*.json"):
    r = load(path)
    if not r:
        continue
    km = r.get("weekKm") if r.get("week") == week else r.get("lastWeekKm") if r.get("lastWeek") == week else None
    km = number(km)
    if km and km > 0:
        rows.append((km, str(r.get("name", "?"))))
    first = number(r.get("firstSeen"))
    if first and start <= first < end:
        new += 1
rows.sort(key=lambda x: (-x[0], x[1]))
print(" · ".join(f"{i + 1}. {n} ({k:.1f} km)" for i, (k, n) in enumerate(rows[:3])))
peak, peak_at = 0, 0
try:
    for line in open(hours_file):
        h, m = (int(x) for x in line.split())
        if start <= h < end and m > peak:
            peak, peak_at = m, h
except Exception:
    pass
if rows:
    days = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
    parts = [f"{len(rows)} Fahrer", f"{sum(k for k, _ in rows):.0f} km"]
    if peak > 0:
        lt = time.localtime(peak_at)
        parts.append(f"Spitze {peak} Spieler gleichzeitig ({days[lt.tm_wday]} {lt.tm_hour} Uhr)")
    if new > 0:
        parts.append(f"{new} {'neue Fahrer' if new != 1 else 'neuer Fahrer'}")
    print("📈 Die Woche: " + " · ".join(parts))
PY
)
    [[ -n ${lines[0]:-} ]] && out+=("🏁 Wochensieger ${week/-W/ KW }: ${lines[0]}")
    [[ -n ${lines[1]:-} ]] && out+=("${lines[1]}")
    return 0
}

# Am 1. eines Monats einmal die Saisonsieger des Vormonats nach Discord (aus dem Archiv des Plugins oder den
# Spielerdaten, falls das Archiv noch fehlt).
watch_season() {
    local -n sout=$1
    local month line dom
    dom=${BEAMNET_DOM:-$(date -u +%d)}
    [[ $dom == 01 && -d $SHARED/players ]] && notify_configured || return 0
    command -v python3 >/dev/null || return 0
    month=$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m)
    [[ -f $STATE_DIR/season-$month ]] && return 0
    line=$(python3 -I - "$month" "$SHARED" <<'PY'
import glob, json, os, sys
month, shared = sys.argv[1], sys.argv[2]
def read_nofollow(path, limit=16 * 1024 * 1024):
    """Inhalt einer regulaeren Datei, ohne einem Symlink zu folgen (Ordner gehoeren beammp)."""
    import os as _os, stat as _stat
    fd = _os.open(path, _os.O_RDONLY | _os.O_NOFOLLOW | _os.O_NONBLOCK)
    with _os.fdopen(fd, "rb") as fh:
        if not _stat.S_ISREG(_os.fstat(fh.fileno()).st_mode):
            raise OSError("keine regulaere Datei: " + path)
        return fh.read(limit).decode("utf-8")
rows = []
try:
    rows = [(float(e.get("xp", 0)), str(e.get("name", "?")))
            for e in json.loads(read_nofollow(os.path.join(shared, "seasons", month + ".json"))).get("top", [])
            if isinstance(e, dict)]
except Exception:
    for path in glob.glob(os.path.join(shared, "players", "*.json")):
        try:
            r = json.loads(read_nofollow(path))
        except Exception:
            continue
        xp = r.get("monthXp") if r.get("month") == month else r.get("lastMonthXp") if r.get("lastMonth") == month else None
        if isinstance(xp, (int, float)) and xp > 0:
            rows.append((xp, str(r.get("name", "?"))))
rows.sort(key=lambda x: (-x[0], x[1]))
print(" · ".join(f"{i + 1}. {n} ({int(x)} XP)" for i, (x, n) in enumerate(rows[:3])))
PY
)
    : >"$STATE_DIR/season-$month"
    [[ -n $line ]] && sout+=("🏆 Saisonsieger $month: $line")
    return 0
}

# Einmal am Tag ab DAILY_HOUR (Ortszeit, Standard 22) die Tageszusammenfassung nach Discord: Kilometer, Fahrer,
# Top 3 und neue Streckenrekorde von heute (UTC-Tag wie im Plugin). DAILY_SUMMARY=0 schaltet ab. Ist heute niemand
# gefahren, entfaellt die Meldung (der Tag gilt trotzdem als erledigt).
daily_hour() {
    local h
    h=$(conf_get DAILY_HOUR)
    if [[ $h =~ ^[0-9]{1,2}$ ]] && (( 10#$h <= 23 )); then echo $(( 10#$h )); else echo 22; fi
}

watch_daily() {
    local -n dout=$1
    local hour today line
    [[ $(conf_get DAILY_SUMMARY) == 0 ]] && return 0
    [[ -d $SHARED/players && ! -L $SHARED/players ]] && notify_configured || return 0
    command -v python3 >/dev/null || return 0
    hour=${BEAMNET_HOUR:-$(date +%H)}
    (( 10#$hour >= $(daily_hour) )) || return 0
    today=$(date +%Y-%m-%d)
    [[ -f $STATE_DIR/daily-$today ]] && return 0
    # Nur regulaere Dateien, keinen Symlinks folgen, nicht an FIFOs haengen bleiben (Ordner gehoeren beammp).
    line=$(python3 -I - "$(( $(date +%s) / 86400 ))" "$SHARED" <<'PY'
import glob, json, os, stat, sys
day, shared = int(sys.argv[1]), sys.argv[2]

def load(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                return None
            r = json.loads(f.read(4 * 1024 * 1024).decode("utf-8"))
    except Exception:
        return None
    return r if isinstance(r, dict) else None

rows = []
for path in glob.glob(os.path.join(shared, "players", "*.json")):
    r = load(path)
    km = r.get("dayKm") if r and r.get("day") == day else None
    if isinstance(km, (int, float)) and not isinstance(km, bool) and km > 0:
        rows.append((float(km), str(r.get("name", "?"))))
if not rows:
    sys.exit(0)
records = 0
races = os.path.join(shared, "races")
if os.path.isdir(races) and not os.path.islink(races):
    for path in glob.glob(os.path.join(races, "*.json")):
        tracks = (load(path) or {}).get("tracks")
        for t in (tracks.values() if isinstance(tracks, dict) else []):
            recs = t.get("records") if isinstance(t, dict) else None
            best = recs[0] if isinstance(recs, list) and recs else None
            at = best.get("at") if isinstance(best, dict) else None
            if isinstance(at, (int, float)) and not isinstance(at, bool) and int(at // 86400) == day:
                records += 1
rows.sort(key=lambda x: (-x[0], x[1]))
total = sum(k for k, _ in rows)
parts = [f"{total:.1f} km von {len(rows)} " + ("Fahrer" if len(rows) == 1 else "Fahrern"),
         "Top: " + " · ".join(f"{i + 1}. {n} ({k:.1f} km)" for i, (k, n) in enumerate(rows[:3]))]
if records:
    parts.append("1 neuer Streckenrekord" if records == 1 else f"{records} neue Streckenrekorde")
print(" · ".join(parts))
PY
)
    # Erst als erledigt merken, wenn es etwas zu melden gab – wer nach DAILY_HOUR losfaehrt, kommt noch in die Meldung.
    if [[ -n $line ]]; then
        local peak
        peak=$(cat "$STATE_DIR/peak-$today" 2>/dev/null)
        [[ $peak =~ ^[0-9]+$ ]] && (( peak > 1 )) && line+=" · Spitze: $peak Spieler gleichzeitig"
        : >"$STATE_DIR/daily-$today"
        dout+=("📊 Heute im Netzwerk: $line")
    fi
    find "$STATE_DIR" -maxdepth 1 -name 'daily-*' -mtime +7 -delete 2>/dev/null
    return 0
}

watch_install() {
    need_root watch
    local self
    self=$(readlink -f "${BASH_SOURCE[0]}")
    mkdir -p "$STATE_DIR" "$SYSTEMD_DIR"
    if [[ ! -f $CONF ]]; then
        cat >"$CONF" <<'EOF'
# BeamNet-Waechter (beamnet watch) – Aenderungen gelten ab dem naechsten Lauf (jede Minute).
#
# Discord-Webhook: Discord-Server → Servereinstellungen → Integrationen → Webhooks → Neuer Webhook → URL kopieren.
# Leer = keine Discord-Meldungen.
DISCORD_WEBHOOK=
# Telegram: Bot bei @BotFather anlegen (/newbot) → Token hier eintragen. Chat-ID: dem Bot einmal schreiben (oder ihn
# in die Gruppe holen) und https://api.telegram.org/bot<TOKEN>/getUpdates aufrufen → "chat":{"id":…}.
# Gruppen haben eine negative ID; Kanaele gehen auch als @Kanalname. Leer = kein Telegram.
TELEGRAM_TOKEN=
TELEGRAM_CHAT=
# "Wer ist online" (Spieler je Server mit Namen) alle N Minuten an Discord/Telegram, wenn jemand faehrt und sich die
# Runde geaendert hat. 0 = aus.
ONLINE_REPORT=60
# 1 = ausgefallene Server automatisch neu starten (hoechstens 3x pro Stunde; nicht, wenn mit "beamnet stop"
# gestoppt oder von OpenClaw gestoppt). 0 = nur melden.
AUTO_RESTART=0
# Map-Abstimmung im Chat (/vote map <Name>): 1 = an, 0 = aus. Erlaubt sind die Vanilla-Maps; weitere (z. B. Mod-Maps,
# die alle Spieler haben) mit Leerzeichen getrennt in VOTE_MAPS.
MAP_VOTE=1
VOTE_MAPS=
# Tageszusammenfassung in Discord (Kilometer, Top 3, neue Streckenrekorde): 1 = an, 0 = aus.
# DAILY_HOUR = ab dieser Stunde (Ortszeit, 0-23) einmal am Tag; ist heute niemand gefahren, kommt keine Meldung.
DAILY_SUMMARY=1
DAILY_HOUR=22
# Moderation (Bann, Kick, Stummschaltung, Verwarnung) an Discord/Telegram melden: 1 = an, 0 = aus.
MODLOG_NOTIFY=1
# Taegliche Datensicherung der Spielerdaten nach /root/beamnet-backups/daten-<Datum>.tgz: ab BACKUP_HOUR Uhr,
# BACKUP_KEEP Tage aufbewahren (zurueckholen: beamnet restore). DATA_BACKUP=0 schaltet ab.
DATA_BACKUP=1
BACKUP_HOUR=4
BACKUP_KEEP=14
# Haengt ein Server (Dienst laeuft, aber seit HANG_MIN Minuten kein Lebenszeichen von BeamNetCore)? Antwortet er auch
# auf seinem Port nicht mehr, startet ihn der Waechter mit AUTO_RESTART=1 neu; sonst nur Meldung. 0 = aus.
HANG_MIN=3
EOF
        chmod 600 "$CONF"
    fi
    cat >"$SYSTEMD_DIR/beamnet-watch.service" <<EOF
[Unit]
Description=BeamNet-Waechter (prueft die BeamMP-Server)

[Service]
Type=oneshot
ExecStart=$self watch
EOF
    cat >"$SYSTEMD_DIR/beamnet-watch.timer" <<'EOF'
[Unit]
Description=BeamNet-Waechter jede Minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now beamnet-watch.timer >/dev/null 2>&1
    ok "Wächter eingerichtet (läuft jede Minute). Einstellungen: $CONF"
    echo "Discord und automatischer Neustart sind aus, bis du sie dort einträgst."
}

watch_uninstall() {
    need_root watch
    systemctl disable --now beamnet-watch.timer >/dev/null 2>&1
    rm -f "$SYSTEMD_DIR/beamnet-watch.service" "$SYSTEMD_DIR/beamnet-watch.timer"
    systemctl daemon-reload
    ok "Wächter entfernt (Einstellungen in $CONF bleiben)."
}

cmd_watch() {
    case ${1:-run} in
        run) need_root watch; watch_run ;;
        install) watch_install ;;
        uninstall) watch_uninstall ;;
        test)
            notify_configured || die "Weder DISCORD_WEBHOOK noch TELEGRAM_TOKEN/TELEGRAM_CHAT in $CONF eingetragen."
            notify "✅ BeamNet-Wächter: Testnachricht von $(hostname 2>/dev/null)" && ok "Testnachricht gesendet."
            ;;
        status)
            if [[ -f $SYSTEMD_DIR/beamnet-watch.timer ]]; then ok "Wächter eingerichtet"; else echo "Wächter nicht eingerichtet (beamnet watch install)."; fi
            if [[ -n $(conf_get DISCORD_WEBHOOK) ]]; then echo "Discord: an"; else echo "Discord: aus"; fi
            if [[ -n $(conf_get TELEGRAM_TOKEN) && -n $(conf_get TELEGRAM_CHAT) ]]; then echo "Telegram: an"; else echo "Telegram: aus"; fi
            if [[ $(conf_get DATA_BACKUP) == 0 ]]; then echo "Datensicherung: aus"
            else echo "Datensicherung: täglich ab $(backup_hour) Uhr ($(find "$BACKUP_DIR" -maxdepth 1 -name 'daten-*.tgz' 2>/dev/null | wc -l) vorhanden, beamnet restore)"; fi
            if (( $(online_report_min) > 0 )) && notify_configured; then echo "Wer-ist-online-Meldung: alle $(online_report_min) Minuten"
            else echo "Wer-ist-online-Meldung: aus"; fi
            if [[ $(conf_get AUTO_RESTART) == 1 ]]; then echo "Automatischer Neustart: an"; else echo "Automatischer Neustart: aus"; fi
            if [[ $(conf_get MAP_VOTE) == 0 ]]; then echo "Map-Abstimmung: aus"; else echo "Map-Abstimmung: an ($(vote_maps | wc -w) Maps)"; fi
            if [[ $(conf_get DAILY_SUMMARY) == 0 ]] || ! notify_configured; then echo "Tageszusammenfassung: aus"
            else echo "Tageszusammenfassung: an (täglich ab $(daily_hour) Uhr)"; fi
            ls "$STATE_DIR"/maintenance-* >/dev/null 2>&1 && echo "In Wartung (bewusst gestoppt): $(ls "$STATE_DIR"/maintenance-* | sed 's/.*maintenance-//' | tr '\n' ' ')"
            return 0
            ;;
        *) die "Aufruf: beamnet watch [install|uninstall|status|test]" ;;
    esac
}

# ---------------------------------------------------------------------------------------------------------------------
# Admins (config.json von BeamNetCore; das Plugin liest sie jede Minute neu)

cmd_admin() {
    local action=${1:-list}
    [[ $# -gt 0 ]] && shift
    command -v python3 >/dev/null || die "python3 fehlt (apt install python3)."
    case $action in
        list|add|remove) ;;
        *) die "Aufruf: beamnet admin list | add <Name …> | remove <Name …>" ;;
    esac
    [[ $action == list || $# -gt 0 ]] || die "Aufruf: beamnet admin $action <BeamMP-Name oder -ID …>"
    [[ $action == list ]] || { need_root admin; ensure_shared; }
    local out
    out=$(mktemp)
    python3 -I - "$SHARED/config.json" "$out" "$action" "$@" <<'PY' || { rm -f "$out"; exit 1; }
import json, os, re, sys
path, out, action, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
def read_nofollow(path, limit=16 * 1024 * 1024):
    """Inhalt einer regulaeren Datei, ohne einem Symlink zu folgen (Ordner gehoeren beammp)."""
    import os as _os, stat as _stat
    fd = _os.open(path, _os.O_RDONLY | _os.O_NOFOLLOW | _os.O_NONBLOCK)
    with _os.fdopen(fd, "rb") as fh:
        if not _stat.S_ISREG(_os.fstat(fh.fileno()).st_mode):
            raise OSError("keine regulaere Datei: " + path)
        return fh.read(limit).decode("utf-8")
try:
    cfg = json.loads(read_nofollow(path))
    if not isinstance(cfg, dict):
        raise ValueError
except FileNotFoundError:
    cfg = {}
except Exception:
    print("config.json ist fehlerhaft – bitte zuerst reparieren oder löschen.")
    sys.exit(1)
admins = [str(a) for a in cfg.get("admins", []) if isinstance(a, (str, int))]
if action == "list":
    print("Admins: " + (", ".join(admins) if admins else "keine (beamnet admin add <Name>)"))
    sys.exit(0)
for name in names:
    if not re.fullmatch(r"[\w .-]{1,32}", name):
        print(f'Ungültiger Name: "{name}"')
        sys.exit(1)
    known = [a for a in admins if a.lower() == name.lower()]
    if action == "add" and not known:
        admins.append(name)
    if action == "remove":
        admins = [a for a in admins if a.lower() != name.lower()]
cfg["admins"] = admins
with open(out, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
print("Admins: " + (", ".join(admins) if admins else "keine"))
print("Wirksam innerhalb einer Minute auf allen Servern.")
PY
    # Ablegen ohne Symlinks zu folgen (der Ordner gehoert dem Dienst-Benutzer).
    if [[ -s $out ]]; then safe put "$SHARED/config.json" 664 "$SERVICE_USER" <"$out" || { rm -f "$out"; die "config.json konnte nicht geschrieben werden."; }; fi
    rm -f "$out"
    return 0
}

# Setzt KEY=Wert in /etc/beamnet.conf (legt die Datei bei Bedarf an).
conf_set() {
    local key=$1 value=$2 tmp
    if [[ ! -f $CONF ]]; then : >"$CONF"; chmod 600 "$CONF"; fi
    tmp=$(mktemp)
    awk -v k="$key" -v v="$value" '
        $0 ~ "^[[:space:]]*" k "=" { if (!done) print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }' "$CONF" >"$tmp" && cat "$tmp" >"$CONF"
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------------------------------------------------
# Einrichtungs-Assistent

ask() {   # ask <Frage> <Vorgabe>: Antwort auf stdout (bei -y oder ohne Eingabe die Vorgabe)
    local answer=""
    if [[ $YES -eq 1 ]]; then printf '%s' "$2"; return; fi
    read -r -p "$1 " answer || answer=""
    printf '%s' "${answer:-$2}"
}

# Fuehrt einen Schritt des Assistenten in einer Unterschale aus: ein Fehler (exit/die) beendet nur diesen Schritt.
step() {
    ( "$@" ) || warn "Dieser Schritt hat nicht geklappt – es geht mit dem nächsten weiter."
    return 0
}

cmd_setup() {
    need_root setup
    local saved_yes=$YES names webhook token chat port old found=""
    title "BeamNet-Einrichtung · Werkzeug $VERSION"
    echo "Ich gehe Schritt für Schritt durch und frage vor jedem Schritt (Enter = überspringen)."

    title "Schritt 1/9: Diagnose (ändert nichts)"
    cmd_doctor

    title "Schritt 2/9: Sicherung"
    if confirm "Konfigurationen, Plugins und Dienste sichern?"; then step cmd_backup; fi

    title "Schritt 3/9: OpenClaw"
    if id "$AGENT_USER" >/dev/null 2>&1 && [[ -n $(pgrep -u "$AGENT_USER" -f openclaw 2>/dev/null) ]]; then
        echo "Der OpenClaw-Agent läuft. Er hat im Juli Server immer wieder gestoppt."
        if confirm "OpenClaw anhalten (einfrieren, jederzeit fortsetzbar mit: beamnet openclaw resume)?"; then
            YES=1; step cmd_openclaw pause; YES=$saved_yes
        fi
    else
        ok "OpenClaw läuft nicht – nichts zu tun."
    fi

    title "Schritt 4/9: Reparieren und starten"
    if confirm "Wilde Prozesse beenden, Rechte setzen, Autostart an, alle Server starten (beamnet fix)?"; then
        YES=1; step cmd_fix; YES=$saved_yes
    fi

    title "Schritt 5/9: Plugin BeamNetCore"
    if confirm "BeamNetCore (km, XP, Liga, Rennen, Moderation, /server) auf allen Servern installieren?"; then
        YES=1; step cmd_install_core; YES=$saved_yes
        for old in XPSystem LigaSystem Rankings; do
            [[ -n $(find "$ROOT"/*/Resources/Server -maxdepth 1 -name "$old" 2>/dev/null | head -n1) ]] && found+="$old "
        done
        if [[ -n $found ]] && confirm "Alte Plugins mit gleichen Aufgaben abschalten (${found% })? Sie werden nur verschoben."; then
            for old in $found; do YES=1; step cmd_plugin_toggle disable "$old"; YES=$saved_yes; done
        fi
    fi

    title "Schritt 6/9: Admins"
    names=$(ask "BeamMP-Namen der Admins, durch Leerzeichen getrennt (Enter = überspringen):" "")
    names=${names//,/ }
    # shellcheck disable=SC2086
    [[ -n ${names// /} ]] && step cmd_admin add $names

    title "Schritt 7/9: Wächter (meldet Ausfälle, optional Discord und Neustart)"
    if confirm "Wächter einrichten?"; then
        step watch_install
        webhook=$(ask "Discord-Webhook-URL (Enter = keiner):" "")
        if [[ -n $webhook ]]; then
            if [[ $webhook =~ ^https://(discord|discordapp)\.com/api/webhooks/[A-Za-z0-9/_-]+$ ]]; then
                conf_set DISCORD_WEBHOOK "$webhook"
                ok "Discord-Webhook gespeichert (Test: beamnet watch test)"
            else
                warn "Das ist keine Discord-Webhook-URL – nicht gespeichert."
            fi
        fi
        token=$(ask "Telegram-Bot-Token von @BotFather (Enter = kein Telegram):" "")
        if [[ -n $token ]]; then
            if [[ $token =~ ^[0-9]{5,}:[A-Za-z0-9_-]{20,}$ ]]; then
                chat=$(ask "Telegram-Chat-ID (Zahl; Gruppen negativ) oder @Kanalname:" "")
                if [[ $chat =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,})$ ]]; then
                    conf_set TELEGRAM_TOKEN "$token"; conf_set TELEGRAM_CHAT "$chat"
                    ok "Telegram gespeichert (Test: beamnet watch test)"
                else
                    warn "Das ist keine Chat-ID – Telegram nicht gespeichert."
                fi
            else
                warn "Das ist kein Bot-Token (123456:ABC…) – Telegram nicht gespeichert."
            fi
        fi
        if confirm "Ausgefallene Server automatisch neu starten (höchstens 3x pro Stunde)?"; then conf_set AUTO_RESTART 1; fi
    fi

    title "Schritt 8/9: Statusseite"
    if confirm "Statusseite als Webseite bereitstellen?"; then
        port=$(ask "Port (Enter = 8080):" "8080")
        if [[ $port =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )); then
            step web_install "$port"
        else
            warn "Ungültiger Port '$port' – Statusseite übersprungen (später: beamnet web install <port>)."
        fi
    fi

    title "Schritt 9/9: Neustart (meist nicht nötig)"
    echo "Plugins lädt BeamMP im laufenden Betrieb neu. Ein Neustart hilft nur, wenn beamnet doctor danach meldet,"
    echo "dass sich BeamNetCore nicht meldet."
    if confirm "Trotzdem alle Server jetzt neu starten? Spieler fliegen kurz raus."; then
        YES=1; step cmd_restart all; YES=$saved_yes
    fi

    title "Fertig"
    cmd_status
    echo
    echo "Zum Teilen mit mir: beamnet report   ·   Hilfe: beamnet hilfe"
}

# ---------------------------------------------------------------------------------------------------------------------
# Moderation (Daten von BeamNetCore)

cmd_bans() {
    command -v python3 >/dev/null || die "python3 fehlt (apt install python3)."
    python3 -I - "$SHARED/bans.json" <<'PY'
import json, sys, time
def read_nofollow(path, limit=16 * 1024 * 1024):
    """Inhalt einer regulaeren Datei, ohne einem Symlink zu folgen (Ordner gehoeren beammp)."""
    import os as _os, stat as _stat
    fd = _os.open(path, _os.O_RDONLY | _os.O_NOFOLLOW | _os.O_NONBLOCK)
    with _os.fdopen(fd, "rb") as fh:
        if not _stat.S_ISREG(_os.fstat(fh.fileno()).st_mode):
            raise OSError("keine regulaere Datei: " + path)
        return fh.read(limit).decode("utf-8")
try:
    data = json.loads(read_nofollow(sys.argv[1]))
except FileNotFoundError:
    print("Keine Banns.")
    sys.exit(0)
except Exception:
    print("bans.json ist fehlerhaft.")
    sys.exit(1)
now = time.time()
bans = [b for b in data.get("bans", []) if isinstance(b, dict)]
active = [b for b in bans if not b.get("until") or b["until"] > now]
if not active:
    print("Keine aktiven Banns.")
for b in active:
    until = time.strftime("%d.%m.%Y %H:%M", time.localtime(b["until"])) if b.get("until") else "dauerhaft"
    who = b.get("id") or ("IP " + b["ip"] if b.get("ip") else "?")
    print(f"{b.get('name', '?')} ({who}) – {b.get('reason') or 'ohne Grund'} – bis {until} – von {b.get('by', '?')}")
if len(bans) > len(active):
    print(f"({len(bans) - len(active)} abgelaufene Banns gespeichert)")
PY
}

cmd_unban() {
    need_root unban
    [[ $# -ge 1 ]] || die "Aufruf: beamnet unban <Name oder BeamMP-ID>"
    command -v python3 >/dev/null || die "python3 fehlt (apt install python3)."
    local out
    out=$(mktemp)
    python3 -I - "$SHARED/bans.json" "$*" "$out" <<'PY' || { rm -f "$out"; exit 1; }
import json, os, sys
path, query, out = sys.argv[1], sys.argv[2].lower(), sys.argv[3]
def read_nofollow(path, limit=16 * 1024 * 1024):
    """Inhalt einer regulaeren Datei, ohne einem Symlink zu folgen (Ordner gehoeren beammp)."""
    import os as _os, stat as _stat
    fd = _os.open(path, _os.O_RDONLY | _os.O_NOFOLLOW | _os.O_NONBLOCK)
    with _os.fdopen(fd, "rb") as fh:
        if not _stat.S_ISREG(_os.fstat(fh.fileno()).st_mode):
            raise OSError("keine regulaere Datei: " + path)
        return fh.read(limit).decode("utf-8")
try:
    data = json.loads(read_nofollow(path))
    if not isinstance(data, dict):
        raise ValueError
except FileNotFoundError:
    print("Keine Banns.")
    sys.exit(1)
except Exception:
    print("bans.json ist fehlerhaft – bitte prüfen (Sicherungen: beamnet backup).")
    sys.exit(1)
bans = [b for b in data.get("bans", []) if isinstance(b, dict)]
kept = [b for b in bans if str(b.get("name", "")).lower() != query and str(b.get("id", "")) != query]
if len(kept) == len(bans):
    print(f'Kein Bann für "{sys.argv[2]}" gefunden.')
    sys.exit(1)
data["bans"] = kept
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False)
print(f'Bann für "{sys.argv[2]}" aufgehoben ({len(bans) - len(kept)}).')
PY
    if [[ -s $out ]]; then safe put "$SHARED/bans.json" 664 "$SERVICE_USER" <"$out" || { rm -f "$out"; die "bans.json konnte nicht geschrieben werden."; }; fi
    rm -f "$out"
    return 0
}

cmd_modlog() {
    local lines=${1:-20}
    [[ $lines =~ ^[0-9]+$ ]] || die "Aufruf: beamnet modlog [anzahl]"
    [[ -f $SHARED/modlog.jsonl ]] || { echo "Noch keine Moderation protokolliert."; return 0; }
    command -v python3 >/dev/null || { tail -n "$lines" "$SHARED/modlog.jsonl"; return 0; }
    tail -n "$lines" "$SHARED/modlog.jsonl" | python3 -I -c '
import json, sys, time
for line in sys.stdin:
    try:
        e = json.loads(line)
    except Exception:
        continue
    when = time.strftime("%d.%m. %H:%M", time.localtime(e.get("at", 0)))
    extra = e.get("reason") or ""
    if e.get("until"):
        extra += " (bis " + time.strftime("%d.%m. %H:%M", time.localtime(e["until"])) + ")"
    print(f"{when} · Port {e.get("server", "?")} · {e.get("by", "System")}: {e.get("action")} {e.get("target", "")} {extra}".rstrip())
'
}

# ---------------------------------------------------------------------------------------------------------------------
# Statusseite

# Erzeugt index.html (und api.json) aus den gemeinsamen Daten von BeamNetCore (Server, Bestenliste, Wochenkilometer, Rekorde).
web_generate() {
    command -v python3 >/dev/null || die "python3 fehlt (apt install python3)."
    mkdir -p "$WEB_DIR" || die "Kann $WEB_DIR nicht anlegen."
    python3 -I - "$SHARED" "$WEB_DIR/index.html" "${1:-BeamNet}" <<'PY'
import glob, html, json, math, os, sys, time

shared, out, title = sys.argv[1], sys.argv[2], sys.argv[3] or "BeamNet"
now = time.time()
E = html.escape


def read_nofollow(path, limit=16 * 1024 * 1024):
    """Inhalt einer regulaeren Datei, ohne einem Symlink zu folgen (Ordner gehoeren beammp)."""
    import os as _os, stat as _stat
    fd = _os.open(path, _os.O_RDONLY | _os.O_NOFOLLOW | _os.O_NONBLOCK)
    with _os.fdopen(fd, "rb") as fh:
        if not _stat.S_ISREG(_os.fstat(fh.fileno()).st_mode):
            raise OSError("keine regulaere Datei: " + path)
        return fh.read(limit).decode("utf-8")


def load(path):
    try:
        return json.loads(read_nofollow(path))
    except Exception:
        return None


def num(v, default=0.0):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else default


cfg = load(os.path.join(shared, "config.json"))
cfg = cfg if isinstance(cfg, dict) else {}
xp_km, xp_min, base = num(cfg.get("xpPerKm"), 10), num(cfg.get("xpPerMinute"), 1), num(cfg.get("levelBase"), 25) or 25
leagues = cfg.get("leagues")
if not (isinstance(leagues, list) and leagues and all(isinstance(l, dict) and isinstance(l.get("name"), str) for l in leagues)):
    leagues = [{"xp": 0, "name": "Bronze"}, {"xp": 500, "name": "Silber"}, {"xp": 2000, "name": "Gold"},
               {"xp": 6000, "name": "Platin"}, {"xp": 15000, "name": "Diamant"}, {"xp": 40000, "name": "Legende"}]


def xp_of(r):
    if isinstance(r.get("xp"), (int, float)):
        return int(r["xp"])
    return int(num(r.get("km")) * xp_km + num(r.get("seconds")) / 60 * xp_min + num(r.get("bonusXp")))


def level_of(xp):
    return int(math.sqrt(xp / base)) + 1 if xp > 0 else 1


def league_of(xp):
    name = leagues[0]["name"]
    for l in leagues:
        if xp >= num(l.get("xp")):
            name = l["name"]
    return name


def km(v):
    return f"{v:.0f} km" if v >= 100 else f"{v:.1f} km"


MAPS = {"gridmap_v2": "Grid Map", "smallgrid": "Small Grid", "west_coast_usa": "West Coast, USA",
        "east_coast_usa": "East Coast, USA", "italy": "Italy", "utah": "Utah, USA", "jungle_rock_island": "Jungle Rock Island",
        "small_island": "Small Island, USA", "hirochi_raceway": "Hirochi Raceway", "johnson_valley": "Johnson Valley",
        "industrial": "Industrial Site", "derby": "Derby Arenas", "automation_test_track": "Automation Test Track"}


def map_name(m):
    m = str(m)
    return MAPS.get(m) or m.replace("_", " ").title()


def race_time(t):
    t = max(0.0, num(t))
    return f"{int(t // 60)}:{t % 60:04.1f}"


week = time.strftime("%G-W%V", time.gmtime(now))
month = time.strftime("%Y-%m", time.gmtime(now))
MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]
season_title = f"{MONTHS[int(month[5:7]) - 1]} {month[:4]}"
servers = [s for s in (load(p) for p in glob.glob(os.path.join(shared, "servers", "*.json")))
           if isinstance(s, dict) and now - num(s.get("updated")) <= 90]
servers.sort(key=lambda s: num(s.get("port")))
players = [r for r in (load(p) for p in glob.glob(os.path.join(shared, "players", "*.json")))
           if isinstance(r, dict) and r.get("id")]
by_xp = sorted(players, key=lambda r: (-xp_of(r), str(r.get("name", ""))))[:10]
by_week = sorted([r for r in players if r.get("week") == week and num(r.get("weekKm")) > 0],
                 key=lambda r: (-num(r.get("weekKm")), str(r.get("name", ""))))[:10]
races = []
for path in sorted(glob.glob(os.path.join(shared, "races", "*.json"))):
    data = load(path)
    tracks = data.get("tracks") if isinstance(data, dict) else None
    if not isinstance(tracks, dict):
        continue
    for name, t in sorted(tracks.items()):
        recs = t.get("records") if isinstance(t, dict) else None
        if isinstance(recs, list) and recs and isinstance(recs[0], dict):
            races.append((os.path.basename(path)[:-5], name, recs[0]))

ID_OK = __import__("re").compile(r"^[A-Za-z0-9_-]{1,64}$")


def link(r, prefix=""):
    """Name als Link auf die Profilseite (nur bei unbedenklicher ID)."""
    name = E(str(r.get("name", "?")))
    rid = str(r.get("id", ""))
    return f'<a href="{prefix}p/{rid}.html">{name}</a>' if ID_OK.fullmatch(rid) else name


online = sum(int(num(s.get("players"))) for s in servers)
profile_ids = {str(r.get("id")) for r in players if ID_OK.fullmatch(str(r.get("id", "")))}
rows = []
for s in servers:
    names = s.get("names") if isinstance(s.get("names"), list) else []
    ids = s.get("ids") if isinstance(s.get("ids"), list) and len(s.get("ids")) == len(names) else [""] * len(names)
    # Namen mit Profilseite (BeamNetCore 1.14+ meldet die IDs) werden verlinkt, Gaeste und Neue nicht.
    who = ", ".join(link({"name": n, "id": i}) if isinstance(i, str) and i in profile_ids else E(str(n))
                    for n, i in zip(names, ids))
    rows.append(f"<tr><td><b>{E(str(s.get('name', '?')))}</b>" + (f"<div class=small>{who}</div>" if who else "") +
                f"</td><td>{E(map_name(s.get('map', '?')))}</td>"
                f"<td class=n>{int(num(s.get('players')))}/{int(num(s.get('max')))}</td></tr>")
def achievements(r):
    a = r.get("achievements")
    return len(a) if isinstance(a, dict) else 0


top = [f"<tr><td class=n>{i}</td><td>{link(r)}</td><td class=n>{level_of(xp_of(r))}</td>"
       f"<td>{E(league_of(xp_of(r)))}</td><td class=n>{xp_of(r)}</td><td class=n>{km(num(r.get('km')))}</td>"
       f"<td class=n>{achievements(r)}</td></tr>"
       for i, r in enumerate(by_xp, 1)]
weekly = [f"<tr><td class=n>{i}</td><td>{link(r)}</td><td class=n>{km(num(r.get('weekKm')))}</td></tr>"
          for i, r in enumerate(by_week, 1)]
def month_xp(r):
    """Saison-XP: Zaehler monthXp (ab 1.9) oder Stand minus Startwert (1.8)."""
    if r.get("month") != month:
        return 0
    if isinstance(r.get("monthXp"), (int, float)):
        return int(r["monthXp"])
    if isinstance(r.get("monthStartXp"), (int, float)):
        return int(xp_of(r) - r["monthStartXp"])
    return 0


season_all = sorted([(month_xp(r), str(r.get("name", "?")), r) for r in players if month_xp(r) > 0],
                    key=lambda x: (-x[0], x[1]))
season = season_all[:10]
season_rows = [f"<tr><td class=n>{i}</td><td>{link(r)}</td><td class=n>{xp}</td></tr>" for i, (xp, n, r) in enumerate(season, 1)]
def map_km(r):
    mk = r.get("mapKm")
    return {str(m): num(v) for m, v in mk.items() if num(v) > 0} if isinstance(mk, dict) else {}


popular = {}
for r in players:
    for m, v in map_km(r).items():
        tot, drivers = popular.get(m, (0.0, 0))
        popular[m] = (tot + v, drivers + 1)
popular_rows = [f"<tr><td>{E(map_name(m))}</td><td class=n>{km(v)}</td><td class=n>{d}</td></tr>"
                for m, (v, d) in sorted(popular.items(), key=lambda x: (-x[1][0], x[0]))[:10]]
records = [f"<tr><td>{E(map_name(m))}</td><td>{E(n)}</td><td>{E(str(b.get('name', '?')))}</td><td class=n>{race_time(b.get('time'))}</td></tr>"
           for m, n, b in races]


peak = load(os.path.join(shared, "peak.json"))
peak_text = ""
if isinstance(peak, dict) and num(peak.get("allTime")) > 0:
    peak_text = f" · Rekord: {int(num(peak.get('allTime')))} gleichzeitig"
    if num(peak.get("allTimeAt")) > 0:
        peak_text += f" ({time.strftime('%d.%m.%Y', time.localtime(num(peak.get('allTimeAt'))))})"


DAYS = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]


def parse_hours():
    """Spitze je Stunde der letzten 7 Tage aus peak.json (nur gueltige Ganzzahlen im Zeitfenster)."""
    raw = peak.get("hours") if isinstance(peak, dict) else None
    out = {}
    if not isinstance(raw, list):
        return out
    end = int(now // 3600 * 3600)
    for e in raw:
        if isinstance(e, list) and len(e) == 2 and all(isinstance(v, int) and not isinstance(v, bool) for v in e):
            if end - 167 * 3600 <= e[0] <= end and e[1] >= 0:
                out[e[0]] = max(e[1], out.get(e[0], 0))
    return out


HOURS = parse_hours()


def hours_chart():
    """Balkendiagramm: Spitze je Stunde der letzten 7 Tage, als SVG ohne Skripte (Tooltip je Balken)."""
    by_hour = HOURS
    if not by_hour or max(by_hour.values()) == 0:
        return ""
    end = int(now // 3600 * 3600)
    start = end - 167 * 3600
    top = max(by_hour.values())
    top_at = min(h for h, v in by_hour.items() if v == top)
    w, hgt = 168 * 4, 120
    bars, labels, days = [], [], []
    for i in range(168):
        h = start + i * 3600
        lt = time.localtime(h)
        if lt.tm_hour == 0:
            labels.append(f'<line x1="{i * 4}" y1="0" x2="{i * 4}" y2="{hgt}" class=grid />')
            days.append(f'<span style="left:{i / 168 * 100:.2f}%">{DAYS[lt.tm_wday]}<i> {lt.tm_mday}.</i></span>')
        if h not in by_hour:
            continue
        v = by_hour[h]
        bh = max(1, round(v / top * (hgt - 4))) if v else 0
        tip = f"{DAYS[lt.tm_wday]} {time.strftime('%d.%m. %H', lt)} Uhr: {v} Spieler"
        bars.append(f'<rect x="{i * 4}" y="{hgt - bh}" width="3" height="{bh}"><title>{tip}</title></rect>')
    tl = time.localtime(top_at)
    return (f'<section><h2>Spieler je Stunde (7 Tage)</h2>'
            f'<svg class=chart viewBox="0 0 {w} {hgt}" role="img" aria-label="Spieler je Stunde">'
            f'{"".join(labels)}{"".join(bars)}</svg><div class=days>{"".join(days)}</div>'
            f'<p class=small>Spitze: <b>{top}</b> Spieler gleichzeitig ({DAYS[tl.tm_wday]} {time.strftime("%d.%m. %H", tl)} Uhr)'
            f' · Balken = meiste Spieler in der Stunde</p></section>')


def table(head, body, empty):
    """head: Spaltennamen; ein '#' am Ende markiert Zahlenspalten (rechtsbuendig)."""
    if not body:
        return f"<p class=empty>{empty}</p>"
    cells = "".join(f"<th class=n>{h[:-1]}</th>" if h.endswith("#") and len(h) > 1 else f"<th>{h}</th>" for h in head)
    return "<table><thead><tr>" + cells + "</tr></thead><tbody>" + "".join(body) + "</tbody></table>"


STYLE = f"""<style>
:root {{ --bg:#f6f7f9; --card:#fff; --text:#1d2330; --muted:#6b7385; --line:#e3e6ec; --accent:#e8590c; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#14161b; --card:#1d2027; --text:#e8eaf0; --muted:#9aa2b3; --line:#2c303a; --accent:#ff8a3d; }} }}
* {{ box-sizing:border-box; }}
body {{ margin:0; font:15px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif; background:var(--bg); color:var(--text); }}
main {{ max-width:960px; margin:0 auto; padding:24px 16px 48px; }}
h1 {{ margin:0 0 4px; font-size:28px; }} h1 span {{ color:var(--accent); }}
h2 {{ font-size:17px; margin:0 0 10px; }}
.sub {{ color:var(--muted); margin-bottom:20px; }}
section {{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px; margin-bottom:16px; overflow-x:auto; }}
table {{ width:100%; border-collapse:collapse; }}
th, td {{ text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); vertical-align:top; }}
th {{ color:var(--muted); font-weight:600; font-size:13px; }}
td.n, th.n {{ text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }}
td b {{ font-weight:600; }}
.small {{ font-size:13px; color:var(--muted); }} .empty {{ color:var(--muted); margin:0; }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(300px,1fr)); gap:16px; }} .grid section {{ margin:0; }}
footer {{ color:var(--muted); font-size:12px; margin-top:24px; }}
a {{ color:inherit; text-decoration:none; border-bottom:1px dotted var(--muted); }} a:hover {{ color:var(--accent); }}
.stats {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; margin:0; }}
.stats div {{ background:var(--bg); border-radius:8px; padding:10px 12px; }} .stats b {{ display:block; font-size:20px; }}
.tags span {{ display:inline-block; background:var(--bg); border-radius:999px; padding:3px 10px; margin:0 6px 6px 0; font-size:13px; }}
svg.chart {{ width:100%; height:auto; display:block; }} svg.chart rect {{ fill:var(--accent); }}
svg.chart rect:hover {{ fill:var(--text); }} svg.chart .grid {{ stroke:var(--line); }}
.days {{ position:relative; height:18px; font-size:12px; color:var(--muted); }} .days span {{ position:absolute; top:2px; padding-left:3px; }}
.days i {{ font-style:normal; }} @media (max-width:560px) {{ .days i {{ display:none; }} }}
</style>"""


page = f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60"><title>{E(title)} – Status</title>
{STYLE}</head><body><main>
<h1><span>{E(title)}</span> Status</h1>
<div class=sub>{len(servers)} Server online · {online} Spieler{peak_text} · Stand {time.strftime('%d.%m.%Y %H:%M', time.localtime(now))} (aktualisiert sich jede Minute)</div>
<section><h2>Server</h2>{table(["Server", "Map", "Spieler#"], rows, "Gerade meldet sich kein Server.")}</section>
{hours_chart()}
<section><h2>Bestenliste</h2>{table(["#", "Name", "Level#", "Liga", "XP#", "Kilometer#", "Erfolge#"], top, "Noch keine Einträge – einfach losfahren!")}</section>
<div class=grid>
<section><h2>Diese Woche</h2>{table(["#", "Name", "Kilometer#"], weekly, "Diese Woche ist noch niemand gefahren.")}</section>
<section><h2>Saison {E(season_title)}</h2>{table(["#", "Name", "XP#"], season_rows, "In dieser Saison noch keine Punkte.")}</section>
<section><h2>Streckenrekorde</h2>{table(["Map", "Strecke", "Name", "Zeit#"], records, "Noch keine Rekorde.")}</section>
<section><h2>Beliebteste Maps</h2>{table(["Map", "Kilometer#", "Fahrer#"], popular_rows, "Noch keine Kilometer je Map.")}</section>
</div>
<footer>Chat-Befehle im Spiel: /hilfe · /stats · /top · /liga · /saison · /aufgabe · /erfolge · /server · /rennen · /rekorde · /lang en · <a href="api.json">api.json</a></footer>
</main></body></html>
"""
def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


write(out, page)

# --- api.json: dieselben Daten maschinenlesbar (Discord-Bots, Webseiten) -----------------------------------------------
# Nur ausgewaehlte Felder, damit nie etwas wie IP-Adressen aus den Rohdaten durchrutscht; IDs nur, wenn sie ID_OK sind.
def api_id(r):
    rid = str(r.get("id", ""))
    return rid if ID_OK.fullmatch(rid) else None


api = {
    "generated": int(now),
    "title": title,
    "servers": [{"name": str(s.get("name", "?")), "port": int(num(s.get("port"))), "map": str(s.get("map", "?")),
                 "mapName": map_name(s.get("map", "?")), "players": int(num(s.get("players"))), "max": int(num(s.get("max"))),
                 "names": [str(n) for n in s.get("names")] if isinstance(s.get("names"), list) else []} for s in servers],
    "online": online,
    "top": [{"id": api_id(r), "name": str(r.get("name", "?")), "xp": xp_of(r), "level": level_of(xp_of(r)),
             "league": league_of(xp_of(r)), "km": round(num(r.get("km")), 1)} for r in by_xp],
    "week": [{"id": api_id(r), "name": str(r.get("name", "?")), "km": round(num(r.get("weekKm")), 1)} for r in by_week],
    "season": {"month": month, "title": season_title,
               "top": [{"id": api_id(r), "name": n, "xp": xp} for xp, n, r in season]},
    "records": [{"map": m, "mapName": map_name(m), "track": str(n), "name": str(b.get("name", "?")),
                 "time": round(max(0.0, num(b.get("time"))), 3)} for m, n, b in races],
    "popularMaps": [{"map": m, "mapName": map_name(m), "km": round(v, 1), "drivers": d}
                    for m, (v, d) in sorted(popular.items(), key=lambda x: (-x[1][0], x[0]))[:10]],
    "peak": {"allTime": int(num(peak.get("allTime"))), "allTimeAt": int(num(peak.get("allTimeAt"))),
             "today": int(num(peak.get("today"))),
             "hours": [[h, v] for h, v in sorted(HOURS.items())]} if isinstance(peak, dict) else None,
}
write(os.path.join(os.path.dirname(out), "api.json"), json.dumps(api, ensure_ascii=False, indent=1) + "\n")

# --- Profilseite je Fahrer ------------------------------------------------------------------------------------------
ACH = {"km10": "Erste 10 km", "km100": "100 km", "km1000": "1000 km", "hour1": "1 Stunde unterwegs",
       "hours10": "10 Stunden unterwegs", "speed200": "200 km/h", "speed300": "300 km/h", "race1": "Erstes Rennen",
       "race10": "10 Rennen", "record1": "Streckenrekord", "maps3": "Weltenbummler (3 Maps)",
       "maps8": "Kenner aller Welten (8 Maps)", "level10": "Level 10"}
pdir = os.path.join(os.path.dirname(out), "p")
os.makedirs(pdir, exist_ok=True)
ranked = sorted(players, key=lambda r: (-xp_of(r), str(r.get("name", ""))))
season_rank = {id(r): i for i, (_, _, r) in enumerate(season_all, 1)}
best = {}   # Spieler-ID -> [(Map, Strecke, Zeit, Platz)]
for path in sorted(glob.glob(os.path.join(shared, "races", "*.json"))):
    data = load(path)
    tracks = data.get("tracks") if isinstance(data, dict) else None
    if not isinstance(tracks, dict):
        continue
    for tname, t in sorted(tracks.items()):
        recs = t.get("records") if isinstance(t, dict) else None
        for pos, rec in enumerate(recs if isinstance(recs, list) else [], 1):
            if isinstance(rec, dict) and rec.get("id"):
                best.setdefault(str(rec["id"]), []).append((os.path.basename(path)[:-5], tname, rec.get("time"), pos))


def hours(sec):
    sec = num(sec)
    return f"{sec / 3600:.1f} h" if sec >= 3600 else f"{int(sec // 60)} min"


written = set()
for rank, r in enumerate(ranked, 1):
    rid = str(r.get("id"))
    if not ID_OK.fullmatch(rid):
        continue
    xp = xp_of(r)
    lvl = level_of(xp)
    name = E(str(r.get("name", "?")))
    ach = r.get("achievements") if isinstance(r.get("achievements"), dict) else {}
    maps = r.get("maps") if isinstance(r.get("maps"), dict) else {}
    tags_a = "".join(f"<span>{E(ACH.get(a, a))}</span>" for a in ACH if a in ach) or "<p class=empty>Noch keine Erfolge.</p>"
    mk = map_km(r)
    tags_m = "".join(f"<span>{E(map_name(m))}" + (f" · {km(mk[m])}" if m in mk else "") + "</span>"
                     for m in sorted(set(maps) | set(mk), key=lambda m: (-mk.get(m, 0), m))) or "<p class=empty>Noch keine Map.</p>"
    fav = max(mk.items(), key=lambda x: x[1])[0] if mk else None
    sr = season_rank.get(id(r))
    times = [f"<tr><td>{E(map_name(m))}</td><td>{E(str(t))}</td><td class=n>{race_time(tm)}</td><td class=n>{pos}</td></tr>"
             for m, t, tm, pos in best.get(rid, [])]
    stat = lambda label, value: f"<div>{label}<b>{value}</b></div>"
    body = "".join([
        stat("Level", lvl), stat("Liga", E(league_of(xp))), stat("XP", xp), stat("Rang", f"{rank} von {len(ranked)}"),
        stat("Kilometer", km(num(r.get("km")))), stat("Fahrzeit", hours(r.get("seconds"))),
        stat("Spitze", f"{int(num(r.get('topSpeedKmh')))} km/h"), stat("Rennen", int(num(r.get("racesFinished")))),
        stat(f"Saison {E(season_title)}", f"{month_xp(r)} XP" + (f" · Platz {sr}" if sr else "")),
        stat("Lieblingsmap", E(map_name(fav)) if fav else "–"),
    ])
    profile = f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60"><title>{name} – {E(title)}</title>
{STYLE}</head><body><main>
<div class=sub><a href="../index.html">← {E(title)} Status</a></div>
<h1>{name}</h1>
<div class=sub>Level {lvl} · Liga {E(league_of(xp))}{(" · zuletzt auf " + E(str(r.get("lastServer")))) if r.get("lastServer") else ""}</div>
<section><div class=stats>{body}</div></section>
<section><h2>Erfolge ({len([a for a in ACH if a in ach])} von {len(ACH)})</h2><div class=tags>{tags_a}</div></section>
<div class=grid>
<section><h2>Maps ({len(set(maps) | set(mk))})</h2><div class=tags>{tags_m}</div></section>
<section><h2>Bestzeiten</h2>{table(["Map", "Strecke", "Zeit#", "Platz#"], times, "Noch keine Rennen.")}</section>
</div>
<footer>Stand {time.strftime('%d.%m.%Y %H:%M', time.localtime(now))}</footer>
</main></body></html>
"""
    write(os.path.join(pdir, rid + ".html"), profile)
    written.add(rid + ".html")
# Seiten von Fahrern, die es nicht mehr gibt, entfernen.
for old in glob.glob(os.path.join(pdir, "*.html")):
    if os.path.basename(old) not in written:
        os.remove(old)
PY
}

web_install() {
    need_root web
    local port=$1 self py
    [[ $port =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )) || die "Port muss zwischen 1024 und 65535 liegen."
    py=$(command -v python3) || die "python3 fehlt (apt install python3)."
    self=$(readlink -f "${BASH_SOURCE[0]}")
    web_generate "$(conf_get WEB_TITLE)" || die "Statusseite konnte nicht erzeugt werden."
    chmod 755 "$WEB_DIR"
    mkdir -p "$SYSTEMD_DIR"
    cat >"$SYSTEMD_DIR/beamnet-web.service" <<EOF
[Unit]
Description=BeamNet-Statusseite (Webserver, nur lesend)
After=network.target

[Service]
# Kleiner Webserver mit "Access-Control-Allow-Origin: *", damit andere Seiten api.json abrufen koennen.
ExecStart=$py -c 'import functools,http.server,sys; H=type("H",(http.server.SimpleHTTPRequestHandler,),{"end_headers":lambda s:(s.send_header("Access-Control-Allow-Origin","*"),http.server.SimpleHTTPRequestHandler.end_headers(s))[1]}); http.server.ThreadingHTTPServer((sys.argv[1],int(sys.argv[2])),functools.partial(H,directory=sys.argv[3])).serve_forever()' 0.0.0.0 $port $WEB_DIR
DynamicUser=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
ReadOnlyPaths=$WEB_DIR
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    cat >"$SYSTEMD_DIR/beamnet-web-update.service" <<EOF
[Unit]
Description=BeamNet-Statusseite erneuern

[Service]
Type=oneshot
ExecStart=$self web run
EOF
    cat >"$SYSTEMD_DIR/beamnet-web-update.timer" <<'EOF'
[Unit]
Description=BeamNet-Statusseite jede Minute erneuern

[Timer]
OnBootSec=1min
OnUnitActiveSec=60s
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now beamnet-web.service beamnet-web-update.timer >/dev/null 2>&1
    ok "Statusseite läuft auf Port $port und erneuert sich jede Minute."
    echo "Aufrufen: http://<IP-Adresse des Servers>:$port/"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "Die Firewall (ufw) ist aktiv – Port freigeben mit: ufw allow $port/tcp"
    fi
    echo "Eigener Titel: WEB_TITLE=… in $CONF"
}

web_uninstall() {
    need_root web
    systemctl disable --now beamnet-web.service beamnet-web-update.timer >/dev/null 2>&1
    rm -f "$SYSTEMD_DIR/beamnet-web.service" "$SYSTEMD_DIR/beamnet-web-update.service" "$SYSTEMD_DIR/beamnet-web-update.timer"
    systemctl daemon-reload
    ok "Statusseite abgeschaltet ($WEB_DIR bleibt)."
}

cmd_web() {
    case ${1:-run} in
        run) web_generate "$(conf_get WEB_TITLE)" && echo "Statusseite erzeugt: $WEB_DIR/index.html" ;;
        install) web_install "${2:-8080}" ;;
        uninstall) web_uninstall ;;
        *) die "Aufruf: beamnet web [run|install [port]|uninstall]" ;;
    esac
}

cmd_self_update() {
    need_root self-update
    local target tmp
    target=$(readlink -f "${BASH_SOURCE[0]}")
    tmp=$(mktemp)
    curl -fsSL "$RAW_BASE/beamnet.sh" -o "$tmp" || { rm -f "$tmp"; die "Download fehlgeschlagen"; }
    bash -n "$tmp" || { rm -f "$tmp"; die "Heruntergeladene Datei ist fehlerhaft"; }
    grep -q '^VERSION=' "$tmp" || { rm -f "$tmp"; die "Heruntergeladene Datei ist kein BeamNet-Werkzeug"; }
    # Neue Datei statt Ueberschreiben: das laufende Skript liest so ungestoert weiter.
    if ! { install -m 755 "$tmp" "$target.new" && mv -f "$target.new" "$target"; }; then
        rm -f "$tmp" "$target.new"
        die "Werkzeug konnte nicht ersetzt werden ($target) – alte Version bleibt"
    fi
    rm -f "$tmp"
    ok "Werkzeug aktualisiert: $target (jetzt Version $(grep -m1 '^VERSION=' "$target" | cut -d'"' -f2))"
}

# Werkzeug und Plugin in einem Schritt auf den neuesten Stand bringen.
cmd_update() {
    need_root update
    local target
    target=$(readlink -f "${BASH_SOURCE[0]}")
    cmd_self_update
    echo "Aktualisiere jetzt das Plugin auf allen Servern …"
    # Immer die neueste Plugin-Version von GitHub (nicht eine evtl. veraltete Kopie neben dem Skript).
    export BEAMNET_FORCE_DOWNLOAD=1
    if [[ $YES -eq 1 ]]; then exec "$target" install-core -y; else exec "$target" install-core; fi
}

cmd_help() {
    cat <<EOF
${BOLD}BeamNet $VERSION${RESET} – Werkzeug für die BeamMP-Server unter $ROOT

  beamnet setup                  Geführte Einrichtung: Diagnose, Sicherung, Reparatur, Plugin, Admins, Wächter, Statusseite
  beamnet status                 Übersicht: läuft?, Autostart, Prozess, Port, Spieler, Map
  beamnet doctor                 Diagnose mit Erklärung und Lösung je Problem
  beamnet report                 Bericht zum Teilen (Status, Diagnose, Plugins, Fehlerzeilen; ohne IPs und AuthKeys)
  beamnet fix                    Repariert: wilde root-Prozesse, Dateirechte, Autostart, Start
  beamnet start|stop|restart [nr …|all]
  beamnet maps                   Maps aller Server und verfügbare Vanilla-Maps
  beamnet set-map <nr> <map>     Map ändern (sichert die Konfiguration, fragt vor dem Neustart)
  beamnet rotation [<nr> <map> …|<nr> aus]  Tägliche Map-Rotation (Wechsel, wenn der Server leer ist)
  beamnet logs <nr> [zeilen]     Letzte Zeilen des Server-Protokolls
  beamnet plugins                Installierte Server-Plugins je Server
  beamnet plugin-disable <name>  Plugin auf allen Servern abschalten (verschiebt nach Server.disabled)
  beamnet plugin-enable <name>   … und wieder einschalten
  beamnet players [json]         Wer gerade fährt, je Server mit Namen (mit Plugin BeamNetCore)
  beamnet backup                 Sichert Konfigurationen, Plugins und Dienste nach $BACKUP_DIR
  beamnet restore [JJJJ-MM-TT]   Tägliche Datensicherungen (vom Wächter) anzeigen oder einen Stand zurückholen
  beamnet install-core           Installiert das Plugin BeamNetCore (km, XP, Liga, Rennen, Moderation) auf allen Servern
  beamnet bans · unban <Name> · modlog [n]   Banns ansehen/aufheben, Moderationsprotokoll
  beamnet admin list · add <Name …> · remove <Name …>   Admins für Rennen und Moderation
  beamnet openclaw status|pause|resume   OpenClaw-Agent ansehen, anhalten (einfrieren), fortsetzen
  beamnet watch install|status|test|uninstall   Wächter: Ausfälle, Rekorde, wer online ist – an Discord/Telegram
  beamnet web install [port]     Statusseite (Server, Bestenliste, Rekorde) als Webseite, Standard-Port 8080
  beamnet update                 Werkzeug und Plugin auf allen Servern auf den neuesten Stand bringen
  beamnet self-update            Nur das Werkzeug aktualisieren

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
        rotation|rotate) cmd_rotation "$@" ;;
        logs|log) cmd_logs "$@" ;;
        plugins) cmd_plugins ;;
        plugin-disable) cmd_plugin_toggle disable "$@" ;;
        plugin-enable) cmd_plugin_toggle enable "$@" ;;
        players|spieler) cmd_players "$@" ;;
        backup|sicherung) cmd_backup ;;
        restore|wiederherstellen) cmd_restore "$@" ;;
        install-core) cmd_install_core ;;
        openclaw) cmd_openclaw "$@" ;;
        watch|waechter) cmd_watch "$@" ;;
        web|statusseite) cmd_web "$@" ;;
        bans) cmd_bans ;;
        setup|einrichten) cmd_setup ;;
        admin|admins) cmd_admin "$@" ;;
        unban) cmd_unban "$@" ;;
        modlog) cmd_modlog "$@" ;;
        self-update) cmd_self_update ;;
        update|aktualisieren) cmd_update ;;
        version|--version) echo "BeamNet $VERSION" ;;
        hilfe|help|-h|--help) cmd_help ;;
        *) cmd_help; exit 1 ;;
    esac
}

main "$@"
