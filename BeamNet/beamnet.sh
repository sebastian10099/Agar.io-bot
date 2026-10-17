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

VERSION="2.40"
# Plugin-Version, die zu diesem Werkzeug gehoert (ein Test vergleicht sie mit BN.VERSION in main.lua).
CORE_VERSION="2.03"
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
LOGROTATE_FILE="${BEAMNET_LOGROTATE:-/etc/logrotate.d/beamnet}"
WEB_DIR="${BEAMNET_WEB_DIR:-/var/www/beamnet}"
# Hoechstens so viele automatische Neustarts je Server und Stunde (Schutz vor Endlosschleifen).
MAX_RESTARTS_PER_HOUR=3
RAW_BASE="${BEAMNET_RAW:-https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/friendly-goldberg-31l8fp/BeamNet}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Vanilla-Maps (jeder Spieler hat sie ohne Mods). Andere Maps nur mit --force.
KNOWN_MAPS="gridmap_v2 smallgrid west_coast_usa east_coast_usa italy utah jungle_rock_island small_island hirochi_raceway johnson_valley industrial derby automation_test_track"

YES=0
WARNINGS=0
RESTARTED_NOW=""      # Server, die der Waechter in diesem Lauf schon neu gestartet hat
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
        # Ordner und Datei gehoeren beammp: Symlinks zaehlen nicht (root wuerde sonst fremden Dateien folgen).
        if [[ $name =~ ^[0-9]+$ && ! -L ${dir%/} && ! -L $dir/ServerConfig.toml && -f $dir/ServerConfig.toml ]]; then echo "$name"; fi
    done | sort -n
}

# cfg <nr> <Schluessel>: Wert aus ServerConfig.toml (ohne Anfuehrungszeichen und Kommentar).
cfg() {
    local file="$ROOT/$1/ServerConfig.toml" line
    # Keinen Symlinks folgen; head mit Zeitlimit und Groessengrenze, damit eine untergeschobene FIFO oder Geraetedatei
    # (/proc/kmsg) den Waechter nicht anhaelt.
    [[ -L $ROOT/$1 || -L $file || ! -f $file ]] && return 0
    line=$(timeout 5 head -c 1048576 -- "$file" 2>/dev/null | grep -m1 -E "^[[:space:]]*$2[[:space:]]*=") || return 0
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
    m=${m%%/*}
    # Nur harmlose Zeichen: der Name kommt aus ServerConfig.toml (gehoert beammp) und landet u. a. als Schluessel in
    # Rechenausdruecken (aeltere Bash werten ihn dort erneut aus).
    printf '%s' "${m//[^A-Za-z0-9_.-]/}"
}

# ---------------------------------------------------------------------------------------------------------------------
# Sicheres Schreiben als root in Ordner, die dem Dienst-Benutzer gehoeren (gemeinsamer Ordner, Server-Ordner):
# nie einem Symlink folgen (sonst koennte beammp root dazu bringen, z. B. /etc/passwd zu ueberschreiben).
#   safe put <Datei> <Modus> [<Besitzer>]   – stdin atomar schreiben (exklusive Zwischendatei, dann rename)
#   safe get <Datei>                        – Inhalt ausgeben, nur wenn regulaere Datei und kein Symlink
#   safe mapline <Datei> <Map> <Sicherungsordner> – Map-Zeile ersetzen, Sicherung im root-Ordner (letzte 20)
#   safe keyline <Datei> <Schluessel> <Zahl> <Sicherungsordner> – ebenso fuer eine Zahl (z. B. MaxPlayers)
#   safe chmoddir <Modus> <Ordner …>         – Rechte setzen, ohne Symlinks zu folgen
read -r -d '' SAFE_PY <<'PY'
import os, pwd, re, stat, sys, time

# Oeffnet den Ordner Stueck fuer Stueck ab "/" ohne Symlinks zu folgen – auch nicht in Zwischenordnern (sonst koennte
# beammp z. B. Resources/Server zwischen Pruefung und Schreiben gegen einen Symlink tauschen). Ausnahme: Symlinks,
# die root gehoeren (etwa /var/run -> /run oder ein verlinktes Installationsverzeichnis): die kann beammp nicht anlegen;
# ihr Ziel wird mit denselben Regeln weiterverfolgt.
TRUST_LINK_UID = int(os.environ.get("BEAMNET_TRUST_LINK_UID", "0"))

def opendir(path):
    parts = [p for p in os.path.abspath(path).split("/") if p]
    for _ in range(40):
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        cur, restart = "/", None
        try:
            for i, part in enumerate(parts):
                try:
                    nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                except OSError:
                    st = os.stat(part, dir_fd=fd, follow_symlinks=False)
                    pst = os.fstat(fd)
                    # Nur einem root-Symlink in einem root-Ordner, den sonst niemand beschreiben kann (und der kein
                    # Hardlink ist – sonst koennte beammp ihn an eine andere Stelle verlinken).
                    if (not stat.S_ISLNK(st.st_mode) or st.st_uid != TRUST_LINK_UID or st.st_nlink != 1
                            or pst.st_uid != TRUST_LINK_UID or pst.st_mode & 0o022):
                        raise
                    restart = os.path.normpath(os.path.join(cur, os.readlink(part, dir_fd=fd), *parts[i + 1:]))
                    break
                os.close(fd)
                fd = nfd
                cur = os.path.join(cur, part)
        except BaseException:
            os.close(fd)
            raise
        if restart is None:
            return fd
        os.close(fd)
        parts = [p for p in restart.split("/") if p]
    raise OSError("zu viele Symlinks: " + path)

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
        fd = os.open(base, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    finally:
        os.close(dfd)
    with os.fdopen(fd, "rb") as f:
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise OSError("keine regulaere Datei: " + path)
        # Mehrfach verlinkt: koennte ein Hardlink auf eine fremde Datei sein (z. B. /etc/shadow bei
        # fs.protected_hardlinks=0) – nie lesen und weitergeben.
        if st.st_nlink != 1:
            raise OSError("mehrfach verlinkte Datei: " + path)
        # Riesige (auch duenn belegte) Dateien des Dienst-Benutzers nie ganz in den Speicher von root laden.
        if st.st_size > GET_MAX:
            raise OSError("zu gross: " + path)
        return f.read(GET_MAX + 1), st

cmd = sys.argv[1]
GET_MAX = 64 << 20
try:
    if cmd == "put":
        uid = gid = -1
        if len(sys.argv) > 4 and sys.argv[4]:
            pw = pwd.getpwnam(sys.argv[4])
            uid, gid = pw.pw_uid, pw.pw_gid
        put(sys.argv[2], sys.stdin.buffer.read(), int(sys.argv[3], 8), uid, gid)
    elif cmd == "get":
        sys.stdout.buffer.write(get(sys.argv[2])[0])
    elif cmd in ("mapline", "keyline"):
        if cmd == "mapline":
            path, mp, bdir = sys.argv[2], sys.argv[3], sys.argv[4]
            key, value = "Map", '"/levels/%s/info.json"' % mp
        else:
            # Zahlenwert (z. B. MaxPlayers); nur Buchstaben als Schluessel, nur 1-3 Ziffern als Wert
            path, key, value, bdir = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
            if not re.fullmatch(r"[A-Za-z]+", key) or not re.fullmatch(r"[1-9][0-9]{0,2}", value):
                sys.exit(4)
        data, st = get(path)
        text = data.decode("utf-8", "surrogateescape")
        pattern = re.compile(r"^([ \t]*)" + key + r"[ \t]*=.*$", re.M)
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
        new = pattern.sub(lambda m: m.group(1) + key + " = " + value, text, count=1)
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

NAME_OK = __import__("re").compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
MAX_BYTES, MAX_FILES = 1024 * 1024 * 1024, 200000

def skip_file(name):
    return name.endswith(".tmp") or name == "players-index.tsv" or ".kaputt-" in name

def save(src, dest):
    tmp = dest + ".tmp"
    try:
        _save(src, tmp, set())
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.chmod(tmp, 0o600)
    os.replace(tmp, dest)

def _save(src, tmp, seen):
    count, total = 0, 0
    with tarfile.open(tmp, "w:gz") as tar:
        def walk(dfd, rel, depth):
            nonlocal count, total
            for name in sorted(os.listdir(dfd)):
                # Nur Namen, die die Wiederherstellung auch annimmt (sonst waere die ganze Sicherung unbrauchbar).
                if not NAME_OK.fullmatch(name):
                    continue
                try:
                    st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISDIR(st.st_mode):
                    if depth >= 4 or (rel == "" and name in SKIP_DIRS):
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
                        # Harte Links nie (sonst: eine grosse Datei tausendfach, oder fremde Dateien von root).
                        if not stat.S_ISREG(fst.st_mode) or fst.st_nlink != 1 or fst.st_size > 64 * 1024 * 1024:
                            continue
                        if (fst.st_dev, fst.st_ino) in seen:
                            continue
                        seen.add((fst.st_dev, fst.st_ino))
                        if count >= MAX_FILES or total + fst.st_size > MAX_BYTES:
                            raise ValueError("Datenordner zu gross fuer die Sicherung (mehr als 1 GB oder 200000 Dateien)")
                        data = f.read(fst.st_size + 1)
                        total += len(data)
                    info = tarfile.TarInfo(rel + name)
                    info.size, info.mode, info.mtime = len(data), 0o644, int(fst.st_mtime)
                    tar.addfile(info, io.BytesIO(data))
                    count += 1
        top = os.open(src, FLAGS_DIR)
        try:
            walk(top, "", 0)
        finally:
            os.close(top)
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

def check(archive):
    """Probe-Wiederherstellung ohne zu schreiben: jeder Eintrag sicher, jede Spielerdatei gueltiges JSON."""
    import json
    files = players = broken = 0
    with tarfile.open(archive, "r:gz") as tar:
        total = 0
        for m in tar:
            parts = safe_parts(m.name)
            if not (m.isreg() or m.isdir()):
                raise ValueError("unerlaubter Eintrag im Archiv: " + m.name)
            total += m.size
            if total > 4 * 1024 * 1024 * 1024:
                raise ValueError("Archiv zu gross")
            if not m.isreg():
                continue
            files += 1
            data = tar.extractfile(m).read()
            if len(parts) == 2 and parts[0] == "players" and parts[1].endswith(".json"):
                players += 1
                try:
                    if not isinstance(json.loads(data.decode("utf-8")), dict):
                        raise ValueError
                except Exception:
                    broken += 1
    print(f"{files} {players} {broken}")

def player(archive, query):
    """Eine Spielerdatei aus der Sicherung: "<ID><TAB><JSON>" – gesucht nach ID oder (eindeutigem) Namen."""
    import json, re
    q = query.strip().lower()
    hits = []
    with tarfile.open(archive, "r:gz") as tar:
        for m in tar:
            parts = safe_parts(m.name)
            if not (m.isreg() and len(parts) == 2 and parts[0] == "players" and parts[1].endswith(".json")) or m.size > 4 << 20:
                continue
            pid = parts[1][:-5]
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", pid):
                continue
            try:
                rec = json.loads(tar.extractfile(m).read().decode("utf-8"))
            except Exception:
                continue
            if not isinstance(rec, dict):
                continue
            if pid.lower() == q:
                hits = [(pid, rec)]
                break
            if str(rec.get("name", "")).lower() == q:
                hits.append((pid, rec))
    if len(hits) != 1:
        raise ValueError("nicht gefunden" if not hits else "Name nicht eindeutig – bitte die ID angeben")
    print(hits[0][0] + "\t" + json.dumps(hits[0][1], ensure_ascii=False, separators=(",", ":")))

try:
    if sys.argv[1] == "save":
        save(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "check":
        check(sys.argv[2])
    elif sys.argv[1] == "player":
        player(sys.argv[2], sys.argv[3])
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
# Lebenszeichen aller Server auf einmal lesen: "Port Spieler Max Zeit" je Zeile, nur ganze Zahlen. Der Ordner gehoert
# beammp: ueber einen Ordner-Deskriptor, ohne Symlinks, nie an einer FIFO haengen, hoechstens 64 KB je Datei.
declare -A HB_CACHE=()
HB_LOADED=0
load_heartbeats() {
    local port pl mx up
    HB_CACHE=()
    HB_LOADED=1
    [[ -d $SHARED/servers ]] || return 0
    command -v python3 >/dev/null || return 0
    while read -r port pl mx up ver; do
        [[ $port =~ ^[0-9]+$ ]] && HB_CACHE[$port]="$pl $mx $up ${ver:--}"
    done < <(python3 -I - "$SHARED/servers" <<'PY' 2>/dev/null
import json, os, re, stat, sys
try:
    dfd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError:
    sys.exit(0)

def whole(v, hi):
    return v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= hi else None

for name in sorted(os.listdir(dfd))[:500]:
    m = re.fullmatch(r"([0-9]{1,5})\.json", name)
    if not m:
        continue
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                continue
            st = json.loads(f.read(65536).decode("utf-8", "replace"))
    except Exception:
        continue
    if not isinstance(st, dict):
        continue
    pl, mx, up = whole(st.get("players"), 10000), whole(st.get("max"), 10000), whole(st.get("updated"), 10**10)
    if up is None:
        continue
    ver = st.get("version") if isinstance(st.get("version"), str) and re.fullmatch(r"[0-9][0-9.]{0,9}", st.get("version")) else "-"
    print(int(m.group(1)), pl if pl is not None else 0, mx if mx is not None else "?", up, ver)
PY
)
}

# "Spieler/Max" eines Servers laut Lebenszeichen, "?" ohne aktuelles (aelter als 90 s oder aus der Zukunft).
players_of() {
    local entry pl mx up now
    (( HB_LOADED )) || load_heartbeats
    entry=${HB_CACHE[$1]:-}
    [[ -n $entry ]] || { echo "?"; return; }
    read -r pl mx up _ <<<"$entry"
    now=$(date +%s)
    if (( now - up > 90 || up > now + 300 )); then echo "?"; return; fi
    echo "$pl/$mx"
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
        return fh.read(limit).decode("utf-8", "replace")
try:
    st = json.loads(read_nofollow(sys.argv[1]))
except Exception:
    sys.exit(0)
if not isinstance(st, dict) or not isinstance(st.get("names"), list):
    sys.exit(0)
upd = st.get("updated")
if not isinstance(upd, (int, float)) or time.time() - upd > 90:
    sys.exit(0)
# Mit Konto-IDs (Plugin 1.14+): Spieler mit BeamMP-Konto mit Namen, Gaeste nur gezaehlt (ihre Namen sagen nichts).
ids = st.get("ids") if isinstance(st.get("ids"), list) and len(st.get("ids")) == len(st["names"]) else None
clean, guests = [], 0
for i, n in enumerate(st["names"]):
    if ids is not None and not (isinstance(ids[i], str) and ids[i]):
        guests += 1
        continue
    n = re.sub(r"[\x00-\x1f\x7f]", "", str(n)).strip()[:32]
    if n:
        clean.append(n)
clean.sort(key=str.lower)
more = len(clean) - 30
text = ", ".join(clean[:30]) + (f" +{more} weitere" if more > 0 else "")
if guests:
    g = "1 Gast" if guests == 1 else f"{guests} Gäste"
    text = f"{text} +{g}" if text else g
print(text)
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
        # Aelter als die Plugin-Version, die zu diesem Werkzeug gehoert?
        local e old="" v n
        for e in "${CORE_VERSIONS[@]}"; do
            v=${e%%:*} n=${e#*:}
            ver_lt "$v" "$CORE_VERSION" && old+="${old:+, }Server $n ($v)"
        done
        if [[ -n $old ]]; then
            warn "BeamNetCore ist älter als $CORE_VERSION: $old"
            hint "beamnet update   (bringt alle Server auf BeamNetCore $CORE_VERSION)"
        fi
    fi
    dup=$(tr ' ' '\n' <<<"$seen_maps" | grep -v '^$' | sort | uniq -d | tr '\n' ' ')
    [[ -n $dup ]] && warn "Mehrere Server mit derselben Map: $dup" && hint "beamnet maps   ·   beamnet set-map <nr> <map>"

    title "BeamNet-Dienste"
    check_watch
    check_broken

    title "Andere Programme, die an den Servern drehen"
    check_agent
    check_cron

    title "SSH-Zugang"
    check_keys

    title "System"
    check_system
    check_logs

    summary
}

# Server-Protokolle: wachsen bei langer Laufzeit ohne Grenze. Rotation (logrotate, copytruncate) richtet "beamnet fix" ein.
check_logs() {
    local nr log mb big=""
    for nr in $(servers); do
        log="$ROOT/$nr/Server.log"
        [[ -f $log && ! -L $log ]] || continue
        mb=$(( $(stat -c %s "$log" 2>/dev/null || echo 0) / 1048576 ))
        (( mb >= 200 )) && big+="Server $nr: $mb MB  "
    done
    if [[ -n $big ]]; then
        warn "Sehr große Server-Protokolle: ${big% }"
        hint "beamnet fix   (richtet die wöchentliche Protokoll-Rotation ein; die Server laufen dabei weiter)"
    fi
    if [[ -f $LOGROTATE_FILE ]]; then
        ok "Protokoll-Rotation eingerichtet ($LOGROTATE_FILE)"
    else
        warn "Keine Protokoll-Rotation für Server.log – sie wachsen ohne Grenze"
        hint "beamnet fix"
    fi
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
    local dur
    dur=$(cat "$STATE_DIR/watch-seconds" 2>/dev/null)
    if [[ $dur =~ ^[0-9]+$ ]]; then
        if (( dur > 40 )); then
            warn "Ein Lauf des Wächters dauert ${dur} s (er läuft jede Minute) – das kostet Rechenzeit neben den Spielservern"
            hint "journalctl -u beamnet-watch -n 20   ·   beamnet report (zum Teilen)"
        else
            ok "Ein Lauf des Wächters dauert ${dur} s"
        fi
    fi
    [[ $(conf_get MAP_VOTE) == 0 ]] || ok "Map-Abstimmung an ($(vote_maps | wc -w) Maps)"
    # Funktionen, die erst eingeschaltet werden muessen (nur Hinweise, keine Warnungen).
    local spec every
    if spec=$(autoevent_spec); then
        ok "XP-Abende: $(conf_get AUTO_EVENT)"
    else
        echo "  XP-Abende aus – zur festen Zeit doppelte XP auf allen Servern, eine Stunde vorher angekündigt."
        hint "beamnet event auto fr,sa 20:00 2 2h"
    fi
    every=$(online_report_min)
    if notify_configured && (( every > 0 )); then ok "Netzwerk-Übersicht an Discord/Telegram alle $every Minuten"; fi
    if [[ -n $(conf_get TELEGRAM_TOKEN) && -z $(conf_get TELEGRAM_ADMINS) ]]; then
        echo "  Keine Telegram-Admins – /ansage und /event 2 2h gehen nur aus dem Chat, wenn deine Telegram-ID eingetragen ist."
        hint "TELEGRAM_ADMINS=<deine Telegram-Zahlen-ID> in /etc/beamnet.conf (ID z. B. über @userinfobot)"
    fi
    local nr list m missing=""
    for nr in $(servers); do
        list=$(conf_get "ROTATE_$nr")
        [[ -n $list ]] && ok "Server $nr: tägliche Map-Rotation ($list)"
    done
    # Fahrauftraege brauchen Orte je Map (places/<Map>.json, im Spiel mit /ort neu angelegt).
    if [[ -d $SHARED && ! -L $SHARED ]]; then
        for m in $(for nr in $(servers); do
                       [[ -f $ROOT/$nr/Resources/Server/BeamNetCore/main.lua ]] && map_short "$(cfg "$nr" Map)" && echo
                   done | sort -u); do
            [[ $m =~ ^[A-Za-z0-9_-]+$ ]] || continue
            [[ $(safe get "$SHARED/places/$m.json" 2>/dev/null | head -c 1048576 | grep -o '"type"' | wc -l) -gt 0 ]] \
                || missing+="${missing:+, }$m"
        done
        if [[ -n $missing ]]; then
            warn "Keine Orte für Fahraufträge (/auftrag) auf: $missing"
            hint "Bis dahin liefert /auftrag zu Lieferpunkten (Plugin 1.62+). Schöner mit echten Orten – im Spiel als Admin an die Stelle fahren: /ort neu krankenhaus <Name> (auch schule, feuerwehr, tankstelle …)"
        fi
    fi
    return 0
}

# ver_lt <a> <b>: ist Version a (z. B. 1.9) aelter als b (z. B. 1.79)? Hauptnummer, dann Unternummer als Zahl.
ver_lt() {
    [[ $1 =~ ^([0-9]{1,4})\.([0-9]{1,4})$ ]] || return 1
    local am=${BASH_REMATCH[1]} an=${BASH_REMATCH[2]}
    [[ $2 =~ ^([0-9]{1,4})\.([0-9]{1,4})$ ]] || return 1
    (( 10#$am < 10#${BASH_REMATCH[1]} || (10#$am == 10#${BASH_REMATCH[1]} && 10#$an < 10#${BASH_REMATCH[2]}) ))
}

# Hat das Plugin in den letzten 30 Tagen kaputte Dateien beiseitegelegt (<datei>.kaputt-<Zeit>)? Dann haben die
# betroffenen Spieler bzw. Teams neu angefangen – aus der Datensicherung zurueckholbar.
check_broken() {
    [[ -d $SHARED && ! -L $SHARED ]] || return 0
    local n
    # ctime: das Beiseitelegen ist ein Umbenennen (die mtime bleibt die des letzten Schreibens).
    n=$(find "$SHARED" -maxdepth 2 -name '*.kaputt-*' -ctime -30 2>/dev/null | wc -l)
    if (( n > 0 )); then
        warn "$n beschädigte Datei(en) in den letzten 30 Tagen beiseitegelegt (*.kaputt-*) – dort wurde neu angefangen"
        hint "beamnet restore   (Datensicherungen ansehen und zurückholen)   ·   find $SHARED -name '*.kaputt-*'"
    fi
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
    title "3. Protokoll-Rotation"
    if [[ -f $LOGROTATE_FILE ]]; then
        ok "Schon eingerichtet ($LOGROTATE_FILE)"
    elif [[ -d $(dirname "$LOGROTATE_FILE") ]]; then
        cat >"$LOGROTATE_FILE" <<EOF
# BeamNet: Server-Protokolle der BeamMP-Server woechentlich (oder ab 100 MB) rotieren, 4 Stueck behalten.
# copytruncate: der laufende Server schreibt einfach weiter. su: die Ordner gehoeren $SERVICE_USER.
$ROOT/*/Server.log {
    su $SERVICE_USER $SERVICE_USER
    weekly
    maxsize 100M
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
        chmod 644 "$LOGROTATE_FILE"
        ok "Protokoll-Rotation eingerichtet ($LOGROTATE_FILE)"
    else
        warn "logrotate ist nicht installiert (apt install logrotate) – Rotation übersprungen"
    fi

    title "4. Autostart und Start"
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

write_slots() {
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    safe keyline "$ROOT/$1/ServerConfig.toml" MaxPlayers "$2" "$BACKUP_DIR/config/$1"
}

# ---------------------------------------------------------------------------------------------------------------------
# Spielerplaetze nach Beliebtheit: Der Waechter schreibt jede Minute je Server "nr map spitze spielerminuten" in
# usage-<Datum> (31 Tage). beamnet slots zeigt die letzten 30 Tage und schlaegt mehr Plaetze vor: SLOTS_STEP mehr fuer
# Server, die an mindestens SLOTS_FULL_DAYS Tagen voll waren (90 % der Plaetze), und noch einmal SLOTS_STEP, wenn ihre
# Map zu den 3 beliebtesten gehoert (Spielerstunden) und sie mindestens einmal voll waren. Hoechstens SLOTS_MAX.
# Mit AUTO_SLOTS=1 (Standard) stellt der Waechter das einmal am Tag ab SLOTS_HOUR um – nur, wenn der Server leer ist.

slots_conf() {
    local v
    v=$(conf_get "$1"); [[ $v =~ ^[0-9]{1,3}$ ]] && echo "$v" || echo "$2"
}

usage_record() {     # stdin: Zeilen "nr map spieler"
    local file
    file="$STATE_DIR/usage-$(date +%Y-%m-%d)"
    { cat "$file" 2>/dev/null; echo "--"; cat; } | awk '
        $0 == "--" { sep = 1; next }
        !sep && NF == 4 && $1 ~ /^[0-9]+$/ { k = $1 " " $2; mx[k] = $3 + 0; pm[k] = $4 + 0; next }
        sep && NF == 3 && $1 ~ /^[0-9]+$/ { k = $1 " " $2; if (!(k in mx) || $3 + 0 > mx[k]) mx[k] = $3 + 0; pm[k] += $3 }
        END { for (k in mx) print k, mx[k], pm[k] + 0 }' >"$file.new" && mv "$file.new" "$file"
    find "$STATE_DIR" -maxdepth 1 -name 'usage-*' -mtime +31 -delete 2>/dev/null
    return 0
}

# Zeilen "nr map plaetze neu spitze volleTage stunden grund" je Server (grund: Text mit _ statt Leerzeichen, - = keiner).
read -r -d '' SLOTS_PY <<'PY'
import datetime, math, os, re, sys
state, smax, step, need = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
cut = (datetime.date.today() - datetime.timedelta(days=30)).isoformat()
daymax, pm_map, pm_srv = {}, {}, {}
try:
    names = os.listdir(state)
except OSError:
    names = []
for name in names:
    m = re.fullmatch(r"usage-(\d{4}-\d{2}-\d{2})", name)
    if not m or m.group(1) <= cut:
        continue
    try:
        with open(os.path.join(state, name), encoding="utf-8", errors="replace") as f:
            lines = f.read(1 << 20).splitlines()
    except OSError:
        continue
    for line in lines:
        p = line.split()
        if len(p) != 4 or not p[0].isdigit() or not p[2].isdigit() or not p[3].isdigit():
            continue
        nr, mp, mx, pm = p[0], p[1], int(p[2]), int(p[3])
        key = (nr, m.group(1))
        daymax[key] = max(daymax.get(key, 0), mx)
        pm_map[mp] = pm_map.get(mp, 0) + pm
        pm_srv[nr] = pm_srv.get(nr, 0) + pm
popular = [mp for mp, v in sorted(pm_map.items(), key=lambda e: -e[1]) if v > 0][:3]
for arg in sys.argv[5:]:
    nr, mp, cur = arg.split(":")
    cur = int(cur)
    days = [v for (n, _), v in daymax.items() if n == nr]
    peak = max(days, default=0)
    full = sum(1 for v in days if cur > 0 and v >= max(1, math.ceil(cur * 0.9)))
    new, why = cur, []
    if full >= need:
        new += step
        why.append(f"{full}× voll in 30 Tagen")
    if mp in popular and full >= 1:
        new += step
        why.append(f"beliebte Map (Platz {popular.index(mp) + 1})")
    new = max(cur, min(new, smax))
    print(nr, mp, cur, new, peak, full, round(pm_srv.get(nr, 0) / 60), "_".join(" · ".join(why).split()) or "-")
PY

slots_manual() {     # 0 = Server wurde in den letzten 30 Tagen von Hand eingestellt
    local at
    at=$(cat "$STATE_DIR/slots-manual-$1" 2>/dev/null)
    [[ $at =~ ^[0-9]+$ ]] && (( $(date +%s) - at < 30 * 86400 ))
}

slots_plan() {
    local nr args=() cur mp
    for nr in $(servers); do
        slots_manual "$nr" && continue
        cur=$(cfg "$nr" MaxPlayers)
        [[ $cur =~ ^[0-9]{1,3}$ ]] || continue
        mp=$(map_short "$(cfg "$nr" Map)")
        [[ $mp =~ ^[A-Za-z0-9_.-]+$ ]] || mp="?"
        args+=("$nr:$mp:$cur")
    done
    (( ${#args[@]} > 0 )) || return 0
    python3 -I -c "$SLOTS_PY" "$STATE_DIR" "$(slots_conf SLOTS_MAX 20)" "$(slots_conf SLOTS_STEP 4)" \
        "$(slots_conf SLOTS_FULL_DAYS 2)" "${args[@]}"
}

# beamnet slots [apply | <nr> <plaetze>]
cmd_slots() {
    local nr mp cur new peak full hours why changed=0
    if [[ ${1:-} =~ ^[0-9]+$ && ${2:-} == auto ]]; then
        need_root slots
        targets "$1" >/dev/null
        rm -f "$STATE_DIR/slots-manual-$1"
        ok "Server $1: Spielerplätze wieder automatisch."
        return 0
    fi
    if [[ ${1:-} =~ ^[0-9]+$ ]]; then
        need_root slots
        [[ $# -eq 2 && $2 =~ ^[1-9][0-9]{0,2}$ ]] || die "Aufruf: beamnet slots <nr> <plätze>   (z. B. beamnet slots 3 16)"
        (( $2 >= 2 && $2 <= 64 )) || die "Plätze: 2 bis 64."
        targets "$1" >/dev/null
        write_slots "$1" "$2" || die "In $ROOT/$1/ServerConfig.toml steht keine MaxPlayers-Zeile."
        # Von Hand gesetzt: die Automatik laesst diesen Server 30 Tage in Ruhe (sonst macht sie eine Senkung rueckgaengig).
        mkdir -p "$STATE_DIR" && date +%s >"$STATE_DIR/slots-manual-$1"
        ok "Server $1: $2 Plätze (alte Konfiguration gesichert in $BACKUP_DIR/config/$1; Automatik hier 30 Tage aus)"
        echo "BeamMP liest MaxPlayers nur beim Start."
        if confirm "Server $1 jetzt neu starten?"; then
            clear_maintenance "$1"
            systemctl restart "$(unit "$1")" && verify_running "$1"
        fi
        return 0
    fi
    if [[ ${1:-} == apply ]]; then
        need_root slots
        while read -r nr mp cur new peak full hours why; do
            (( new > cur )) || continue
            write_slots "$nr" "$new" || { warn "Server $nr: keine MaxPlayers-Zeile."; continue; }
            ok "Server $nr ($mp): $cur → $new Plätze (${why//_/ })"
            changed=1
        done < <(slots_plan)
        (( changed )) || { echo "Keine Änderung nötig."; return 0; }
        echo "Wirksam nach einem Neustart: beamnet restart all (der Wächter macht es mit AUTO_SLOTS=1 automatisch, sobald ein Server leer ist)."
        return 0
    fi
    [[ $# -eq 0 ]] || die "Aufruf: beamnet slots [apply | <nr> <plätze>]"
    echo "Spielerplätze – letzte 30 Tage (Spitze = meiste Spieler gleichzeitig, voll = Tage mit 90 % belegt):"
    printf '  %-6s %-16s %6s %7s %5s %8s  %s\n' "Server" "Map" "Plätze" "Spitze" "voll" "Stunden" "Vorschlag"
    while read -r nr mp cur new peak full hours why; do
        local tip="bleibt"
        (( new > cur )) && tip="→ $new (${why//_/ })"
        printf '  %-6s %-16s %6s %7s %5s %8s  %s\n' "$nr" "$mp" "$cur" "$peak" "$full" "$hours" "$tip"
    done < <(slots_plan)
    for nr in $(servers); do
        slots_manual "$nr" && echo "  Server $nr: von Hand auf $(cfg "$nr" MaxPlayers) gesetzt – Automatik 30 Tage aus (beamnet slots $nr auto schaltet sie wieder ein)"
    done
    echo "Übernehmen: beamnet slots apply · selbst setzen: beamnet slots <nr> <plätze> · automatisch: AUTO_SLOTS=1 (Standard)"
}

# Einmal am Tag ab SLOTS_HOUR: Vorschlaege fuer leere Server uebernehmen und neu starten (AUTO_SLOTS=0 schaltet ab).
watch_slots() {
    local -n slotout=$1
    local hour start today nr mp cur new peak full hours why pl
    [[ $(conf_get AUTO_SLOTS) == 0 ]] && return 0
    hour=${BEAMNET_HOUR:-$(date +%H)}
    start=$(slots_conf SLOTS_HOUR 6)
    (( 10#$hour >= 10#$start )) || return 0
    today=$(date +%Y-%m-%d)
    local open=0
    for nr in $(servers); do [[ $(cat "$STATE_DIR/slots-$nr" 2>/dev/null) == "$today" ]] || open=1; done
    (( open )) || return 0
    while read -r nr mp cur new peak full hours why; do
        [[ $(cat "$STATE_DIR/slots-$nr" 2>/dev/null) == "$today" ]] && continue
        # Nichts zu tun, in Wartung oder aus: fuer heute erledigt. Nur besetzte Server werden spaeter erneut geprueft.
        if (( new <= cur )) || [[ -f $STATE_DIR/maintenance-$nr ]] || ! unit_active "$nr"; then
            echo "$today" >"$STATE_DIR/slots-$nr"
            continue
        fi
        # Gerade fuer die Map neu gestartet: Lebenszeichen ist noch alt – beim naechsten Lauf (ohne zweiten Neustart jetzt).
        [[ $RESTARTED_NOW == *" $nr "* ]] && continue
        pl=$(players_of "$(cfg "$nr" Port)")
        [[ $pl == 0/* ]] || continue        # nur leer – sonst beim naechsten Lauf erneut
        echo "$today" >"$STATE_DIR/slots-$nr"
        write_slots "$nr" "$new" || continue
        if systemctl restart "$(unit "$nr")"; then
            slotout+=("📈 Server $nr ($mp): mehr Platz – jetzt $new statt $cur Spieler (${why//_/ }).")
        else
            slotout+=("⚠️ Server $nr: Neustart nach dem Erhöhen der Plätze fehlgeschlagen (beamnet logs $nr).")
        fi
    done < <(slots_plan)
    return 0
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

# Ansage auf allen Servern (ueber announcements.json, das BeamNetCore alle 3 s liest): sofort oder zu einer Uhrzeit.
#   beamnet ansage                    – geplante Ansagen zeigen
#   beamnet ansage [HH:MM] <Text>     – ansagen (mit Uhrzeit: heute, oder morgen, wenn schon vorbei)
cmd_ansage() {
    need_root ansage
    local when="" text out
    command -v python3 >/dev/null || die "python3 fehlt (apt install python3)."
    [[ -d $SHARED && ! -L $SHARED ]] || die "Kein gemeinsamer Ordner – ist BeamNetCore installiert? (beamnet install-core)"
    if [[ ${1:-} =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then when=$1; shift; fi
    text="$*"
    out=$(mktemp)
    local rc=0
    python3 -I - "$SHARED/announcements.json" "$out" "$when" "$text" <<'PY' || rc=$?
import datetime, json, os, random, re, stat, sys, time
path, out, when, text = sys.argv[1:5]
def read_nofollow(p):
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError
        return f.read(1 << 20).decode("utf-8", "replace")
try:
    data = json.loads(read_nofollow(path))
except FileNotFoundError:
    data = {}
except Exception:
    print("announcements.json ist fehlerhaft – bitte prüfen."); sys.exit(1)
lst = data.get("list") if isinstance(data, dict) and isinstance(data.get("list"), list) else []
# Nur gueltige Eintraege (Tabelle mit sinnvoller Zeit); fremde fallen beim naechsten Schreiben weg.
lst = [a for a in lst if isinstance(a, dict) and isinstance(a.get("at"), (int, float)) and 0 <= a["at"] < 4e9]
now = int(time.time())
def clean(v, n):
    # Steuerzeichen (auch C1, z. B. Terminal-Escapes aus einer Ingame-Ansage) nie aufs Root-Terminal
    return " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(v)).split())[:n]
text = clean(text, 300)
if not text:
    planned = [a for a in lst if a["at"] > now]
    if not planned:
        print("Keine geplanten Ansagen. Neue: beamnet ansage [HH:MM] <Text>")
    for a in sorted(planned, key=lambda a: a["at"]):
        print(f"{time.strftime('%d.%m. %H:%M', time.localtime(a['at']))}  {clean(a.get('text', ''), 300)}  ({clean(a.get('by', '?'), 40)})")
    sys.exit(2)
at = now
if when:
    h, m = (int(x) for x in when.split(":"))
    t = datetime.datetime.now().replace(hour=h, minute=m, second=0, microsecond=0)
    if t.timestamp() <= now:
        t += datetime.timedelta(days=1)
    at = int(t.timestamp())
by = clean(os.environ.get("ANSAGE_BY") or "Konsole", 40)
lst.append({"id": f"{now}-konsole-{random.randint(100000, 999999)}", "text": text, "by": by, "at": at})
# Kuerzen wie im Plugin: erst laengst angesagte (aelter als 2 Minuten), dann die aeltesten.
while len(lst) > 20:
    old = next((i for i, a in enumerate(lst) if a["at"] < now - 120), 0)
    del lst[old]
data = {"list": lst}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False)
print(("Ansage geplant für " + time.strftime("%d.%m. %H:%M", time.localtime(at)) + " Uhr") if at > now else "Ansage gesendet")
PY
    if (( rc == 2 )); then rm -f "$out"; return 0; fi        # nur die Liste gezeigt
    (( rc == 0 )) || { rm -f "$out"; exit 1; }
    if [[ -s $out ]]; then
        safe put "$SHARED/announcements.json" 664 "$SERVICE_USER" <"$out" || { rm -f "$out"; die "Konnte die Ansage nicht speichern."; }
    fi
    rm -f "$out"
    return 0
}

# Datensicherungen (taeglich vom Waechter): auflisten oder einen Stand zuruecksetzen.
cmd_restore() {
    need_root restore
    local want=${1:-} file ts="" new old nr running=() f
    if [[ -z $want ]]; then
        echo "Tägliche Datensicherungen in $BACKUP_DIR (Spieler, Rekorde, Banns, Protokoll):"
        f=""
        for file in "$BACKUP_DIR"/daten-*.tgz; do
            [[ -f $file ]] || continue
            f=1
            printf '  %s  %s\n' "$(basename "$file" .tgz | sed 's/^daten-//')" "$(du -h "$file" | cut -f1)"
        done
        [[ -n $f ]] || echo "  (noch keine – der Wächter legt sie täglich ab $(backup_hour) Uhr an: beamnet watch install)"
        echo "Zurücksetzen: beamnet restore <JJJJ-MM-TT> · nur ein Spieler: beamnet restore <JJJJ-MM-TT> spieler <Name|ID> · prüfen: beamnet restore check [JJJJ-MM-TT]"
        return 0
    fi
    if [[ $want == check || $want == pruefen || $want == prüfen ]]; then
        local day=${2:-} out files players
        if [[ -z $day ]]; then
            file=$(find "$BACKUP_DIR" -maxdepth 1 -name 'daten-*.tgz' -printf '%f\n' 2>/dev/null | sort -r | head -n1)
            [[ -n $file ]] || die "Noch keine Datensicherung."
            day=${file#daten-}; day=${day%.tgz}
        fi
        [[ $day =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "Aufruf: beamnet restore check [JJJJ-MM-TT]"
        file="$BACKUP_DIR/daten-$day.tgz"
        [[ -f $file && ! -L $file ]] || die "Keine Datensicherung vom $day."
        if out=$(data_tool check "$file" 2>&1); then
            local broken
            read -r files players broken <<<"$out"
            ok "Sicherung vom $day ist in Ordnung: $files Dateien, $players Spieler."
            [[ ${broken:-0} -gt 0 ]] && warn "$broken Spielerdatei(en) darin sind kaputt (so wie im Spielordner) – beim Zurückspielen fängt das Plugin für diese Spieler neu an."
            return 0
        fi
        die "Sicherung vom $day ist NICHT in Ordnung: ${out##*$'\n'}"
    fi
    [[ $want =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "Aufruf: beamnet restore [JJJJ-MM-TT]"
    file="$BACKUP_DIR/daten-$want.tgz"
    [[ -f $file && ! -L $file ]] || die "Keine Datensicherung vom $want (Liste: beamnet restore)."
    if [[ ${2:-} == spieler || ${2:-} == player ]]; then
        # Nur einen Spieler zurueckholen (z. B. nach einer kaputten Datei): die anderen bleiben, kein Neustart.
        local query=${3:-} line pid json pname
        [[ -n $query && ${#query} -le 64 ]] || die "Aufruf: beamnet restore <JJJJ-MM-TT> spieler <Name oder ID>"
        [[ -d $SHARED/players && ! -L $SHARED/players && ! -L $SHARED ]] || die "Kein Spielerordner unter $SHARED."
        line=$(data_tool player "$file" "$query" 2>&1) || die "Spieler '$query' in der Sicherung vom $want: ${line##*$'\n'}"
        pid=${line%%$'\t'*}; json=${line#*$'\t'}
        [[ $pid =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "Unerwartete Spieler-ID in der Sicherung."
        pname=$(python3 -I -c 'import json, re, sys; print(" ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(json.loads(sys.argv[1]).get("name", "?"))).split())[:32])' "$json" 2>/dev/null)
        # Gerade online? Dann rechnet sein Server die laufende Fahrt beim naechsten Speichern oben drauf – besser danach.
        local where
        where=$(python3 -I - "$SHARED/servers" "$pid" <<'PY' 2>/dev/null
import json, os, re, stat, sys, time
try:
    dfd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError:
    sys.exit(0)
for name in sorted(os.listdir(dfd))[:500]:
    if not re.fullmatch(r"[0-9]{1,5}\.json", name):
        continue
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
        with os.fdopen(fd, "rb") as fh:
            if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
                continue
            st = json.loads(fh.read(65536).decode("utf-8", "replace"))
    except Exception:
        continue
    up = st.get("updated") if isinstance(st, dict) else None
    if isinstance(up, int) and 0 <= time.time() - up <= 90 and isinstance(st.get("ids"), list) and sys.argv[2] in st["ids"]:
        print("Port " + name[:-5]); break
PY
)
        [[ -n $where ]] && warn "Spieler $pid ist gerade online ($where) – besser nach dem Verlassen zurückholen."
        confirm "Spieler $pid (${pname:-?}) auf den Stand vom $want zurücksetzen? (am besten, während er nicht fährt)" || { echo "Abgebrochen."; return 1; }
        mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
        ts=$(date +%Y%m%d-%H%M%S)
        safe get "$SHARED/players/$pid.json" >"$BACKUP_DIR/spieler-$pid-vor-$ts.json" 2>/dev/null || rm -f "$BACKUP_DIR/spieler-$pid-vor-$ts.json"
        printf '%s' "$json" | safe put "$SHARED/players/$pid.json" 664 "$SERVICE_USER" || die "Konnte die Spielerdatei nicht schreiben."
        ok "Spieler $pid (${pname:-?}) auf den Stand vom $want zurückgesetzt."
        [[ -f $BACKUP_DIR/spieler-$pid-vor-$ts.json ]] && echo "Der bisherige Stand liegt in $BACKUP_DIR/spieler-$pid-vor-$ts.json."
        return 0
    fi
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
    # Ab hier laufen die Server nicht: bei jedem Fehler den alten Stand behalten und sie wieder starten.
    restart_running() { for nr in "${running[@]}"; do systemctl start "$(unit "$nr")"; clear_maintenance "$nr"; done; }
    if [[ -d $SHARED ]] && ! mv -T "$SHARED" "$old"; then
        rm -rf "$new"; restart_running
        die "Konnte den alten Stand nicht beiseitelegen – nichts geändert, Server wieder gestartet."
    fi
    if ! mv -T "$new" "$SHARED"; then
        [[ -d $old ]] && mv -T "$old" "$SHARED"
        rm -rf "$new"; restart_running
        die "Konnte den gesicherten Stand nicht einsetzen – alter Stand bleibt, Server wieder gestartet."
    fi
    ensure_shared
    restart_running
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
    rm -f "$BACKUP_DIR"/daten-*.tgz.tmp
    find "$BACKUP_DIR" -maxdepth 1 -name 'daten-*.tgz' -printf '%f\n' 2>/dev/null | sort -r | tail -n +$(( 10#$keep + 1 )) \
        | while read -r f; do rm -f "$BACKUP_DIR/$f"; done
    find "$STATE_DIR" -maxdepth 1 -name 'backup-failed-*' -mtime +3 -delete 2>/dev/null
    # Einmal je Woche die neue Sicherung probeweise wiederherstellen (ohne zu schreiben) – eine kaputte Sicherung
    # faellt so auf, bevor man sie braucht.
    local wk out
    wk=$(date +%G-W%V)
    if [[ $(cat "$STATE_DIR/backup-checked" 2>/dev/null) != "$wk" ]]; then
        echo "$wk" >"$STATE_DIR/backup-checked"
        if ! out=$(data_tool check "$BACKUP_DIR/daten-$today.tgz" 2>&1); then
            bout+=("⚠️ Die Datensicherung vom $today lässt sich nicht sauber wiederherstellen: ${out##*$'\n'}")
        fi
    fi
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
            [[ -f $file && ! -L $file ]] || continue
            safe get "$file" 2>/dev/null | head -c 65536 | tr -d '\000-\010\013-\037\177'
            echo
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

# Plugin auf einen Server schreiben; die bisherige Version landet in $BACKUP_DIR/plugins/<nr>/ (LAST_PLUGIN_BACKUP).
LAST_PLUGIN_BACKUP=""
install_core_on() {
    local nr=$1 src=$2 dest="$ROOT/$1/Resources/Server/BeamNetCore"
    LAST_PLUGIN_BACKUP=""
    if [[ -L $ROOT/$nr/Resources || -L $ROOT/$nr/Resources/Server || -L $dest ]]; then
        bad "Server $nr: Plugin-Ordner ist ein Symlink – übersprungen (bitte prüfen)"
        return 1
    fi
    mkdir -p "$dest"
    if [[ -f $dest/main.lua ]]; then
        mkdir -p "$BACKUP_DIR/plugins/$nr"
        LAST_PLUGIN_BACKUP="$BACKUP_DIR/plugins/$nr/main.lua.$(date +%Y%m%d-%H%M%S)"
        safe get "$dest/main.lua" >"$LAST_PLUGIN_BACKUP" 2>/dev/null || LAST_PLUGIN_BACKUP=""
    fi
    if safe put "$dest/main.lua" 644 "$SERVICE_USER" <"$src"; then
        chown -h "$SERVICE_USER:$SERVICE_USER" "$dest"
        ok "Server $nr: BeamNetCore installiert"
    else
        bad "Server $nr: BeamNetCore konnte nicht geschrieben werden"
        return 1
    fi
}

# Testserver fuer ein Update: laufend, mit aktuellem Lebenszeichen, moeglichst wenige Spieler.
pick_canary() {
    local nr pl best="" fewest=1000000
    for nr in "$@"; do
        unit_active "$nr" || continue
        pl=$(players_of "$(cfg "$nr" Port)")
        [[ $pl =~ ^([0-9]+)/ ]] || continue
        if (( BASH_REMATCH[1] < fewest )); then best=$nr; fewest=${BASH_REMATCH[1]}; fi
    done
    echo "$best"
}

# Meldet sich Server <nr> innerhalb von <sekunden> mit Plugin-Version <version>?
canary_reports() {
    local nr=$1 want=$2 wait=$3 port entry ver up waited=0
    port=$(cfg "$nr" Port)
    while :; do
        load_heartbeats
        entry=${HB_CACHE[$port]:-}
        if [[ -n $entry ]]; then
            read -r _ _ up ver <<<"$entry"
            [[ $ver == "$want" ]] && (( $(date +%s) - up <= 90 )) && return 0
        fi
        (( waited >= wait )) && return 1
        sleep 3
        waited=$(( waited + 3 ))
    done
}

cmd_install_core() {
    need_root install-core
    local src nr list newver canary="" wait
    src=$(core_source)
    grep -q 'BeamNetCore' "$src" || die "$src ist kein BeamNetCore-Plugin"
    list=$(servers)
    confirm "BeamNetCore auf allen Servern ($(tr '\n' ' ' <<<"$list"))installieren?" || { echo "Abgebrochen."; return 1; }
    ensure_shared
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    # Erst auf einem Testserver: meldet er sich nicht mit der neuen Version, alte Version zurueck und Abbruch –
    # die uebrigen Server bleiben unberuehrt. (Ohne laufenden Server mit Lebenszeichen, z. B. bei der ersten
    # Installation, oder mit BEAMNET_CANARY=0: gleich ueberall.)
    newver=$(grep -o 'BN.VERSION = "[0-9.]*"' "$src" | head -n1 | cut -d'"' -f2)
    # shellcheck disable=SC2086
    [[ ${BEAMNET_CANARY:-1} != 0 && -n $newver ]] && canary=$(pick_canary $list)
    if [[ -n $canary ]]; then
        echo "Teste BeamNetCore $newver zuerst auf Server $canary …"
        install_core_on "$canary" "$src" || die "Update abgebrochen – nichts weiter geändert."
        wait=${BEAMNET_CANARY_WAIT:-60}
        [[ $wait =~ ^[0-9]+$ ]] || wait=60
        if ! canary_reports "$canary" "$newver" "$wait"; then
            if [[ -n $LAST_PLUGIN_BACKUP && -s $LAST_PLUGIN_BACKUP ]]; then
                safe put "$ROOT/$canary/Resources/Server/BeamNetCore/main.lua" 644 "$SERVICE_USER" <"$LAST_PLUGIN_BACKUP"
                bad "Server $canary meldet sich nicht mit $newver – alte Version wiederhergestellt."
            else
                bad "Server $canary meldet sich nicht mit $newver (keine alte Version zum Zurückholen)."
            fi
            die "Update abgebrochen, die übrigen Server sind unverändert. Fehler ansehen: beamnet logs $canary"
        fi
        ok "Server $canary läuft mit BeamNetCore $newver – jetzt die übrigen Server."
    fi
    for nr in $list; do
        [[ $nr == "$canary" ]] && continue
        install_core_on "$nr" "$src" || true
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

# Teilt Text zeilenweise in Stuecke von hoechstens $1 Zeichen und ruft fuer jedes "$2 <Stueck>" auf (Discord nimmt
# hoechstens 2000 Zeichen, Telegram 4096 – sonst ginge die ganze Meldung verloren). Hoechstens 4 Stuecke je Lauf.
send_chunks() {
    local max=$1 sender=$2 text=$3 chunk="" line rc=0 n=0
    while IFS= read -r line; do
        line=${line:0:$max}
        if [[ -n $chunk ]] && (( ${#chunk} + ${#line} + 1 > max )); then
            if (( n >= 3 )); then chunk+=$'\n'"… (gekürzt – alles im Systemprotokoll: journalctl -u beamnet-watch)"; break; fi
            "$sender" "$chunk" || rc=1
            n=$(( n + 1 ))
            chunk=""
        fi
        chunk+="${chunk:+$'\n'}$line"
    done <<<"$text"
    if [[ -n $chunk ]]; then "$sender" "$chunk" || rc=1; fi
    return $rc
}

# Discord wertet Markdown aus: Spielertexte duerfen keine getarnten Links ([Text](https://…)) o. Ae. bauen.
discord_escape() { sed -e 's/[][\\*_~`|>()#]/\\&/g' <<<"$1"; }

send_discord() {
    curl -fsS -m 10 -H "Content-Type: application/json" \
        -d "{\"content\":\"$(json_escape "$(discord_escape "$1")")\",\"allowed_mentions\":{\"parse\":[]},\"flags\":4}" \
        -K <(printf 'url = "%s"\n' "$NOTIFY_HOOK") >/dev/null
}

send_telegram() {
    curl -fsS -m 10 -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$NOTIFY_CHAT\",\"text\":\"$(json_escape "$1")\",\"disable_web_page_preview\":true}" \
        -K <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$NOTIFY_TOKEN") >/dev/null
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
            NOTIFY_HOOK=$hook send_chunks 1900 send_discord "$text" || { echo "Discord-Meldung fehlgeschlagen" >&2; rc=1; }
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
            NOTIFY_CHAT=$chat NOTIFY_TOKEN=$token send_chunks 4000 send_telegram "$text" \
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
    local entry pl mx up
    (( HB_LOADED )) || load_heartbeats
    entry=${HB_CACHE[$1]:-}
    [[ -n $entry ]] || return 0
    read -r pl mx up _ <<<"$entry"
    echo $(( $(date +%s) - up ))
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
# Neue Streckenrekorde sofort melden (RECORD_NOTIFY=0 schaltet ab). Der erste Lauf merkt sich nur den Stand.
watch_records() {
    local -n recout=$1
    local line
    [[ $(conf_get RECORD_NOTIFY) == 0 ]] && return 0
    [[ -d $SHARED/races && ! -L $SHARED/races && ! -L $SHARED ]] || return 0
    while IFS= read -r line; do
        [[ -n $line ]] && recout+=("$line")
    done < <(python3 -I - "$SHARED/races" "$STATE_DIR/records.json" <<'PY' 2>/dev/null
import json, os, re, stat, sys
races, state = sys.argv[1], sys.argv[2]
OK = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
def load(name):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    except OSError:
        return None
    try:
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                return None
            return json.loads(f.read(4 << 20).decode("utf-8", "replace"))
    except Exception:
        return None
def c(v, n=32):
    return " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(v)).split())[:n] or "?"
def t(v):
    m, s = divmod(float(v), 60)
    return f"{int(m)}:{s:04.1f}"
dfd = os.open(races, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
best = {}
for name in sorted(os.listdir(dfd)):
    if not name.endswith(".json") or not OK.match(name[:-5]):
        continue
    data = load(name)
    tracks = data.get("tracks") if isinstance(data, dict) else None
    for tn, tr in (tracks.items() if isinstance(tracks, dict) else []):
        recs = tr.get("records") if isinstance(tr, dict) else None
        b = recs[0] if isinstance(recs, list) and recs and isinstance(recs[0], dict) else None
        tm = b.get("time") if b else None
        if OK.match(str(tn)) and isinstance(tm, (int, float)) and not isinstance(tm, bool) and 0 < tm < 1e6:
            best[name[:-5] + "/" + str(tn)] = {"time": tm, "name": c(b.get("name"))}
try:
    old = json.load(open(state))
    first = not isinstance(old, dict)
except Exception:
    old, first = {}, True
MAPS = {"gridmap_v2": "Grid Map", "west_coast_usa": "West Coast, USA", "east_coast_usa": "East Coast, USA",
        "italy": "Italy", "utah": "Utah, USA", "jungle_rock_island": "Jungle Rock Island", "industrial": "Industrial",
        "small_island": "Small Island", "johnson_valley": "Johnson Valley", "automation_test_track": "Automation Test Track"}
lines = []
if not first:
    for key, b in sorted(best.items()):
        o = old.get(key) if isinstance(old.get(key), dict) else None
        if o and isinstance(o.get("time"), (int, float)) and b["time"] < o["time"] - 1e-6:
            m, tn = key.split("/", 1)
            prev = f" (vorher {c(o.get('name'))} {t(o['time'])})" if o.get("name") != b["name"] else f" (vorher {t(o['time'])})"
            lines.append(f"🏆 Neuer Streckenrekord auf {tn} ({MAPS.get(m, m)}): {b['name']} {t(b['time'])}{prev}")
        elif not o:
            m, tn = key.split("/", 1)
            lines.append(f"🏁 Erste Zeit auf {tn} ({MAPS.get(m, m)}): {b['name']} {t(b['time'])} – wer ist schneller?")
# Hoechstens 5 Zeilen: viele (auch untergeschobene) Strecken duerfen wichtige Meldungen nicht verdraengen.
for line in lines[:5]:
    print(line)
if len(lines) > 5:
    print(f"   … und {len(lines) - 5} weitere neue Zeiten")
with open(state + ".tmp", "w") as f:
    json.dump(best, f)
os.replace(state + ".tmp", state)
PY
)
    return 0
}

# Wiederholungstaeter: einmal je Stunde das Moderationsprotokoll der letzten 7 Tage zaehlen. Wer mindestens REPEAT_WARN
# Mal (Standard 3) gemeldet, stummgeschaltet, verwarnt oder gekickt wurde, wird den Admins einmal je Woche genannt.
watch_repeat() {
    local -n offenders_out=$1
    local warn line
    warn=$(conf_get REPEAT_WARN)
    [[ $warn =~ ^[0-9]{1,3}$ ]] || warn=3
    (( 10#$warn > 0 )) || return 0
    [[ -f $SHARED/modlog.jsonl && ! -L $SHARED/modlog.jsonl && ! -L $SHARED ]] || return 0
    [[ -n $(find "$STATE_DIR/repeat-at" -mmin -60 2>/dev/null) ]] && return 0
    : >"$STATE_DIR/repeat-at"
    while IFS= read -r line; do
        [[ -n $line ]] && offenders_out+=("$line")
    done < <(python3 -I - "$SHARED/modlog.jsonl" "$STATE_DIR/repeat.json" "$((10#$warn))" <<'PY' 2>/dev/null
import json, os, re, stat, sys, time
path, state, need = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = time.time()
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    sys.exit(0)
with os.fdopen(fd, "rb") as f:
    st = os.fstat(f.fileno())
    if not stat.S_ISREG(st.st_mode):
        sys.exit(0)
    f.seek(max(0, st.st_size - 2 * 1024 * 1024))          # die letzten 2 MB reichen fuer 7 Tage
    data = f.read(2 * 1024 * 1024)
LABEL = {"melden": "gemeldet", "mute": "stummgeschaltet", "spam-mute": "stumm (Spam)", "filter-mute": "stumm (Wortfilter)",
         "warn": "verwarnt", "kick": "gekickt"}
def c(v, n=32):
    return re.sub(r"[\x00-\x1f\x7f]", " ", str(v)).strip()[:n] or "?"
counts, names, reporters = {}, {}, {}
for raw in data.split(b"\n"):
    try:
        e = json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        continue
    if not isinstance(e, dict) or e.get("action") not in LABEL:
        continue
    at = e.get("at")
    if not isinstance(at, (int, float)) or isinstance(at, bool) or not now - 7 * 86400 <= at <= now + 300:
        continue
    tid = e.get("targetId")
    key = ("id:" + tid) if isinstance(tid, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", tid) else ("name:" + c(e.get("target")).lower())
    if key == "name:?":
        continue
    counts.setdefault(key, {})
    if e["action"] == "melden":
        # Meldungen zaehlen nur mit Ziel-Konto und je Melder einmal (einer allein kann niemanden zum Taeter machen).
        if not key.startswith("id:"):
            continue
        rep = e.get("byId") or ("name:" + c(e.get("by")).lower())
        reporters.setdefault(key, set()).add(str(rep))
        counts[key]["melden"] = len(reporters[key])
    else:
        counts[key][e["action"]] = counts[key].get(e["action"], 0) + 1
    names[key] = c(e.get("target"))
try:
    seen = json.load(open(state))
    seen = seen if isinstance(seen, dict) else {}
except Exception:
    seen = {}
seen = {k: v for k, v in seen.items() if isinstance(v, (int, float)) and now - v < 30 * 86400}
for key in sorted(counts, key=lambda k: -sum(counts[k].values())):
    total = sum(counts[key].values())
    if counts[key].get("melden", 0) == 1:
        total -= 1                                  # ein einzelner Melder zaehlt nicht
    if total < need or now - seen.get(key, 0) < 7 * 86400:
        continue
    seen[key] = now
    parts = " · ".join(f"{n}× {LABEL[a]}" for a, n in sorted(counts[key].items(), key=lambda x: -x[1]))
    print(f"⚠️ Wiederholt aufgefallen: {names[key]} – {parts} in 7 Tagen (beamnet modlog)")
with open(state + ".tmp", "w") as f:
    json.dump(seen, f)
os.replace(state + ".tmp", state)
PY
)
    return 0
}

watch_modlog() {
    local -n modout=$1
    local line nr map=()
    # Moderation (MODLOG_NOTIFY) und Erfolge von Spielern (Liga, Level, Kilometer: MILESTONE_NOTIFY) getrennt schaltbar.
    [[ $(conf_get MODLOG_NOTIFY) == 0 && $(conf_get MILESTONE_NOTIFY) == 0 ]] && return 0
    [[ -f $SHARED/modlog.jsonl && ! -L $SHARED/modlog.jsonl && ! -L $SHARED ]] || return 0
    command -v python3 >/dev/null || return 0
    for nr in $(servers); do map+=("$(cfg "$nr" Port)=$nr"); done
    while IFS= read -r line; do
        [[ -n $line ]] && modout+=("$line")
    done < <(BEAMNET_MODLOG=$(conf_get MODLOG_NOTIFY) BEAMNET_MILESTONES=$(conf_get MILESTONE_NOTIFY) python3 -I - "$SHARED/modlog.jsonl" "$STATE_DIR/modlog-pos" "${map[@]}" <<'PY' 2>/dev/null
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
    recent_only = False
    try:
        ino, pos = (int(x) for x in open(state).read().split()[:2])
    except Exception:
        ino, pos = st.st_ino, st.st_size          # erster Lauf: ab dem Ende
    if ino != st.st_ino or pos > st.st_size:
        # Neue oder gekuerzte Datei (z. B. nach beamnet restore): von vorn lesen, aber nur Eintraege der letzten
        # 10 Minuten melden – sonst kaeme die ganze alte Geschichte noch einmal.
        pos, recent_only = 0, True
    f.seek(pos)
    chunk = f.read(256 * 1024)
end = chunk.rfind(b"\n") + 1                    # nur vollstaendige Zeilen
if end == 0 and len(chunk) == 256 * 1024:
    end = len(chunk)                              # eine einzige Riesenzeile: ueberspringen statt ewig haengen
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
        e = json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        continue
    if not isinstance(e, dict):
        continue
    at = e.get("at")
    if recent_only and not (isinstance(at, (int, float)) and time.time() - at <= 600):
        continue
    a, by, who = e.get("action"), c(e.get("by", "System")), c(e.get("target"))
    if a in ("liga", "level", "km", "neu"):
        if os.environ.get("BEAMNET_MILESTONES") == "0":
            continue
    elif os.environ.get("BEAMNET_MODLOG") == "0":
        continue
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
    elif a == "event":
        f, u = e.get("factor"), e.get("until")
        if isinstance(f, (int, float)) and isinstance(u, (int, float)) and 1 < f <= 5 and 0 < u < 4e9:
            fs = (f"{f:.1f}".replace(".", ",") if f != int(f) else str(int(f)))
            lines.append(f"🎉 {by} startet ein XP-Event: {fs}-fache XP bis {time.strftime('%H:%M', time.localtime(u))} Uhr – jetzt einsteigen!")
    elif a == "filter-mute":
        sec = e.get("seconds")
        span = f" für {int(sec) // 60} min" if isinstance(sec, (int, float)) and sec >= 60 else ""
        lines.append(f"🔇 {who} wurde wegen Beleidigungen im Chat{span} stummgeschaltet ({where(e)})")
    elif a == "join-spam":
        sec = e.get("seconds")
        span = f" für {int(sec) // 60} min" if isinstance(sec, (int, float)) and sec >= 60 else ""
        lines.append(f"🚫 {who} hat sich zu oft neu verbunden und wird{span} abgewiesen ({where(e)})")
    elif a == "event-stop":
        lines.append(f"🎉 {by} hat das XP-Event beendet")
    elif a == "team-loeschen":
        lines.append(f"🛡️ {by} hat das Team {who} gelöscht")
    elif a == "ort-vorschlag":
        kind = e.get("kind") if isinstance(e.get("kind"), str) and re.fullmatch(r"[a-z]{2,12}", e.get("kind", "")) else "ort"
        lines.append(f"📍 {by} schlägt einen Ort für Aufträge vor: {who} ({kind}, {where(e)}) – im Spiel: /ort vorschlaege")
    elif a == "liga":
        lg = c(e.get("league"), 24)
        lines.append(f"🏅 {who} ist in die Liga {lg} aufgestiegen ({where(e)}) – Glückwunsch!")
    elif a == "neu":
        lines.append(f"👋 {who} ist zum ersten Mal im BeamNet ({where(e)}) – herzlich willkommen!")
    elif a == "level":
        lv = e.get("level")
        if isinstance(lv, int) and not isinstance(lv, bool) and 1 <= lv <= 1000:
            lines.append(f"⭐ {who} hat Level {lv} erreicht ({where(e)}) – Glückwunsch!")
    elif a == "km":
        k = e.get("km")
        if isinstance(k, int) and not isinstance(k, bool) and 1 <= k <= 10 ** 7:
            ks = f"{k:,}".replace(",", ".")
            lines.append(f"🛣️ {who} hat {ks} km im BeamNet geschafft ({where(e)}) – Glückwunsch!")
    elif a == "speed-reset":
        k = e.get("kmh")
        was = f" (war {int(k)} km/h)" if isinstance(k, (int, float)) and 0 <= k < 1e5 else ""
        lines.append(f"🛡️ {by} hat die Höchstgeschwindigkeit von {who} zurückgesetzt{was}")
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
        RESTARTED_NOW+=" $nr "
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
    local usage="" mp
    for nr in $(servers); do
        pl=$(players_of "$(cfg "$nr" Port)")
        if [[ $pl =~ ^([0-9]+)/ ]]; then
            pl=${BASH_REMATCH[1]}
            online=$(( online + pl ))
            mp=$(map_short "$(cfg "$nr" Map)")
            [[ $mp =~ ^[A-Za-z0-9_.-]+$ ]] || mp="?"
            usage+="$nr $mp $pl"$'\n'
        fi
    done
    [[ -n $usage ]] && printf '%s' "$usage" | usage_record
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
    local nr state last name msgs=() auto hang t0=$SECONDS
    auto=$(conf_get AUTO_RESTART)
    watch_heartbeat
    watch_votes msgs
    watch_reports msgs
    watch_modlog msgs
    watch_repeat msgs
    watch_records msgs
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
    watch_slots msgs
    watch_load msgs
    watch_index
    watch_backup msgs
    watch_peak msgs
    watch_capacity msgs
    watch_bonusmap msgs
    watch_online msgs
    watch_autoevent msgs
    watch_weekly msgs
    watch_season msgs
    watch_season_final msgs
    watch_daily msgs
    watch_update msgs
    watch_broken msgs
    watch_telegram
    if (( ${#msgs[@]} > 0 )); then
        printf '%s\n' "${msgs[@]}"
        if notify "$(printf '%s\n' "${msgs[@]}")"; then
            [[ -f $STATE_DIR/update-pending ]] && mv -f "$STATE_DIR/update-pending" "$STATE_DIR/update-notified"
        fi
    fi
    rm -f "$STATE_DIR/update-pending"
    # Dauer des Laufs (fuer beamnet doctor: der Waechter laeuft jede Minute neben den Spieleservern).
    echo $(( SECONDS - t0 )) >"$STATE_DIR/watch-seconds"
    return 0
}

# ---------------------------------------------------------------------------------------------------------------------
# XP-Abende: netzweites XP-Event (event.json, wie /event im Spiel) – von Hand oder automatisch nach Plan (AUTO_EVENT).

# AUTO_EVENT="fr,sa 20:00 2 2h" pruefen; Ausgabe "Tage(1-7, mit Komma) HH MM Faktor Sekunden" oder Fehler.
autoevent_spec() {
    local spec=${1-$(conf_get AUTO_EVENT)} days hhmm factor dur d out="" n
    [[ -n $spec && $spec != 0 && $spec != aus ]] || return 1
    read -r days hhmm factor dur _ <<<"$spec"
    [[ $hhmm =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]] || return 1
    local hh=$(( 10#${BASH_REMATCH[1]} )) mm=${BASH_REMATCH[2]}
    factor=${factor/,/.}
    [[ $factor =~ ^[1-5](\.[0-9])?$ ]] || return 1
    awk -v f="$factor" 'BEGIN { exit !(f >= 1.5 && f <= 5) }' || return 1
    [[ $dur =~ ^([0-9]{1,4})([mh])$ ]] || return 1
    n=${BASH_REMATCH[1]}
    if [[ ${BASH_REMATCH[2]} == h ]]; then n=$(( 10#$n * 3600 )); else n=$(( 10#$n * 60 )); fi
    (( n >= 600 && n <= 6 * 3600 )) || return 1
    case ${days,,} in täglich|taeglich|alle|jeden) out="1,2,3,4,5,6,7" ;;
        *)
            for d in ${days//,/ }; do
                case ${d,,} in
                    mo) out+="1," ;; di) out+="2," ;; mi) out+="3," ;; do) out+="4," ;; fr) out+="5," ;;
                    sa) out+="6," ;; so) out+="7," ;; *) return 1 ;;
                esac
            done
            out=${out%,} ;;
    esac
    [[ -n $out ]] || return 1
    printf '%s %02d %s %s %s\n' "$out" "$hh" "$mm" "$factor" "$n"
}

# Stand fuer Telegram und "beamnet event": laufendes XP-Event (Faktor, Ende, von wem) und der Plan fuer XP-Abende.
event_status_text() {
    local text spec
    text=$( { safe get "$SHARED/event.json" 2>/dev/null || true; } | python3 -I -c '
import json, re, sys, time
try:
    d = json.loads(sys.stdin.read(65536))
    f, until = float(d.get("factor", 1)), float(d.get("until", 0))
    if f <= 1 or until <= time.time():
        raise ValueError
    by = " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(d.get("by", "?"))).split())[:40]
    fs = ("%g" % f).replace(".", ",")
    print("⚡ XP-Event läuft: %s-fache XP bis %s Uhr (von %s)" % (fs, time.strftime("%H:%M", time.localtime(until)), by))
except Exception:
    print("Gerade läuft kein XP-Event.")' 2>/dev/null)
    [[ -n $text ]] || text="Gerade läuft kein XP-Event."
    spec=$(conf_get AUTO_EVENT)
    if autoevent_spec >/dev/null; then text+=$'\n'"🗓️ XP-Abend geplant: $spec"; fi
    spec=$(bonusmap_line)
    [[ -n $spec ]] && text+=$'\n'"$spec"
    printf '%s\n' "$text"
}

# Bonus-Map des Tages aus bonusmap.json als Zeile ("🗺️ Bonus-Map heute: utah (+50 % XP beim Fahren)"), solange sie
# gilt; sonst nichts.
bonusmap_line() {
    # Nur die Map, die der Waechter heute selbst gewaehlt hat (bonusmap.json darf der Dienst aendern).
    local own
    own=$(tail -n 1 "$STATE_DIR/bonusmap-$(date +%F)" 2>/dev/null)
    [[ $own =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
    { safe get "$SHARED/bonusmap.json" 2>/dev/null || true; } | python3 -I -c '
import json, re, sys, time
try:
    d = json.loads(sys.stdin.read(4096))
    m, f, until = d["map"], float(d["factor"]), float(d["until"])
except Exception:
    sys.exit(0)
if m == sys.argv[1] and re.fullmatch(r"[A-Za-z0-9_.-]+", m) and 1 < f <= 3 and time.time() < until:
    print("🗺️ Bonus-Map heute: %s (+%d %% XP beim Fahren)" % (m, int((f - 1) * 100 + 0.5)))' "$own" 2>/dev/null
}

# Naechster XP-Abend aus xpabend.json als Zeile ("🎉 Nächster XP-Abend: Fr 20:00–22:00 Uhr (2-fache XP)"), nur wenn
# er hoechstens <Tage> Tage entfernt ist; sonst nichts.
xpabend_line() {
    # Aus der eigenen Kopie (autoevent_publish), nicht aus dem gemeinsamen Ordner.
    { head -c 4096 "$STATE_DIR/xpabend.json" 2>/dev/null || true; } | python3 -I -c '
import json, sys, time
try:
    d = json.loads(sys.stdin.read(4096))
    at, f, sec, days = float(d["next"]), float(d["factor"]), float(d["sec"]), float(sys.argv[1])
except Exception:
    sys.exit(0)
now = time.time()
if not (now < at <= now + days * 86400 and 1.5 <= f <= 5 and 0 < sec <= 6 * 3600):
    sys.exit(0)
day = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"][time.localtime(at).tm_wday]
if time.strftime("%F", time.localtime(at)) == time.strftime("%F", time.localtime(now)):
    day = "heute"
fs = ("%g" % f).replace(".", ",")
print("🎉 Nächster XP-Abend: %s %s–%s Uhr (%s-fache XP)" % (day, time.strftime("%H:%M", time.localtime(at)),
      time.strftime("%H:%M", time.localtime(at + sec)), fs))' "$1" 2>/dev/null
}

# Laeuft gerade ein XP-Event (event.json mit "until" in der Zukunft)?
event_running() {
    [[ -f $SHARED/event.json ]] || return 1
    safe get "$SHARED/event.json" 2>/dev/null | python3 -I -c '
import json, sys, time
try:
    d = json.loads(sys.stdin.read(65536))
    sys.exit(0 if isinstance(d, dict) and float(d.get("until", 0)) > time.time() and float(d.get("factor", 1)) > 1 else 1)
except Exception:
    sys.exit(1)'
}

# event_write <Faktor> <Sekunden> <von>: XP-Event fuer alle Server schreiben (Faktor 1 = beenden).
event_write() {
    [[ -d $SHARED && ! -L $SHARED ]] || return 1
    python3 -I -c '
import json, sys, time
f, sec, by = float(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
now = int(time.time())
ev = {"factor": f, "until": now + sec, "by": by, "at": now, "id": "%d-%s" % (now, "stop" if f <= 1 else "konsole")}
print(json.dumps(ev, ensure_ascii=False))' "$1" "$2" "$3" | safe put "$SHARED/event.json" 664 "$SERVICE_USER"
}

# beamnet event: Stand · start <Faktor> <Dauer> · stop · auto <Tage> <HH:MM> <Faktor> <Dauer> · auto aus
cmd_event() {
    local sub=${1:-} spec
    case $sub in
        ""|status)
            event_status_text | head -n 1
            spec=$(conf_get AUTO_EVENT)
            if autoevent_spec >/dev/null; then echo "Automatischer XP-Abend: $spec"
            else echo "Automatischer XP-Abend: aus (beamnet event auto fr,sa 20:00 2 2h)"; fi
            bonusmap_line
            ;;
        start)
            need_root event
            local f=${2:-} d=${3:-}
            spec=$(autoevent_spec "mo 00:00 $f $d") || die "Aufruf: beamnet event start <Faktor 1,5–5> <Dauer 10m–6h, z. B. 2h>"
            read -r _ _ _ f d <<<"$spec"
            event_write "$f" "$d" "Konsole" || die "Konnte das Event nicht speichern."
            ok "XP-Event gestartet: ${f/./,}-fache XP für $(( d / 60 )) Minuten auf allen Servern."
            ;;
        stop)
            need_root event
            event_write 1 0 "Konsole" || die "Konnte das Event nicht beenden."
            ok "XP-Event beendet."
            ;;
        auto)
            need_root event
            shift
            if [[ ${1:-} == aus || ${1:-} == off || ${1:-} == 0 ]]; then conf_set AUTO_EVENT ""; autoevent_publish; ok "Automatischer XP-Abend aus."; return 0; fi
            spec="$*"
            autoevent_spec "$spec" >/dev/null || die "Aufruf: beamnet event auto <Tage, z. B. fr,sa oder täglich> <HH:MM> <Faktor 1,5–5> <Dauer 10m–6h> – z. B. beamnet event auto fr,sa 20:00 2 2h"
            conf_set AUTO_EVENT "$spec"
            autoevent_publish
            ok "Automatischer XP-Abend: $spec – eine Stunde vorher kommt eine Ankündigung (Spiel, Discord/Telegram)."
            [[ -f $SYSTEMD_DIR/beamnet-watch.timer ]] || echo "Hinweis: Der XP-Abend braucht den Wächter – beamnet watch install"
            ;;
        *) die "Aufruf: beamnet event [start <Faktor> <Dauer>|stop|auto <Tage> <HH:MM> <Faktor> <Dauer>|auto aus]" ;;
    esac
}

# Bonus-Map des Tages: die Map der eingerichteten Server mit den wenigsten Spielerminuten der letzten 7 Tage (aus den
# usage-Dateien) bekommt bis Mitternacht BONUS_MAP_FACTOR-fache XP beim Fahren (Standard 1.5) – so verteilen sich die
# Spieler besser. Einmal am Tag; BONUS_MAP=0 schaltet ab. bonusmap.json liest das Plugin. Die gewaehlten Maps des Tages
# stehen (eine je Zeile) in der eigenen Datei STATE_DIR/bonusmap-<Tag> – nicht in bonusmap.json, die der Dienst
# beschreiben darf.
watch_bonusmap() {
    local -n bmout=$1
    [[ -d $SHARED && ! -L $SHARED ]] || return 0
    command -v python3 >/dev/null || return 0
    local today factor nr mp maps=() pick until json where="" pct stamp
    today=$(date +%F)
    stamp=$STATE_DIR/bonusmap-$today
    if [[ -s $stamp ]]; then
        # Laeuft die Bonus-Map nach einer Map-Rotation oder -Abstimmung auf keinem Server mehr: neu waehlen – hoechstens
        # dreimal am Tag. Heute nichts gewaehlt (aus, nur eine Map, "-"): nichts zu tun.
        local cur on=0
        cur=$(tail -n 1 "$stamp" 2>/dev/null)
        [[ $cur =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
        (( $(wc -l <"$stamp") < 3 )) || return 0
        for nr in $(servers); do [[ $(map_short "$(cfg "$nr" Map)") == "$cur" ]] && on=1; done
        (( on )) && return 0
    elif [[ ! -f $stamp ]]; then
        # Leere Datei = heute noch nichts gewaehlt (z. B. Schreiben fehlgeschlagen): naechste Minute erneut versuchen.
        : >"$stamp"
        find "$STATE_DIR" -maxdepth 1 -name 'bonusmap-*' -mtime +3 -delete 2>/dev/null
    fi
    if [[ $(conf_get BONUS_MAP) == 0 ]]; then
        printf '{"map":""}' | safe put "$SHARED/bonusmap.json" 664 "$SERVICE_USER" 2>/dev/null
        echo - >>"$stamp"
        return 0
    fi
    factor=$(conf_get BONUS_MAP_FACTOR)
    if ! [[ $factor =~ ^[1-3](\.[0-9])?$ ]] || ! awk -v f="$factor" 'BEGIN { exit !(f > 1) }'; then factor=1.5; fi
    for nr in $(servers); do
        mp=$(map_short "$(cfg "$nr" Map)")
        [[ -n $mp ]] && maps+=("$mp")
    done
    (( ${#maps[@]} > 0 )) || return 0
    pick=$(python3 -I - "$STATE_DIR" "${maps[@]}" <<'PY' 2>/dev/null
import datetime, os, re, sys
state, maps = sys.argv[1], sorted(set(sys.argv[2:]))
if len(maps) < 2:
    sys.exit(0)                      # nur eine Map: kein Bonus noetig
cut = (datetime.date.today() - datetime.timedelta(days=7)).isoformat()
minutes = {m: 0 for m in maps}
for name in os.listdir(state):
    d = re.fullmatch(r"usage-(\d{4}-\d{2}-\d{2})", name)
    if not d or d.group(1) <= cut:
        continue
    try:
        lines = open(os.path.join(state, name), encoding="utf-8", errors="replace").read(1 << 20).splitlines()
    except OSError:
        continue
    for line in lines:
        f = line.split()
        if len(f) == 4 and f[1] in minutes and f[3].isdigit():
            minutes[f[1]] += int(f[3])
print(min(maps, key=lambda m: (minutes[m], m)))
PY
)
    if ! [[ $pick =~ ^[A-Za-z0-9_.-]+$ ]]; then
        # Keine Wahl (nur noch eine Map): eine alte Bonus-Map nicht weiter anzeigen, bis morgen Ruhe.
        [[ -s $stamp ]] && printf '{"map":""}' | safe put "$SHARED/bonusmap.json" 664 "$SERVICE_USER" 2>/dev/null
        echo - >>"$stamp"
        return 0
    fi
    until=$(date -d "$(date -d tomorrow +%F) 00:00" +%s)
    json="{\"map\":\"$pick\",\"factor\":$factor,\"until\":$until,\"day\":\"$today\"}"
    printf '%s' "$json" | safe put "$SHARED/bonusmap.json" 664 "$SERVICE_USER" 2>/dev/null || return 0
    echo "$pick" >>"$stamp"
    for nr in $(servers); do [[ $(map_short "$(cfg "$nr" Map)") == "$pick" ]] && where+="${where:+, }$nr"; done
    pct=$(awk -v f="$factor" 'BEGIN { printf "%d", (f - 1) * 100 + 0.5 }')
    bmout+=("🗺️ Bonus-Map heute: $pick (Server $where) – +$pct % XP beim Fahren bis Mitternacht.")
    return 0
}

# Neu beiseitegelegte kaputte Dateien des Plugins (<datei>.kaputt-<Zeit>) einmal melden: der Spieler bzw. die Teams
# fangen dort neu an, die Daten lassen sich aus der Datensicherung zurueckholen. Erster Lauf: nur merken.
watch_broken() {
    local -n bout2=$1
    [[ -d $SHARED && ! -L $SHARED ]] || return 0
    local stamp=$STATE_DIR/broken-seen n names=() other=0 text
    if [[ ! -f $stamp ]]; then : >"$stamp"; return 0; fi
    # Neuen Merker vor der Suche anlegen: was waehrend der Suche beiseitegelegt wird, kommt beim naechsten Lauf.
    : >"$stamp.neu"
    # ctime (Umbenennen aendert sie, die mtime nicht); Namen nur in der erwarteten Form, sonst nur gezaehlt.
    while IFS= read -r -d '' n; do
        if [[ $n =~ ^[A-Za-z0-9_-]+(/[A-Za-z0-9_.-]+)?\.kaputt-[0-9]+$ ]] && (( ${#names[@]} < 5 )); then names+=("$n"); else other=$(( other + 1 )); fi
    done < <(find "$SHARED" -maxdepth 2 -name '*.kaputt-*' -cnewer "$stamp" -printf '%P\0' 2>/dev/null | head -z -n 200)
    mv -f "$stamp.neu" "$stamp"
    (( ${#names[@]} + other > 0 )) || return 0
    text="${names[*]}"
    (( other > 0 )) && text+="${text:+ }(+$other weitere)"
    bout2+=("⚠️ BeamNetCore hat kaputte Dateien beiseitegelegt: $text – dort wird neu angefangen. Zurückholen: beamnet restore <Datum> spieler <ID>")
}

# Update-Hinweis: einmal am Tag nachsehen, ob es auf GitHub ein neueres Werkzeug gibt, und je neuer Version einmal
# melden ("sudo beamnet update"). Installiert nichts selbst. UPDATE_CHECK=0 schaltet ab.
watch_update() {
    local -n uout=$1
    [[ $(conf_get UPDATE_CHECK) == 0 ]] && return 0
    notify_configured || return 0
    local today latest lm ln cm cn
    today=$(date +%F)
    [[ -f $STATE_DIR/updatecheck-$today ]] && return 0
    # Nach einem Netzfehler hoechstens einmal je Stunde erneut versuchen.
    [[ -n $(find "$STATE_DIR/updatecheck-try" -mmin -60 2>/dev/null) ]] && return 0
    : >"$STATE_DIR/updatecheck-try"
    find "$STATE_DIR" -maxdepth 1 -name 'updatecheck-*' -mtime +3 -delete 2>/dev/null
    latest=$(curl -fsS -m 10 -r 0-4095 "$RAW_BASE/beamnet.sh" 2>/dev/null | head -c 4096 | grep -m1 -xE 'VERSION="[0-9]{1,3}\.[0-9]{1,3}"' | cut -d'"' -f2)
    [[ $latest =~ ^[0-9]{1,3}\.[0-9]{1,3}$ && $VERSION =~ ^[0-9]+\.[0-9]+$ ]] || return 0
    : >"$STATE_DIR/updatecheck-$today"
    lm=${latest%%.*} ln=${latest#*.} cm=${VERSION%%.*} cn=${VERSION#*.}
    (( 10#$lm > 10#$cm || (10#$lm == 10#$cm && 10#$ln > 10#$cn) )) || return 0
    [[ $(cat "$STATE_DIR/update-notified" 2>/dev/null) == "$latest" ]] && return 0
    # Gemerkt wird erst, wenn die Meldung angekommen ist (watch_run); sonst kommt sie am naechsten Tag noch einmal.
    echo "$latest" >"$STATE_DIR/update-pending"
    uout+=("🆕 BeamNet-Update verfügbar: Werkzeug $latest (installiert: $VERSION) – auf dem Server: sudo beamnet update")
}

# Naechsten geplanten XP-Abend fuer Plugin und Statusseite in xpabend.json schreiben ({"next":0} = keiner), nur wenn
# sich etwas aendert (der Waechter laeuft jede Minute).
autoevent_publish() {
    [[ -d $SHARED && ! -L $SHARED ]] || return 0
    local spec days hh mm factor secs now off day start next=0 json old
    now=${BEAMNET_NOW:-$(date +%s)}
    if spec=$(autoevent_spec); then
        read -r days hh mm factor secs <<<"$spec"
        local base
        base=$(date -d "@$now" +%F)
        for off in 0 1 2 3 4 5 6 7; do
            day=$(date -d "$base +$off days" +%F)     # Kalendertage (nicht 86400 s: Zeitumstellung)
            [[ ,$days, == *",$(date -d "$day 12:00" +%u),"* ]] || continue
            start=$(date -d "$day $hh:$mm" +%s 2>/dev/null) || continue
            if (( start > now )); then next=$start; break; fi
        done
    fi
    if (( next > 0 )); then
        json="{\"next\":$next,\"factor\":$factor,\"sec\":$secs}"
    else
        json='{"next":0}'
    fi
    # Eigene Kopie fuer die Meldungen (xpabend_line): die Datei im gemeinsamen Ordner darf der Dienst aendern.
    { printf '%s' "$json" >"$STATE_DIR/xpabend.json"; } 2>/dev/null
    old=$(safe get "$SHARED/xpabend.json" 2>/dev/null | head -c 4096)
    [[ $old == "$json" ]] && return 0
    printf '%s' "$json" | safe put "$SHARED/xpabend.json" 664 "$SERVICE_USER" 2>/dev/null
    return 0
}

# Automatischer XP-Abend: eine Stunde vorher Ankuendigung (Discord/Telegram und im Spiel), zur Startzeit startet der
# Waechter das netzweite XP-Event (in den ersten 10 Minuten; nicht, wenn schon eines laeuft). Jeweils einmal am Tag.
watch_autoevent() {
    local -n aout=$1
    local spec days hh mm factor secs now start key endt nice off day
    autoevent_publish
    spec=$(autoevent_spec) || return 0
    read -r days hh mm factor secs <<<"$spec"
    now=${BEAMNET_NOW:-$(date +%s)}
    nice=${factor/./,}
    nice=${nice%,0}
    # Heute und morgen pruefen: ein Abend kurz nach Mitternacht wird schon am Vorabend angekuendigt.
    local base
    base=$(date -d "@$now" +%F)
    for off in 0 1; do
        day=$(date -d "$base +$off days" +%F)
        [[ ,$days, == *",$(date -d "$day 12:00" +%u),"* ]] || continue
        key=$day
        if ! start=$(date -d "$key $hh:$mm" +%s 2>/dev/null); then
            # Gibt es die Uhrzeit an diesem Tag nicht (Zeitumstellung), einmal melden statt still ausfallen.
            if (( off == 0 )) && [[ ! -f $STATE_DIR/autoevent-start-$key ]]; then
                : >"$STATE_DIR/autoevent-start-$key"
                aout+=("⚠️ XP-Abend: $hh:$mm Uhr gibt es heute nicht (Zeitumstellung) – heute kein automatischer XP-Abend.")
            fi
            continue
        fi
        endt=$(date -d "@$(( start + secs ))" +%H:%M)
        if (( now >= start - 3600 && now < start )) && [[ ! -f $STATE_DIR/autoevent-warn-$key ]]; then
            : >"$STATE_DIR/autoevent-warn-$key"
            local when="Heute"
            [[ $(date -d "@$now" +%F) == "$key" ]] || when="Gleich"
            aout+=("🎉 $when $hh:$mm–$endt Uhr: XP-Abend mit $nice-facher XP auf allen BeamNet-Servern – kommt vorbei!")
            (YES=1 ANSAGE_BY="XP-Abend" cmd_ansage "🎉 $when $hh:$mm–$endt Uhr: XP-Abend mit $nice-facher XP auf allen Servern!") >/dev/null 2>&1
        fi
        if (( now >= start && now < start + 600 )) && [[ ! -f $STATE_DIR/autoevent-start-$key ]]; then
            if event_running; then
                # Laeuft noch ein anderes Event: bis zum Ende des 10-Minuten-Fensters weiter versuchen.
                if (( now >= start + 540 )); then
                    : >"$STATE_DIR/autoevent-start-$key"
                    aout+=("ℹ️ XP-Abend: es läuft schon ein XP-Event – kein zweites gestartet.")
                fi
            elif event_write "$factor" "$(( start + secs - now ))" "XP-Abend"; then
                : >"$STATE_DIR/autoevent-start-$key"
                aout+=("🚀 XP-Abend läuft: $nice-fache XP bis $endt Uhr auf allen Servern.")
            elif [[ ! -f $STATE_DIR/autoevent-fail-$key ]]; then
                : >"$STATE_DIR/autoevent-fail-$key"
                aout+=("⚠️ XP-Abend konnte nicht gestartet werden (gemeinsamer Ordner? beamnet doctor) – nächster Versuch in einer Minute.")
            fi
        fi
    done
    find "$STATE_DIR" -maxdepth 1 -name 'autoevent-*' -mtime +3 -delete 2>/dev/null
    return 0
}

# Last je Server aus der systemd-Abrechnung: CPU (% eines Kerns, gemessen zwischen zwei Laeufen) und RAM. Warnung,
# wenn ein Server LOAD_MINUTES Laeufe lang ueber CPU_WARN % liegt oder mehr als MEM_WARN_MB belegt – jeweils einmal,
# Entwarnung, sobald es wieder passt. Werte "-" schalten die Pruefung ab.
watch_load() {
    local -n lout=$1
    local nr u cpu mem now pcpu pat pct high cpu_warn mem_warn minutes name
    cpu_warn=$(conf_get CPU_WARN); [[ $cpu_warn =~ ^[0-9]{1,3}$ || $cpu_warn == - ]] || cpu_warn=90
    mem_warn=$(conf_get MEM_WARN_MB); [[ $mem_warn =~ ^[0-9]{1,6}$ || $mem_warn == - ]] || mem_warn=1500
    minutes=$(conf_get LOAD_MINUTES); [[ $minutes =~ ^[0-9]{1,2}$ ]] && (( 10#$minutes > 0 )) || minutes=5
    now=$(date +%s)
    for nr in $(servers); do
        unit_active "$nr" || { rm -f "$STATE_DIR/cpu-$nr" "$STATE_DIR/cpuhigh-$nr"; continue; }
        u=$(unit "$nr")
        name="Server $nr ($(map_short "$(cfg "$nr" Map)"))"
        cpu=$(systemctl show -p CPUUsageNSec --value "$u" 2>/dev/null)
        mem=$(systemctl show -p MemoryCurrent --value "$u" 2>/dev/null)
        if [[ $cpu_warn != - && $cpu =~ ^[0-9]+$ ]]; then
            read -r pcpu pat < <(cat "$STATE_DIR/cpu-$nr" 2>/dev/null; echo)
            echo "$cpu $now" >"$STATE_DIR/cpu-$nr"
            if [[ $pcpu =~ ^[0-9]+$ && $pat =~ ^[0-9]+$ ]] && (( now - pat >= 20 && cpu >= pcpu )); then
                pct=$(( (cpu - pcpu) / ((now - pat) * 10000000) ))
                high=$(cat "$STATE_DIR/cpuhigh-$nr" 2>/dev/null); [[ $high =~ ^[0-9]+$ ]] || high=0
                if (( pct >= 10#$cpu_warn )); then
                    high=$(( high + 1 ))
                    (( high == 10#$minutes )) && lout+=("🔥 $name ist seit $minutes Minuten ausgelastet (CPU ${pct} %) – Spieler merken Ruckler. beamnet logs $nr")
                else
                    (( high >= 10#$minutes )) && lout+=("✅ $name ist nicht mehr ausgelastet (CPU ${pct} %).")
                    high=0
                fi
                echo "$high" >"$STATE_DIR/cpuhigh-$nr"
            fi
        fi
        if [[ $mem_warn != - && $mem =~ ^[0-9]+$ ]]; then
            if (( mem / 1048576 > 10#$mem_warn )); then
                if [[ ! -f $STATE_DIR/memhigh-$nr ]]; then
                    : >"$STATE_DIR/memhigh-$nr"
                    lout+=("🧠 $name belegt $(( mem / 1048576 )) MB RAM (Grenze $mem_warn MB) – ein Neustart in einer ruhigen Minute hilft meist.")
                fi
            elif [[ -f $STATE_DIR/memhigh-$nr ]] && (( mem / 1048576 < 10#$mem_warn * 9 / 10 )); then
                rm -f "$STATE_DIR/memhigh-$nr"
                lout+=("✅ $name belegt wieder $(( mem / 1048576 )) MB RAM.")
            fi
        fi
    done
    return 0
}

# Bestenlisten-Index fuer das Plugin (ab 1.13; Format 2 mit Hoechstgeschwindigkeit ab Plugin 1.21, Format 3 mit
# Auftraegen ab Plugin 1.37, Format 4 mit Konvoi-km und gewonnenen Jagden ab Plugin 1.71 – aeltere Plugins erkennen das neue Format nicht und lesen dann wie frueher alle Dateien, bis
# beamnet update sie erneuert): eine Zeile je Spieler in players-index.tsv. So liest jeder Server
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
    return re.sub(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]", "", str(v))[:64]

out = [f"# beamnet-index 4 {int(time.time())}"]
try:
    pdir = os.open(os.path.join(shared, "players"), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError:
    sys.exit(1)

def load_at(name):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=pdir)
    except OSError:
        return None
    try:
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                return None
            r = json.loads(f.read(4 * 1024 * 1024).decode("utf-8", "replace"))
    except Exception:
        return None
    return r if isinstance(r, dict) else None

for name in sorted(n for n in os.listdir(pdir) if n.endswith(".json")):
    r = load_at(name)
    if not r or not isinstance(r.get("id"), str) or not ID_OK.fullmatch(r["id"]):
        continue
    month_xp = r.get("monthXp")
    if month_xp is None and all(isinstance(r.get(k), (int, float)) for k in ("xp", "monthStartXp")):
        month_xp = r["xp"] - r["monthStartXp"]       # Datensatz von 1.8
    out.append("\t".join([r["id"], text(r.get("name", "?")), num(r.get("km")), num(r.get("seconds")),
                          num(r.get("bonusXp")), key(r.get("week")), num(r.get("weekKm")), key(r.get("lastWeek")),
                          num(r.get("lastWeekKm")), key(r.get("month")), num(month_xp), key(r.get("lastMonth")),
                          num(r.get("lastMonthXp")), num(r.get("topSpeedKmh")), num(r.get("jobsDone")),
                          num(r.get("convoyKm")), num(r.get("chaseWins"))]))
sys.stdout.write("\n".join(out) + "\n")
PY
)
    # Nur einen vollstaendigen Index schreiben (bei einem Fehler bleibt der alte; das Plugin erkennt veraltete).
    [[ $idx == "# beamnet-index 4 "* ]] && printf '%s\n' "$idx" | safe put "$SHARED/players-index.tsv" 644
    return 0
}

# Netzwerk fast voll: ab CAPACITY_WARN % (Standard 90) aller Plaetze einmal melden, mit den Servern, die noch Platz
# haben; Entwarnung unter 80 %. CAPACITY_WARN=- schaltet ab.
watch_capacity() {
    local -n cout=$1
    local warn nr pl used=0 total=0 free="" pct
    warn=$(conf_get CAPACITY_WARN)
    [[ $warn == - ]] && return 0
    [[ $warn =~ ^[0-9]{1,3}$ ]] && (( 10#$warn > 0 )) || warn=90
    for nr in $(servers); do
        pl=$(players_of "$(cfg "$nr" Port)")
        [[ $pl =~ ^([0-9]+)/([0-9]+)$ ]] || continue
        used=$(( used + BASH_REMATCH[1] ))
        total=$(( total + BASH_REMATCH[2] ))
        (( BASH_REMATCH[2] > BASH_REMATCH[1] )) && free+="Server $nr ($(map_short "$(cfg "$nr" Map)")): $(( BASH_REMATCH[2] - BASH_REMATCH[1] )) frei · "
    done
    (( total > 0 )) || return 0
    pct=$(( used * 100 / total ))
    if (( pct >= 10#$warn )); then
        if [[ ! -f $STATE_DIR/capacity-high ]]; then
            : >"$STATE_DIR/capacity-high"
            if [[ -n $free ]]; then free="Noch Platz: ${free% · }"; else free="Alle Server sind voll – Zeit für einen weiteren Server?"; fi
            cout+=("📈 Netzwerk fast voll: $used von $total Plätzen belegt ($pct %). $free")
        fi
    elif [[ -f $STATE_DIR/capacity-high ]] && (( pct < 80 )); then
        rm -f "$STATE_DIR/capacity-high"
        cout+=("✅ Wieder Platz im Netzwerk: $used von $total Plätzen belegt.")
    fi
    return 0
}

# Abstand der Netzwerk-Uebersicht in Minuten: NETWORK_REPORT (0 = aus); fehlt er, gilt 10 – ausser die alte
# Wer-ist-online-Meldung wurde mit ONLINE_REPORT=0 abgeschaltet.
online_report_min() {
    local m
    m=$(conf_get NETWORK_REPORT)
    if [[ $m =~ ^[0-9]{1,4}$ ]]; then echo $(( 10#$m )); return; fi
    m=$(conf_get ONLINE_REPORT)
    if [[ $m =~ ^0+$ ]]; then echo 0; else echo 10; fi
}

# Netzwerk-Uebersicht: Kopfzeile mit Gesamtzahl, je belegtem Server Spieler/Plaetze und Namen (Gaeste gezaehlt), leere
# Server und Server ohne Lebenszeichen in je einer Zeile, Auslastung je Map (am vollsten zuerst, 🔥 ab 80 %).
network_lines() {
    local nr port pl cur mx mxs map names total=0 busy=0 count=0 empty="" silent="" body="" pct m maprows=""
    local -A map_pl=() map_mx=()
    for nr in $(servers); do
        count=$(( count + 1 ))
        port=$(cfg "$nr" Port)
        pl=$(players_of "$port")
        map=$(map_short "$(cfg "$nr" Map)")
        map=${map:-?}
        if [[ ! $pl =~ ^([0-9]+)/([0-9]*) ]]; then
            silent+="${silent:+, }$nr"
            continue
        fi
        cur=${BASH_REMATCH[1]}
        mxs=${BASH_REMATCH[2]:-?}
        mx=${BASH_REMATCH[2]:-0}
        total=$(( total + cur ))
        map_pl[$map]=$(( ${map_pl[$map]:-0} + cur ))
        map_mx[$map]=$(( ${map_mx[$map]:-0} + mx ))
        if (( cur == 0 )); then
            empty+="${empty:+, }$nr"
            continue
        fi
        busy=$(( busy + 1 ))
        names=$(names_of "$port")
        body+="Server $nr · $map: $cur/$mxs"
        (( mx > 0 && cur * 100 >= mx * 80 )) && body+=" 🔥"
        [[ -n $names ]] && body+=" – $names"
        body+=$'\n'
    done
    printf '📊 BeamNet: %s Spieler · %s von %s Servern belegt\n' "$total" "$busy" "$count"
    printf '%s' "$body"
    [[ -n $empty ]] && printf 'Leer: Server %s\n' "$empty"
    [[ -n $silent ]] && printf 'Ohne Lebenszeichen: Server %s\n' "$silent"
    local mp mm bonus="" tag
    [[ $(bonusmap_line) =~ Bonus-Map\ heute:\ ([A-Za-z0-9_.-]+) ]] && bonus=${BASH_REMATCH[1]}
    for m in "${!map_pl[@]}"; do
        mp=${map_pl[$m]}
        mm=${map_mx[$m]}
        tag=""
        [[ $m == "$bonus" ]] && tag=" ⭐ Bonus"
        if (( mm > 0 )); then
            pct=$(( (mp * 100 + mm / 2) / mm ))
            maprows+="$pct"$'\t'"$m $mp/$mm ($pct %$( (( pct >= 80 )) && printf ' 🔥'))$tag"$'\n'
        else
            maprows+="0"$'\t'"$m $mp Spieler$tag"$'\n'
        fi
    done
    if [[ -n $maprows ]]; then
        printf '🗺️ Maps: %s\n' "$(printf '%s' "$maprows" | sort -t$'\t' -k1,1nr -k2,2 | head -n 8 | cut -f2- | awk '{ printf "%s%s", (NR > 1 ? " · " : ""), $0 }')"
    fi
}

# Netzwerk-Uebersicht an Discord/Telegram: alle NETWORK_REPORT Minuten (Standard 10), solange jemand spielt. Ist sie
# unveraendert, kommt sie hoechstens alle dreifachen Abstand; wird das Netzwerk leer, einmal "niemand online".
watch_online() {
    local -n oout=$1
    local every now last=0 lines total=0 fingerprint line head
    every=$(online_report_min)
    (( every > 0 )) || return 0
    notify_configured || return 0
    now=$(date +%s)
    last=$(cat "$STATE_DIR/online-at" 2>/dev/null)
    [[ $last =~ ^[0-9]+$ ]] || last=0
    (( now - last >= every * 60 )) || return 0
    lines=$(network_lines)
    head=${lines%%$'\n'*}
    [[ $head =~ BeamNet:\ ([0-9]+)\ Spieler ]] && total=${BASH_REMATCH[1]}
    if (( total == 0 )); then
        # Nur einmal melden, dass es leer geworden ist (nicht die ganze Nacht).
        [[ $(cat "$STATE_DIR/online-who" 2>/dev/null) == leer || ! -s $STATE_DIR/online-who ]] && return 0
        oout+=("📊 BeamNet: gerade niemand online.")
        echo "$now" >"$STATE_DIR/online-at"
        echo leer >"$STATE_DIR/online-who"
        return 0
    fi
    fingerprint=$(printf '%s' "$lines" | cksum)
    if [[ $fingerprint == "$(cat "$STATE_DIR/online-who" 2>/dev/null)" ]] && (( now - last < 3 * every * 60 )); then
        return 0
    fi
    oout+=("$head")
    while IFS= read -r line; do [[ -n $line ]] && oout+=("   $line"); done < <(printf '%s\n' "$lines" | tail -n +2)
    echo "$now" >"$STATE_DIR/online-at"
    echo "$fingerprint" >"$STATE_DIR/online-who"
    return 0
}

# Telegram-Befehle: neue Nachrichten im eingetragenen Chat (TELEGRAM_CHAT) holen und /online, /top, /rekord,
# /server, /hilfe beantworten (hoechstens 5 je Lauf; Antwort also innerhalb einer Minute). Nachrichten aus anderen
# Chats werden ignoriert. TELEGRAM_COMMANDS=0 schaltet ab.
watch_telegram() {
    local token chat offset raw cmd arg reply n=0 total nr pl
    # Nur, wenn ausdruecklich eingeschaltet: getUpdates "verbraucht" die Nachrichten – ein anderes Programm mit
    # demselben Bot-Token bekaeme sie sonst nicht mehr (aeltere Konfigurationen ohne den Schluessel: aus).
    [[ $(conf_get TELEGRAM_COMMANDS) == 1 ]] || return 0
    token=$(conf_get TELEGRAM_TOKEN)
    chat=$(conf_get TELEGRAM_CHAT)
    [[ $token =~ ^[0-9]{5,}:[A-Za-z0-9_-]{20,}$ && $chat =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,})$ ]] || return 0
    command -v python3 >/dev/null || return 0
    offset=$(cat "$STATE_DIR/telegram-offset" 2>/dev/null)
    [[ $offset =~ ^[0-9]+$ ]] || offset=0
    # Eigener Bot-Name (einmal am Tag per getMe): "/online@AndererBot" in Gruppen ist nicht fuer uns.
    local botname=""
    if [[ ! -f $STATE_DIR/telegram-bot || -n $(find "$STATE_DIR/telegram-bot" -mmin +1440 2>/dev/null) ]]; then
        curl -fsS -m 10 -K <(printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$token") 2>/dev/null \
            | grep -o '"username":"[A-Za-z0-9_]*"' | head -n1 | cut -d'"' -f4 >"$STATE_DIR/telegram-bot.new"
        # Nur einen echten Namen merken; bei einem Fehler beim naechsten Lauf erneut fragen.
        if [[ -s $STATE_DIR/telegram-bot.new ]]; then mv "$STATE_DIR/telegram-bot.new" "$STATE_DIR/telegram-bot"; else rm -f "$STATE_DIR/telegram-bot.new"; fi
    fi
    botname=$(head -c 64 "$STATE_DIR/telegram-bot" 2>/dev/null | tr -cd 'A-Za-z0-9_')
    # Befehlsliste einmal je Version bei Telegram hinterlegen (setMyCommands): Telegram schlaegt die Befehle dann beim
    # Tippen von "/" vor – ohne Umweg ueber @BotFather.
    if [[ $(cat "$STATE_DIR/telegram-commands" 2>/dev/null) != "$VERSION" \
          && $(cat "$STATE_DIR/telegram-commands-try" 2>/dev/null) != "$VERSION $(date +%F)" ]]; then
        echo "$VERSION $(date +%F)" >"$STATE_DIR/telegram-commands-try"
        if curl -fsS -m 10 -H "Content-Type: application/json" -d "$TG_COMMANDS_JSON" \
            -K <(printf 'url = "https://api.telegram.org/bot%s/setMyCommands"\n' "$token") >/dev/null 2>&1; then
            echo "$VERSION" >"$STATE_DIR/telegram-commands"
        fi
    fi
    raw=$(curl -fsS -m 10 -K <(printf 'url = "https://api.telegram.org/bot%s/getUpdates?offset=%s&timeout=0&allowed_updates=%%5B%%22message%%22%%5D"\n' "$token" "$offset") 2>/dev/null) || return 0
    local admins
    admins=$(conf_get TELEGRAM_ADMINS | tr -d ' ')
    [[ $admins =~ ^[0-9]{1,15}(,[0-9]{1,15}){0,19}$ ]] || admins=""
    while IFS=$'\t' read -r offset cmd arg; do
        [[ $offset =~ ^[0-9]+$ ]] || continue
        # Hoechstens 5 Antworten je Lauf; weitere Befehle bleiben fuer den naechsten Lauf (Offset nicht weiter).
        if [[ -n $cmd ]] && (( n >= 5 )); then break; fi
        echo "$offset" >"$STATE_DIR/telegram-offset"
        [[ -n $cmd ]] || continue
        n=$(( n + 1 ))
        case $cmd in
            online)
                total=0
                for nr in $(servers); do
                    pl=$(players_of "$(cfg "$nr" Port)")
                    [[ $pl =~ ^([0-9]+)/ ]] && total=$(( total + BASH_REMATCH[1] ))
                done
                reply="👥 Gerade online: $total Spieler"
                (( total > 0 )) && reply+=$'\n'"$(online_lines)"
                ;;
            server) reply=$(network_lines) ;;
            top) reply=$(telegram_top) ;;
            ansage)
                # Nur Telegram-Konten aus TELEGRAM_ADMINS (der Parser prueft den Absender); Text wie bei beamnet ansage.
                local first="" rest="" sender=${arg%%$'\x1f'*}
                arg=${arg#*$'\x1f'}
                read -r first rest <<<"$arg"
                if [[ $first =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    if [[ -z $rest ]]; then
                        reply="Aufruf: /ansage [HH:MM] <Text>"
                    elif (YES=1 ANSAGE_BY="Telegram $sender" cmd_ansage "$first" "$rest") >/dev/null 2>&1; then
                        reply="📢 Ansage für $first Uhr geplant: ${rest:0:300}"
                    else
                        reply="Ansage fehlgeschlagen – bitte beamnet doctor prüfen."
                    fi
                elif [[ -z $arg ]]; then
                    reply="Aufruf: /ansage [HH:MM] <Text>"
                elif (YES=1 ANSAGE_BY="Telegram $sender" cmd_ansage "$arg") >/dev/null 2>&1; then
                    reply="📢 Ansage an alle Server: ${arg:0:300}"
                else
                    reply="Ansage fehlgeschlagen – bitte beamnet doctor prüfen."
                fi
                ;;
            nichtadmin) reply="Nur für Admins (TELEGRAM_ADMINS in /etc/beamnet.conf)." ;;
            event) reply=$(event_status_text) ;;
            spieler) reply=$(telegram_player "$arg") ;;
            plaetze) reply=$(telegram_slots) ;;
            woche) reply=$(telegram_week) ;;
            heute) reply=$(telegram_today) ;;
            teams) reply=$(telegram_teams) ;;
            saison) reply=$(telegram_season) ;;
            eventset)
                # Nur Telegram-Konten aus TELEGRAM_ADMINS: /event <Faktor> <Dauer> startet, /event stop beendet.
                local esender=${arg%%$'\x1f'*} ef="" ed="" espec
                arg=${arg#*$'\x1f'}
                read -r ef ed _ <<<"$arg"
                if [[ ${ef,,} == stop || ${ef,,} == aus ]]; then
                    if event_write 1 0 "Telegram $esender"; then reply="XP-Event beendet."; else reply="XP-Event konnte nicht beendet werden – bitte beamnet doctor prüfen."; fi
                elif espec=$(autoevent_spec "mo 00:00 $ef $ed"); then
                    read -r _ _ _ ef ed <<<"$espec"
                    if event_write "$ef" "$ed" "Telegram $esender"; then
                        ef=${ef/./,}
                        reply="⚡ XP-Event gestartet: ${ef%,0}-fache XP für $(( ed / 60 )) Minuten auf allen Servern."
                    else
                        reply="XP-Event konnte nicht gestartet werden – bitte beamnet doctor prüfen."
                    fi
                else
                    reply="Aufruf: /event <Faktor 1,5–5> <Dauer 10m–6h> – z. B. /event 2 2h · /event stop"
                fi
                ;;
            rekord)
                reply=$(python3 -I - "$SHARED/peak.json" <<'PY' 2>/dev/null
import json, os, stat, sys, time
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError
        p = json.loads(f.read(1 << 20).decode("utf-8", "replace"))
    best, at, today = int(p.get("allTime", 0)), p.get("allTimeAt", 0), int(p.get("today", 0))
except Exception:
    print("Noch kein Spielerrekord gespeichert."); sys.exit(0)
when = time.strftime("%d.%m.%Y", time.localtime(at)) if isinstance(at, (int, float)) and 0 < at < 4e9 else "?"
print(f"🏆 Rekord: {best} Spieler gleichzeitig ({when}) · heute bisher: {today}")
PY
)
                ;;
            *) reply="BeamNet-Bot: /online · /top · /rekord · /server · /event · /spieler <Name> · /plaetze · /woche · /heute · /teams · /saison${admins:+ · /ansage und /event 2 2h (Admins)}" ;;
        esac
        NOTIFY_CHAT=$chat NOTIFY_TOKEN=$token send_chunks 4000 send_telegram "$reply" || true
    done < <(python3 -I -c "$TG_PARSE_PY" "$chat" "$botname" "$admins" <<<"$raw" 2>/dev/null)
    return 0
}

# Befehle fuer die Vorschlagsliste in Telegram (setMyCommands).
TG_COMMANDS_JSON='{"commands":[{"command":"online","description":"Wer gerade fährt"},{"command":"server","description":"Netzwerk-Übersicht: Server, Spieler, Maps"},{"command":"top","description":"Bestenliste (XP)"},{"command":"heute","description":"Tagesaufgabe, Bonus-Map, XP-Event und Wochenziel"},{"command":"woche","description":"Wochenbeste und Wochenziel"},{"command":"teams","description":"Teams dieser Woche"},{"command":"saison","description":"Saisonwertung des Monats"},{"command":"spieler","description":"Werte eines Spielers: /spieler Name"},{"command":"event","description":"XP-Event, XP-Abend und Bonus-Map"},{"command":"rekord","description":"Spielerrekord"},{"command":"plaetze","description":"Auslastung und Spielerplätze"},{"command":"hilfe","description":"Alle Befehle"}]}'

# Antwort von getUpdates -> "naechster Offset<TAB>Befehl" je Nachricht (Befehl leer, wenn nicht fuer uns).
read -r -d '' TG_PARSE_PY <<'PY'
import json, re, sys, time
chat = sys.argv[1]
bot = (sys.argv[2] if len(sys.argv) > 2 else "").lower()
admins = set(a for a in (sys.argv[3] if len(sys.argv) > 3 else "").split(",") if a.isdigit())
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
if not isinstance(data, dict) or data.get("ok") is not True or not isinstance(data.get("result"), list):
    sys.exit(0)
per_sender = {}
for u in data["result"][:100]:
    if not isinstance(u, dict) or not isinstance(u.get("update_id"), int):
        continue
    nxt, cmd = u["update_id"] + 1, ""
    m = u.get("message") if isinstance(u.get("message"), dict) else {}
    c = m.get("chat") if isinstance(m.get("chat"), dict) else {}
    same = str(c.get("id")) == chat or (chat.startswith("@") and ("@" + str(c.get("username", ""))).lower() == chat.lower())
    text = m.get("text") if isinstance(m.get("text"), str) else ""
    hit = re.match(r"^/([a-z]+)(@[A-Za-z0-9_]+)?(\s|$)", text.strip().lower())
    arg = ""
    if same and hit and not (bot and hit.group(2) and hit.group(2)[1:] != bot):
        word = hit.group(1)
        cmd = {"online": "online", "wer": "online", "top": "top", "bestenliste": "top", "rekord": "rekord",
               "record": "rekord", "server": "server", "servers": "server"}.get(word, "hilfe" if word in ("hilfe", "help", "start") else "")
        # Text nach dem Befehl (Original-Schreibweise), ohne Steuerzeichen und Tabulatoren, hoechstens 300 Zeichen.
        body = " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", text.strip().split(None, 1)[1] if len(text.strip().split(None, 1)) > 1 else "").split())[:300]
        sender = m.get("from") if isinstance(m.get("from"), dict) else {}
        forwarded = any(k in m for k in ("forward_origin", "forward_from", "forward_from_chat", "forward_date", "is_automatic_forward"))
        fresh = isinstance(m.get("date"), int) and abs(time.time() - m["date"]) <= 600
        is_admin = str(sender.get("id")) in admins and not sender.get("is_bot") and not forwarded and fresh
        if word in ("ansage", "announce") or (word in ("event", "xpabend") and body):
            if is_admin:
                cmd = "ansage" if word in ("ansage", "announce") else "eventset"
                # Absender-ID, Trennzeichen 0x1f, dann der Text.
                arg = str(sender.get("id")) + "\x1f" + body
            else:
                cmd = "nichtadmin"
        elif word in ("event", "xpabend"):
            cmd = "event"
        elif word in ("plaetze", "platz", "slots"):
            cmd = "plaetze"
        elif word in ("woche", "week", "kw"):
            cmd = "woche"
        elif word in ("heute", "today"):
            cmd = "heute"
        elif word in ("teams", "team"):
            cmd = "teams"
        elif word in ("saison", "season", "monat"):
            cmd = "saison"
        elif word in ("spieler", "player", "profil", "stats"):
            cmd, arg = "spieler", body[:32]
        # Flutschutz: aelter als 2 Minuten (Rueckstau) nicht mehr beantworten; hoechstens 3 Befehle je Absender und Lauf
        # (der Rest wird uebersprungen, damit die Befehle anderer nicht stundenlang warten).
        sid = sender.get("id") if isinstance(sender.get("id"), int) else None
        if cmd and isinstance(m.get("date"), int) and time.time() - m["date"] > 120:
            cmd, arg = "", ""
        elif cmd and sid is not None:
            per_sender[sid] = per_sender.get(sid, 0) + 1
            if per_sender[sid] > 3:
                cmd, arg = "", ""
    print(f"{nxt}\t{cmd}\t{arg}")
PY


# Top 5 nach XP fuer Telegram (aus dem Bestenlisten-Index, sonst nichts).
telegram_top() {
    python3 -I - "$SHARED/players-index.tsv" "$SHARED/config.json" <<'PY' 2>/dev/null || echo "Noch keine Bestenliste."
import json, os, stat, sys
def read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError
        return f.read(64 << 20).decode("utf-8", "replace")
try:
    cfg = json.loads(read(sys.argv[2]))
except Exception:
    cfg = {}
cfg = cfg if isinstance(cfg, dict) else {}
def n(v, d):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else d
per_km, per_min = n(cfg.get("xpPerKm"), 10), n(cfg.get("xpPerMinute"), 1)
rows = []
for line in read(sys.argv[1]).split("\n")[1:]:
    f = line.split("\t")
    if len(f) not in (13, 14, 15, 17):
        continue
    try:
        km, sec, bonus = float(f[2] or 0), float(f[3] or 0), float(f[4] or 0)
    except ValueError:
        continue
    rows.append((int(km * per_km + sec / 60 * per_min) + int(bonus), km, f[1][:32]))
rows.sort(key=lambda r: (-r[0], r[2]))
if not rows:
    print("Noch keine Bestenliste."); sys.exit(0)
print("🏁 Bestenliste (XP):")
for i, (xp, km, name) in enumerate(rows[:5], 1):
    print(f"{i}. {name} – {xp} XP · {km:.0f} km")
PY
}

# /heute fuer Telegram: Tagesaufgabe (aus dem Lebenszeichen eines Servers), laufendes XP-Event, Bonus-Map, naechster
# XP-Abend (hoechstens eine Woche entfernt) und Wochenziel.
telegram_today() {
    local ch line
    echo "☀️ Heute im BeamNet:"
    ch=$(python3 -I - "$SHARED/servers" <<'PY' 2>/dev/null
import json, os, re, stat, sys, time
try:
    dfd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError:
    sys.exit(0)
best = (0, "")
for name in sorted(os.listdir(dfd))[:500]:
    if not re.fullmatch(r"[0-9]{1,5}\.json", name):
        continue
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                continue
            st = json.loads(f.read(65536).decode("utf-8", "replace"))
    except Exception:
        continue
    up, text = st.get("updated") if isinstance(st, dict) else None, st.get("challenge") if isinstance(st, dict) else None
    # Nur eine Tagesaufgabe in bekannter Form (die Datei darf der Dienst schreiben – kein freier Text in den Chat).
    if isinstance(up, int) and not isinstance(up, bool) and 0 <= time.time() - up <= 90 and isinstance(text, str) and up > best[0] \
            and re.fullmatch(r"(Fahre heute [0-9]{1,3} km( auf (einer Map|der Bonus-Map \(/server\)))?|Erreiche heute [0-9]{1,3} km/h|Sei heute [0-9]{1,3} Minuten unterwegs|Fahre heute auf [0-9] verschiedenen Servern|Beende heute [0-9] Rennen|Erledige heute [0-9] Aufträge \(/auftrag\))", text):
        best = (up, text)
if best[1]:
    print(best[1])
PY
)
    if [[ -n $ch ]]; then echo "✅ Tagesaufgabe: $ch (/aufgabe im Spiel)"; else echo "✅ Tagesaufgabe: im Spiel mit /aufgabe"; fi
    line=$(event_status_text | head -n 1)
    [[ $line == ⚡* ]] && echo "$line"
    line=$(bonusmap_line); [[ -n $line ]] && echo "$line"
    line=$(xpabend_line 7); [[ -n $line ]] && echo "$line"
    line=$(telegram_week | grep '^🎯'); [[ -n $line ]] && echo "$line"
    return 0
}

# /teams fuer Telegram: Teams nach Kilometern dieser Woche (Index + teams.json; Mitglieder zaehlen ab der Woche nach
# dem Beitritt, wie im Spiel).
telegram_teams() {
    python3 -I - "$SHARED/players-index.tsv" "$SHARED/teams.json" <<'PY' 2>/dev/null || echo "Noch keine Teams."
import datetime, json, os, re, stat, sys
def read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError
        return f.read(64 << 20).decode("utf-8", "replace")
def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) and v == v else None
now = datetime.datetime.now(datetime.timezone.utc)
year, wk, wd = now.isocalendar()
week = "%04d-W%02d" % (year, wk)
start = (now - datetime.timedelta(days=wd - 1)).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
km = {}
try:
    lines = read(sys.argv[1]).split("\n")[1:]
except Exception:
    lines = []
for line in lines:
    f = line.split("\t")
    if len(f) in (13, 14, 15, 17) and f[5] == week:
        try:
            v = float(f[6] or 0)
        except ValueError:
            continue
        if 0 < v < 1e6:
            km[f[0]] = v
try:
    teams = json.loads(read(sys.argv[2])).get("teams")
except Exception:
    teams = None
rows = []
for t in (teams.values() if isinstance(teams, dict) else []):
    if not (isinstance(t, dict) and isinstance(t.get("members"), dict) and isinstance(t.get("name"), str)):
        continue
    joined = t.get("joined") if isinstance(t.get("joined"), dict) else {}
    total = 0.0
    for i in list(t["members"])[:200]:
        at = num(joined.get(i))
        at = num(t.get("created")) if at is None else at
        at = 0 if at is None else at
        if at < start:
            total += km.get(str(i), 0)
    name = " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", t["name"]).split())[:24]
    if total > 0 and name:
        rows.append((total, name))
rows.sort(key=lambda r: (-r[0], r[1]))
if not rows:
    print(f"🏅 KW {wk}: diese Woche ist noch kein Team gefahren.")
else:
    print(f"🏅 Teams KW {wk}:")
    for i, (v, n) in enumerate(rows[:5], 1):
        print(f"{i}. {n} – " + f"{v:.1f}".replace(".", ",") + " km")
PY
}

# /saison fuer Telegram: Top 5 der laufenden Saison (Monat, UTC – wie im Plugin) nach Saison-XP aus dem Index, das
# fuehrende Team (Mitglieder zaehlen ab Saisonbeginn, wie im Plugin) und die Sieger der letzten Saison aus dem Archiv.
telegram_season() {
    python3 -I - "$SHARED/players-index.tsv" "$SHARED/teams.json" "$SHARED/seasons" "${1:-}" <<'PY' 2>/dev/null || echo "Noch keine Saisonwertung."
import calendar, datetime, json, os, re, stat, sys, time
def read(path, limit=64 << 20):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError
        return f.read(limit).decode("utf-8", "replace")
def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) and v == v else None
def clean(s, n):
    return " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(s)).split())[:n]
MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]
now = datetime.datetime.fromtimestamp(int(sys.argv[4]) if sys.argv[4:] and sys.argv[4].isdigit() else time.time(),
                                     datetime.timezone.utc)
month = now.strftime("%Y-%m")
start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
left = calendar.monthrange(now.year, now.month)[1] - now.day + 1
xp, names = {}, {}
try:
    lines = read(sys.argv[1]).split("\n")[1:]
except Exception:
    lines = []
for line in lines:
    f = line.split("\t")
    if len(f) in (13, 14, 15, 17) and f[9] == month:
        try:
            v = float(f[10] or 0)
        except ValueError:
            continue
        if 0 < v < 1e9:
            xp[f[0]], names[f[0]] = int(v), clean(f[1], 32)
rows = sorted(((v, names[i]) for i, v in xp.items()), key=lambda r: (-r[0], r[1]))
print(f"🏆 Saison {MONTHS[now.month - 1]} {now.year} (noch {left} Tage):")
if not rows:
    print("Noch keine Punkte in dieser Saison.")
for i, (v, n) in enumerate(rows[:5], 1):
    print(f"{i}. {n} – {v} XP")
try:
    teams = json.loads(read(sys.argv[2])).get("teams")
except Exception:
    teams = None
best = None
for t in (teams.values() if isinstance(teams, dict) else []):
    if not (isinstance(t, dict) and isinstance(t.get("members"), dict) and isinstance(t.get("name"), str)):
        continue
    joined = t.get("joined") if isinstance(t.get("joined"), dict) else {}
    def at(i):
        v = num(joined.get(i))
        v = num(t.get("created")) if v is None else v
        return 0 if v is None else v
    total = sum(xp.get(str(i), 0) for i in list(t["members"])[:200] if at(i) < start.timestamp())
    name = clean(t["name"], 24)
    if total > 0 and name and (best is None or (-total, name) < (-best[0], best[1])):
        best = (total, name)
if best:
    print(f"🏅 Führendes Team: {best[1]} ({best[0]} XP)")
prev = (start - datetime.timedelta(days=1)).strftime("%Y-%m")
try:
    a = json.loads(read(os.path.join(sys.argv[3], prev + ".json"), 1 << 20))
except Exception:
    a = None
top = a.get("top") if isinstance(a, dict) and isinstance(a.get("top"), list) else []
parts = [f"{i}. {clean(e.get('name', '?'), 32)} ({int(num(e.get('xp')) or 0)} XP)"
         for i, e in enumerate(top[:3], 1) if isinstance(e, dict) and 0 <= (num(e.get("xp")) or 0) < 1e9]
if parts:
    team = a.get("team")
    tname = clean(team.get("name"), 24) if isinstance(team, dict) and isinstance(team.get("name"), str) else ""
    print(f"Letzte Saison ({MONTHS[int(prev[5:7]) - 1]} {prev[:4]}): " + " · ".join(parts)
          + (f" · Team: {tname}" if tname else ""))
PY
}

# /woche fuer Telegram: Top 5 der Kalenderwoche (ISO, UTC – wie im Plugin) nach Kilometern aus dem Bestenlisten-Index
# und das Wochenziel fuer alle (community.json).
telegram_week() {
    python3 -I - "$SHARED/players-index.tsv" "$SHARED/community.json" <<'PY' 2>/dev/null || echo "Noch keine Wochenwertung."
import datetime, json, os, stat, sys
def read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError
        return f.read(64 << 20).decode("utf-8", "replace")
def km(v):
    return f"{v:.1f}".replace(".", ",") + " km"
year, wk, _ = datetime.datetime.now(datetime.timezone.utc).isocalendar()
week = "%04d-W%02d" % (year, wk)
rows = []
try:
    lines = read(sys.argv[1]).split("\n")[1:]
except Exception:
    lines = []
for line in lines:
    f = line.split("\t")
    if len(f) not in (13, 14, 15, 17) or f[5] != week:
        continue
    try:
        v = float(f[6] or 0)
    except ValueError:
        continue
    if 0 < v < 1e6:
        rows.append((v, f[1][:32]))
rows.sort(key=lambda r: (-r[0], r[1]))
total = sum(v for v, _ in rows)
if rows:
    print(f"📅 KW {wk}: {len(rows)} Fahrer, zusammen {km(total)}")
    for i, (v, name) in enumerate(rows[:5], 1):
        print(f"{i}. {name} – {km(v)}")
else:
    print(f"📅 KW {wk}: diese Woche ist noch niemand gefahren.")
try:
    cg = json.loads(read(sys.argv[2]))
except Exception:
    cg = None
goal = cg.get("goal") if isinstance(cg, dict) and cg.get("week") == week else None
if isinstance(goal, (int, float)) and not isinstance(goal, bool) and 0 < goal < 1e7:
    pct = min(100, int(total / goal * 100))
    print(f"🎯 Wochenziel für alle: {km(total)} von {km(goal)} ({pct} %)" + (" – geschafft! 🎉" if total >= goal else ""))
PY
}

# /plaetze fuer Telegram: Auslastung der letzten 30 Tage je Server und ob die Automatik mehr Plaetze geben wird.
telegram_slots() {
    local nr mp cur new peak full hours why line out="" any=0 auto
    auto=$(conf_get AUTO_SLOTS)
    while read -r nr mp cur new peak full hours why; do
        [[ $nr =~ ^[0-9]+$ ]] || continue
        any=1
        line="Server $nr · $mp: $cur Plätze, Spitze $peak, $full $( (( full == 1 )) && echo Tag || echo Tage) voll"
        if (( new > cur )); then line+=" → 📈 $new Plätze (${why//_/ })"; fi
        out+="$line"$'\n'
    done < <(slots_plan 2>/dev/null)
    if (( ! any )); then echo "Noch keine Auslastungsdaten (sammelt der Wächter jede Minute)."; return 0; fi
    printf '📊 Spielerplätze – letzte 30 Tage:\n%s' "$out"
    if [[ $auto == 0 ]]; then
        echo "Automatik aus (AUTO_SLOTS=0) – übernehmen mit: beamnet slots apply"
    else
        echo "Die Automatik erhöht die Plätze einmal am Tag ab 6 Uhr, sobald der Server leer ist."
    fi
}

# /spieler <Name> fuer Telegram: Level, Liga, XP, Platz, Kilometer, Fahrzeit, Spitze, Auftraege aus dem
# Bestenlisten-Index (genauer Name zuerst, sonst Teil des Namens; bei mehreren Treffern eine Auswahl).
telegram_player() {
    [[ -n ${1:-} ]] || { echo "Aufruf: /spieler <Name> (Teil des Namens reicht)"; return 0; }
    python3 -I - "$SHARED/players-index.tsv" "$SHARED/config.json" "$1" "$SHARED/teams.json" <<'PY' 2>/dev/null || echo "Noch keine Bestenliste."
import json, math, os, re, stat, sys
def read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError
        return f.read(64 << 20).decode("utf-8", "replace")
try:
    cfg = json.loads(read(sys.argv[2]))
except Exception:
    cfg = {}
cfg = cfg if isinstance(cfg, dict) else {}
def n(v, d):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else d
per_km, per_min, base = n(cfg.get("xpPerKm"), 10), n(cfg.get("xpPerMinute"), 1), n(cfg.get("levelBase"), 25) or 25
base = min(max(base, 1), 10000) if base == base else 25
leagues = cfg.get("leagues")
if not (isinstance(leagues, list) and leagues and all(isinstance(l, dict) and isinstance(l.get("name"), str) for l in leagues)):
    leagues = [{"xp": 0, "name": "Bronze"}, {"xp": 500, "name": "Silber"}, {"xp": 2000, "name": "Gold"},
               {"xp": 6000, "name": "Platin"}, {"xp": 15000, "name": "Diamant"}, {"xp": 40000, "name": "Legende"}]
def f(v):
    try:
        x = float(v or 0)
        return x if math.isfinite(x) else 0.0
    except ValueError:
        return 0.0
import time
WEEK, MONTH = time.strftime("%G-W%V", time.gmtime()), time.strftime("%Y-%m", time.gmtime())
rows = []
for line in read(sys.argv[1]).split("\n")[1:]:
    c = line.split("\t")
    if len(c) not in (13, 14, 15, 17):
        continue
    xp = int(f(c[2]) * per_km + f(c[3]) / 60 * per_min) + int(f(c[4]))
    rows.append({"id": c[0], "name": re.sub(r"[\x00-\x1f\x7f]", "", c[1])[:32], "xp": xp, "km": f(c[2]), "sec": f(c[3]),
                 "top": f(c[13]) if len(c) > 13 else 0, "jobs": int(f(c[14])) if len(c) > 14 else 0,
                 "weekKm": f(c[6]) if c[5] == WEEK and 0 < f(c[6]) < 1e6 else 0,
                 "monthXp": int(f(c[10])) if c[9] == MONTH and 0 < f(c[10]) < 1e9 else 0})
if not rows:
    print("Noch keine Bestenliste."); sys.exit(0)
rows.sort(key=lambda r: (-r["xp"], r["name"].lower()))
q = " ".join(sys.argv[3].split()).lower()
hits = [r for r in rows if r["name"].lower() == q] or [r for r in rows if q in r["name"].lower()]
if not hits:
    print(f"Keinen Spieler „{sys.argv[3][:32]}“ gefunden."); sys.exit(0)
if len(hits) > 1:
    print("Mehrere Treffer: " + ", ".join(r["name"] for r in hits[:8]) + (" …" if len(hits) > 8 else "") + " – bitte genauer.")
    sys.exit(0)
r = hits[0]
lvl = int(math.sqrt(r["xp"] / base)) + 1 if r["xp"] > 0 else 1
league = leagues[0]["name"]
for l in leagues:
    if r["xp"] >= n(l.get("xp"), 0):
        league = l["name"]
rank = rows.index(r) + 1
kmtxt = f"{r['km']:.0f}" if r["km"] >= 100 else f"{r['km']:.1f}".replace(".", ",")
print(f"👤 {r['name']} – Level {lvl} · {league[:20]} · {r['xp']} XP · Platz {rank} von {len(rows)}")
print(f"🚗 {kmtxt} km · {r['sec'] / 3600:.0f} h unterwegs · Spitze {r['top']:.0f} km/h · {r['jobs']} Aufträge".replace(".", ","))
# Diese Woche und laufende Saison (Kalenderwoche und Monat in UTC, wie im Plugin).
now_parts = []
if r["weekKm"] > 0:
    now_parts.append("📅 Diese Woche " + f"{r['weekKm']:.1f}".replace(".", ",") + " km")
if r["monthXp"] > 0:
    # wie im Plugin: mehr XP vorn, bei Gleichstand der Name
    srank = 1 + sum(1 for o in rows if o["monthXp"] > r["monthXp"] or (o["monthXp"] == r["monthXp"] and o["name"] < r["name"]))
    now_parts.append(f"🏆 Saison {r['monthXp']} XP (Platz {srank})")
if now_parts:
    print(" · ".join(now_parts))
# Team (teams.json vom Plugin), falls vorhanden.
try:
    teams = json.loads(read(sys.argv[4])).get("teams")
except Exception:
    teams = None
for t in (teams.values() if isinstance(teams, dict) else []):
    if isinstance(t, dict) and isinstance(t.get("members"), dict) and r["id"] in t["members"] and isinstance(t.get("name"), str):
        wins = t.get("weekWins")
        extra = f" · 🏅 {int(wins)}× Team der Woche" if isinstance(wins, int) and not isinstance(wins, bool) and 0 < wins < 1000 else ""
        print("👥 Team " + " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", t["name"]).split())[:24] + extra)
        break
PY
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

def clean(v, n):
    return " ".join(__import__("re").sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(v)).split())[:n]

rows, new, jobs, by_id = [], 0, 0, {}
for path in glob.glob(folder + "/*.json"):
    r = load(path)
    if not r:
        continue
    j = number(r.get("weekJobs") if r.get("week") == week else r.get("lastWeekJobs") if r.get("lastWeek") == week else None)
    if j and 0 < j < 100000:
        jobs += int(j)
    km = r.get("weekKm") if r.get("week") == week else r.get("lastWeekKm") if r.get("lastWeek") == week else None
    km = number(km)
    if km and km > 0 and km < 1e6:
        rows.append((km, clean(r.get("name", "?"), 40) or "?"))    # keine Zeilenumbrueche/Steuerzeichen aus Namen
        by_id[str(r.get("id"))] = km
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
    if jobs > 0:
        parts.append(f"{jobs} {'Aufträge' if jobs != 1 else 'Auftrag'}")
    print("📈 Die Woche: " + " · ".join(parts))
    # Team der Woche: die Momentaufnahme des Plugins (teamweek-<Woche>.json; dieselbe wie Ansage und Belohnung im
    # Spiel), sonst die meisten Kilometer der Mitglieder (teams.json).
    snap = load(os.path.join(os.path.dirname(folder), f"teamweek-{week}.json")) or {}
    teams = (load(os.path.join(os.path.dirname(folder), "teams.json")) or {}).get("teams")
    best = None
    if snap.get("week") == week:
        teams = None
        sk, sm = number(snap.get("km")), snap.get("members")
        if isinstance(snap.get("name"), str) and clean(snap["name"], 32) and sk and 0 < sk < 1e7 and isinstance(sm, dict):
            best = (sk, clean(snap["name"], 32), len(sm))
    for t in (teams.values() if isinstance(teams, dict) and best is None else []):
        if not (isinstance(t, dict) and isinstance(t.get("members"), dict)):
            continue
        ids = [str(i) for i in list(t["members"])[:200]]
        km = sum(by_id.get(i, 0) for i in ids)
        drivers = sum(1 for i in ids if by_id.get(i, 0) > 0)
        name = clean(t.get("name", "?"), 32)
        if km > 0 and name and (best is None or km > best[0] or (km == best[0] and name < best[1])):
            best = (km, name, drivers)
    if best:
        print(f"🏅 Team der Woche: {best[1]} ({best[0]:.0f} km, {best[2]} Fahrer)")
PY
)
    [[ -n ${lines[0]:-} ]] && out+=("🏁 Wochensieger ${week/-W/ KW }: ${lines[0]}")
    [[ -n ${lines[1]:-} ]] && out+=("${lines[1]}")
    [[ -n ${lines[2]:-} ]] && out+=("${lines[2]}")
    return 0
}

# Letzter Tag der Saison, ab 12 Uhr UTC einmal: Zwischenstand als Endspurt-Aufruf (Top 3 und fuehrendes Team, wie
# /saison im Telegram-Chat). Ein Zeitpunkt fuer alles (kein Monatswechsel mitten im Lauf).
watch_season_final() {
    local -n fout=$1
    local now month hour top="" lead="" l
    now=$(date -u +%s)
    [[ ${BEAMNET_LASTDAY:-$([[ $(date -u -d "@$(( now + 86400 ))" +%d) == 01 ]] && echo 1)} == 1 ]] || return 0
    hour=${BEAMNET_HOUR:-$(date -u -d "@$now" +%H)}
    (( 10#$hour >= 12 )) || return 0
    [[ -d $SHARED/players && ! -L $SHARED/players ]] && notify_configured || return 0
    command -v python3 >/dev/null || return 0
    month=$(date -u -d "@$now" +%Y-%m)
    [[ -f $STATE_DIR/season-final-$month ]] && return 0
    while IFS= read -r l; do
        if [[ $l =~ ^([1-3])\.\ (.*)\ –\ ([0-9]+)\ XP$ ]]; then
            top+="${top:+ · }${BASH_REMATCH[1]}. ${BASH_REMATCH[2]} (${BASH_REMATCH[3]} XP)"
        elif [[ $l == "🏅 Führendes Team: "* ]]; then
            lead=$l
        fi
    done < <(telegram_season "$now")
    : >"$STATE_DIR/season-final-$month"
    [[ -n $top ]] || return 0
    fout+=("⏳ Letzter Tag der Saison $month – Endspurt! $top")
    [[ -n $lead ]] && fout+=("$lead")
    return 0
}

# Am 1. eines Monats einmal die Saisonsieger des Vormonats nach Discord (aus dem Archiv des Plugins oder den
# Spielerdaten, falls das Archiv noch fehlt).
watch_season() {
    local -n sout=$1
    local month dom
    dom=${BEAMNET_DOM:-$(date -u +%d)}
    [[ $dom == 01 && -d $SHARED/players ]] && notify_configured || return 0
    command -v python3 >/dev/null || return 0
    month=$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m)
    [[ -f $STATE_DIR/season-$month ]] && return 0
    local lines=() l
    while IFS= read -r l; do lines+=("$l"); done < <(python3 -I - "$month" "$SHARED" <<'PY'
import glob, json, os, re, sys
month, shared = sys.argv[1], sys.argv[2]
def clean(v, n):
    return " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(v)).split())[:n] or "?"
def read_nofollow(path, limit=16 * 1024 * 1024):
    """Inhalt einer regulaeren Datei, ohne einem Symlink zu folgen (Ordner gehoeren beammp)."""
    import os as _os, stat as _stat
    fd = _os.open(path, _os.O_RDONLY | _os.O_NOFOLLOW | _os.O_NONBLOCK)
    with _os.fdopen(fd, "rb") as fh:
        if not _stat.S_ISREG(_os.fstat(fh.fileno()).st_mode):
            raise OSError("keine regulaere Datei: " + path)
        return fh.read(limit).decode("utf-8", "replace")
rows, team = [], None
try:
    archive = json.loads(read_nofollow(os.path.join(shared, "seasons", month + ".json")))
    rows = [(float(e.get("xp", 0)), clean(e.get("name", "?"), 40)) for e in archive.get("top", []) if isinstance(e, dict)]
    t = archive.get("team")
    if isinstance(t, dict) and isinstance(t.get("name"), str) and isinstance(t.get("xp"), (int, float)) and 0 < t["xp"] < 1e9:
        team = (clean(t["name"], 32), int(t["xp"]))
except Exception:
    for path in glob.glob(os.path.join(shared, "players", "*.json")):
        try:
            r = json.loads(read_nofollow(path))
        except Exception:
            continue
        xp = r.get("monthXp") if r.get("month") == month else r.get("lastMonthXp") if r.get("lastMonth") == month else None
        if isinstance(xp, (int, float)) and xp > 0:
            rows.append((xp, clean(r.get("name", "?"), 40)))
rows.sort(key=lambda x: (-x[0], x[1]))
print(" · ".join(f"{i + 1}. {n} ({int(x)} XP)" for i, (x, n) in enumerate(rows[:3])))
if team and rows:
    print(f"🏅 Team der Saison: {team[0]} ({team[1]} XP)")
PY
)
    : >"$STATE_DIR/season-$month"
    [[ -n ${lines[0]:-} ]] && sout+=("🏆 Saisonsieger $month: ${lines[0]}")
    [[ -n ${lines[1]:-} ]] && sout+=("${lines[1]}")
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
import glob, json, os, re, stat, sys
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

rows, jobs, new = [], 0, 0
for path in glob.glob(os.path.join(shared, "players", "*.json")):
    r = load(path)
    first = r.get("firstSeen") if r else None
    if isinstance(first, (int, float)) and not isinstance(first, bool) and 0 < first < 1e11 and int(first // 86400) == day:
        new += 1
    km = r.get("dayKm") if r and r.get("day") == day else None
    if isinstance(km, (int, float)) and not isinstance(km, bool) and km > 0:
        rows.append((float(km), " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(r.get("name", "?"))).split())[:32] or "?"))
    j = r.get("dayJobs") if r and r.get("day") == day else None
    if isinstance(j, int) and not isinstance(j, bool) and 0 < j < 10000:
        jobs += j
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
if jobs:
    parts.append("1 Auftrag erledigt" if jobs == 1 else f"{jobs} Aufträge erledigt")
if new:
    parts.append("1 neuer Spieler 👋" if new == 1 else f"{new} neue Spieler 👋")
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
        line=$(xpabend_line 3)
        [[ -n $line ]] && dout+=("   $line")
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
# Der Bot beantwortet im eingetragenen Chat /online, /top, /rekord und /server (innerhalb einer Minute). 0 = aus.
TELEGRAM_COMMANDS=1
# Telegram-Konten (Zahlen-IDs, mit Komma), die im Chat /ansage [HH:MM] <Text> an alle Server schicken duerfen.
TELEGRAM_ADMINS=
# Netzwerk-Uebersicht alle N Minuten an Discord/Telegram, solange jemand spielt: Spieler je Server (Konten mit Namen,
# Gaeste gezaehlt), leere Server und Auslastung je Map. 0 = aus.
NETWORK_REPORT=10
# Automatischer XP-Abend (netzweites XP-Event nach Plan, eine Stunde vorher angekuendigt), z. B. "fr,sa 20:00 2 2h"
# (Tage mo..so oder taeglich, Uhrzeit, Faktor 1,5-5, Dauer 10m-6h). Leer = aus. Einfacher: beamnet event auto ...
AUTO_EVENT=
# Bonus-Map des Tages: die am wenigsten gefahrene Map (7 Tage) bekommt beim Fahren BONUS_MAP_FACTOR-fache XP. 0 = aus.
BONUS_MAP=1
BONUS_MAP_FACTOR=1.5
# Einmal am Tag melden, wenn es ein neueres BeamNet gibt (installiert nichts selbst). 0 = aus.
UPDATE_CHECK=1
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
# Erfolge von Spielern melden: neue Spieler, Liga-Aufstiege und Meilensteine (Level 25/50/75/100, 1000/5000/10000/25000 km). 0 = aus.
MILESTONE_NOTIFY=1
# Taegliche Datensicherung der Spielerdaten nach /root/beamnet-backups/daten-<Datum>.tgz: ab BACKUP_HOUR Uhr,
# BACKUP_KEEP Tage aufbewahren (zurueckholen: beamnet restore). DATA_BACKUP=0 schaltet ab.
DATA_BACKUP=1
BACKUP_HOUR=4
BACKUP_KEEP=14
# Last-Warnung: CPU ueber CPU_WARN % (eines Kerns) fuer LOAD_MINUTES Minuten, RAM ueber MEM_WARN_MB. "-" = aus.
CPU_WARN=90
MEM_WARN_MB=1500
# Netzwerk fast voll: Meldung ab diesem Anteil belegter Plaetze (Prozent), mit freien Servern. - = aus.
CAPACITY_WARN=90
LOAD_MINUTES=5
# Mehr Spielerplaetze fuer beliebte Server (beamnet slots): einmal am Tag ab SLOTS_HOUR, nur wenn der Server leer ist.
# +SLOTS_STEP bei SLOTS_FULL_DAYS vollen Tagen in 30 Tagen, nochmals +SLOTS_STEP fuer eine Top-3-Map; hoechstens
# SLOTS_MAX. AUTO_SLOTS=0 = nur Vorschlag anzeigen.
AUTO_SLOTS=1
SLOTS_MAX=20
SLOTS_STEP=4
SLOTS_FULL_DAYS=2
SLOTS_HOUR=6
# Haengt ein Server (Dienst laeuft, aber seit HANG_MIN Minuten kein Lebenszeichen von BeamNetCore)? Antwortet er auch
# auf seinem Port nicht mehr, startet ihn der Waechter mit AUTO_RESTART=1 neu; sonst nur Meldung. 0 = aus.
HANG_MIN=3
# Neue Streckenrekorde sofort an Discord/Telegram melden: 1 = an, 0 = aus.
RECORD_NOTIFY=1
# Wiederholungstaeter: wer in 7 Tagen so oft gemeldet, stummgeschaltet, verwarnt oder gekickt wurde, wird gemeldet. 0 = aus.
REPEAT_WARN=3
EOF
        chmod 600 "$CONF"
    fi
    cat >"$SYSTEMD_DIR/beamnet-watch.service" <<EOF
[Unit]
Description=BeamNet-Waechter (prueft die BeamMP-Server)

[Service]
Type=oneshot
ExecStart=$self watch
TimeoutStartSec=300
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
            if (( $(online_report_min) > 0 )) && notify_configured; then echo "Netzwerk-Übersicht: alle $(online_report_min) Minuten"
            else echo "Netzwerk-Übersicht: aus"; fi
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
        return fh.read(limit).decode("utf-8", "replace")
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

# beamnet config: Spiel-Einstellungen in config.json ansehen und aendern (nur bekannte Schluessel, geprueft auf Typ und
# Grenzen; das Plugin uebernimmt sie innerhalb einer Minute). "standard" setzt den Standardwert.
read -r -d '' CONFIG_PY <<'PY'
import json, math, os, re, stat, sys
path, out, args = sys.argv[1], sys.argv[2], sys.argv[3:]
# Schluessel: (Typ, Minimum, Maximum, Standard, Beschreibung). Standardwerte wie im Plugin (ein Test vergleicht).
KEYS = {
    "xpPerKm": ("num", 0, 1000, 10, "XP je Kilometer"),
    "xpPerMinute": ("num", 0, 100, 1, "XP je Minute Fahrzeit"),
    "announceLevelUps": ("bool", 0, 0, True, "Level-Aufstiege allen ansagen"),
    "welcomeNew": ("bool", 0, 0, True, "Neue Spieler begrüßen und vorstellen"),
    "achievements": ("bool", 0, 0, True, "Erfolge an/aus"),
    "mapVote": ("bool", 0, 0, True, "Map-Abstimmung im Chat"),
    "publicHost": ("str", 0, 64, "", "Adresse für /server (z. B. meinserver.de)"),
    "challengeXp": ("int", 0, 1000, 40, "XP für die Tagesaufgabe"),
    "challengeTypes": ("list", 0, 0, ["km", "speed", "time", "servers"], "Tagesaufgaben (km speed time servers races mapkm jobs bonus)"),
    "weeklyTrackXp": ("int", 0, 1000, 50, "XP für die Strecke der Woche"),
    "maxFriends": ("int", 1, 100, 20, "Freunde je Spieler"),
    "streakXp": ("int", 0, 1000, 10, "Bonus-XP je Tag der Tages-Serie (0 = aus)"),
    "streakMaxDays": ("int", 2, 30, 7, "Höchstens so viele Serientage zählen"),
    "streakMinKm": ("num", 0.1, 100, 1, "Kilometer am Tag für die Serie"),
    "jobXp": ("int", 0, 1000, 20, "Fester Anteil je Auftrag ab 1 km"),
    "jobXpPerKm": ("num", 0, 1000, 25, "Auftrags-XP je km Luftlinie"),
    "jobCooldownSec": ("int", 0, 3600, 45, "Pause zwischen zwei Aufträgen (s)"),
    "jobXpPerHour": ("int", 0, 100000, 600, "Höchstens so viele Auftrags-XP je Stunde"),
    "communityKm": ("int", 0, 1000000, 0, "Wochenziel in km (0 = automatisch)"),
    "communityXp": ("int", 0, 10000, 100, "XP fürs geschaffte Wochenziel"),
    "teamWeekXp": ("int", 0, 10000, 50, "XP für Mitglieder des Teams der Woche, die mitgefahren sind"),
    "chaseXpPerDay": ("int", 0, 100000, 300, "Höchstens so viele Jagd-XP je Tag"),
    "tipEverySec": ("int", 0, 86400, 900, "Tipps im Chat alle N s (0 = aus)"),
    "tutorialXp": ("int", 0, 1000, 25, "XP je Schritt im Einsteiger-Pfad (0 = aus)"),
    "tutorialDoneXp": ("int", 0, 10000, 50, "Extra-XP für den ganzen Einsteiger-Pfad"),
    "seriesXp": ("int", 0, 1000, 40, "XP für eine Rennserie"),
    "alertEverySec": ("int", 0, 86400, 1800, "Einsatz-Alarm etwa alle N s (0 = aus)"),
    "alertXp": ("int", 0, 1000, 50, "XP für den Einsatz-Alarm"),
    "alertMinPlayers": ("int", 1, 64, 2, "Einsatz-Alarm ab so vielen Spielern"),
    "convoyKm": ("num", 0.5, 100, 3, "Konvoi: Bonus je so viele km zusammen"),
    "convoyXp": ("int", 0, 1000, 20, "Konvoi-XP je Abschnitt (0 = aus)"),
    "convoyXpPerHour": ("int", 0, 10000, 80, "Höchstens so viele Konvoi-XP je Stunde"),
    "convoyRadiusM": ("int", 20, 1000, 150, "Konvoi: höchstens so weit auseinander (m)"),
    "crowdHintSec": ("int", 0, 86400, 900, "„Wo ist was los?“ alle N s (0 = aus)"),
    "crowdMinPlayers": ("int", 1, 64, 3, "„Wo ist was los?“: anderer Server ab so vielen Spielern"),
    "crowdMaxHere": ("int", 0, 64, 2, "„Wo ist was los?“: nur bis so viele Spieler hier"),
    "comebackDays": ("int", 1, 365, 14, "Rückkehrer-Bonus nach so vielen Tagen Pause"),
    "comebackXp": ("int", 0, 10000, 50, "Rückkehrer-Bonus (0 = aus)"),
    "roadPointsMax": ("int", 0, 2000, 300, "Lieferpunkte je Map (0 = aus)"),
}
ALIASES = {"aufgaben": "challengeTypes", "tagesaufgaben": "challengeTypes"}
CHALLENGES = ["km", "speed", "time", "servers", "races", "mapkm", "jobs", "bonus"]
def read_nofollow(p, limit=16 * 1024 * 1024):
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as fh:
        if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
            raise OSError
        return fh.read(limit).decode("utf-8", "replace")
try:
    cfg = json.loads(read_nofollow(path))
    if not isinstance(cfg, dict):
        raise ValueError
except FileNotFoundError:
    cfg = {}
except Exception:
    print("config.json ist fehlerhaft – bitte zuerst reparieren oder löschen."); sys.exit(1)
def show(v):
    if isinstance(v, bool):
        return "an" if v else "aus"
    if isinstance(v, list):
        return " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", "", str(x))[:40] for x in v[:20])
    if isinstance(v, float) and not math.isfinite(v):
        return "(ungültig)"
    if isinstance(v, float) and v == int(v):
        v = int(v)
    # config.json gehoert dem Dienst: Steuerzeichen (Terminal-Escape-Folgen) nie ins Terminal von root.
    return str(v).replace(".", ",") if isinstance(v, float) else (re.sub(r"[\x00-\x1f\x7f-\x9f]", "", str(v))[:200] if v != "" else "–")
if not args:
    for k, (t, lo, hi, d, desc) in KEYS.items():
        cur = cfg.get(k, d)
        mark = "" if k not in cfg else "  (geändert)"
        print(f"{k:<18} {show(cur):<28} {desc}{mark}")
    print("Ändern: beamnet config <Schlüssel> <Wert> · zurück: beamnet config <Schlüssel> standard · "
          "Tagesaufgaben: beamnet config aufgaben km speed jobs mapkm")
    sys.exit(2)
key = ALIASES.get(args[0].lower(), args[0])
match = [k for k in KEYS if k.lower() == key.lower()]
if not match:
    print(f"Unbekannter Schlüssel „{args[0][:40]}“ – Liste: beamnet config"); sys.exit(1)
key = match[0]
t, lo, hi, d, desc = KEYS[key]
vals = args[1:]
if not vals:
    print(f"{key} = {show(cfg.get(key, d))} ({desc})"); sys.exit(2)
if len(vals) == 1 and vals[0].lower() in ("standard", "default"):
    v = d
elif t == "list":
    v = []
    for w in vals:
        w = w.lower().strip(",")
        if w not in CHALLENGES:
            print(f"Unbekannte Tagesaufgabe „{w[:20]}“ – möglich: {' '.join(CHALLENGES)}"); sys.exit(1)
        if w not in v:
            v.append(w)
elif len(vals) != 1:
    print(f"Aufruf: beamnet config {key} <Wert>"); sys.exit(1)
elif t == "bool":
    w = vals[0].lower()
    if w not in ("an", "aus", "ja", "nein", "on", "off", "true", "false", "1", "0"):
        print(f"{key}: an oder aus"); sys.exit(1)
    v = w in ("an", "ja", "on", "true", "1")
elif t == "str":
    v = vals[0].strip()
    if v in ("-", "leer"):
        v = ""
    if len(v) > hi or not re.fullmatch(r"[A-Za-z0-9.:-]*", v):
        print(f"{key}: nur Buchstaben, Ziffern, Punkt, Doppelpunkt und Bindestrich (höchstens {hi})"); sys.exit(1)
else:
    w = vals[0].replace(",", ".")
    if not re.fullmatch(r"[0-9]{1,7}(\.[0-9]{1,3})?", w) or (t == "int" and "." in w):
        print(f"{key}: {'ganze ' if t == 'int' else ''}Zahl von {show(lo)} bis {show(hi)}"); sys.exit(1)
    v = int(w) if t == "int" else float(w)
    if not lo <= v <= hi:
        print(f"{key}: {show(lo)} bis {show(hi)}"); sys.exit(1)
    if t == "num" and v == int(v):
        v = int(v)
cfg[key] = v
with open(out, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
print(f"{key} = {show(v)} – wirksam innerhalb einer Minute auf allen Servern.")
PY

cmd_config() {
    command -v python3 >/dev/null || die "python3 fehlt (apt install python3)."
    local out rc=0
    out=$(mktemp)
    if [[ $# -ge 2 ]]; then need_root config; ensure_shared; fi
    python3 -I -c "$CONFIG_PY" "$SHARED/config.json" "$out" "$@" || rc=$?
    if (( rc == 0 )) && [[ -s $out ]]; then
        safe put "$SHARED/config.json" 664 "$SERVICE_USER" <"$out" || { rm -f "$out"; die "config.json konnte nicht geschrieben werden."; }
    fi
    rm -f "$out"
    (( rc == 0 || rc == 2 )) || exit 1
    return 0
}

# Setzt KEY=Wert in /etc/beamnet.conf (legt die Datei bei Bedarf an).
conf_set() {
    local key=$1 value=$2 tmp
    if [[ ! -f $CONF ]]; then : >"$CONF"; chmod 600 "$CONF"; fi
    tmp=$(mktemp)
    # Wert ueber die Umgebung statt -v: die Befehlszeile (mit Token/Webhook) kann jeder Benutzer mit ps lesen.
    BEAMNET_CONF_VALUE=$value awk -v k="$key" '
        $0 ~ "^[[:space:]]*" k "=" { if (!done) print k "=" ENVIRON["BEAMNET_CONF_VALUE"]; done = 1; next }
        { print }
        END { if (!done) print k "=" ENVIRON["BEAMNET_CONF_VALUE"] }' "$CONF" >"$tmp" && cat "$tmp" >"$CONF"
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
                    local tgadm
                    tgadm=$(ask "Deine Telegram-Zahlen-ID für /ansage und /event im Chat (z. B. über @userinfobot; Enter = keine):" "")
                    tgadm=${tgadm// /}
                    if [[ $tgadm =~ ^[0-9]{1,15}(,[0-9]{1,15}){0,19}$ ]]; then
                        conf_set TELEGRAM_ADMINS "$tgadm"
                        ok "Telegram-Admins: $tgadm"
                    elif [[ -n $tgadm ]]; then
                        warn "Das ist keine Telegram-Zahlen-ID – nicht gespeichert."
                    fi
                else
                    warn "Das ist keine Chat-ID – Telegram nicht gespeichert."
                fi
            else
                warn "Das ist kein Bot-Token (123456:ABC…) – Telegram nicht gespeichert."
            fi
        fi
        if confirm "Ausgefallene Server automatisch neu starten (höchstens 3x pro Stunde)?"; then conf_set AUTO_RESTART 1; fi
        if confirm "XP-Abende einschalten (freitags und samstags 20–22 Uhr doppelte XP, eine Stunde vorher angekündigt)?"; then
            conf_set AUTO_EVENT "fr,sa 20:00 2 2h"
            autoevent_publish
            ok "XP-Abende: fr,sa 20:00 2 2h (ändern: beamnet event auto <Tage> <HH:MM> <Faktor> <Dauer>)"
        fi
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
        return fh.read(limit).decode("utf-8", "replace")
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
        return fh.read(limit).decode("utf-8", "replace")
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
    # Bonus-Map und XP-Abend nur nach den eigenen Angaben des Waechters (die Dateien im gemeinsamen Ordner darf der
    # Dienst aendern).
    BEAMNET_BONUS_OWN=$(tail -n 1 "$STATE_DIR/bonusmap-$(date +%F)" 2>/dev/null) BEAMNET_XPABEND="$STATE_DIR/xpabend.json" \
    python3 -I - "$SHARED" "$WEB_DIR/index.html" "${1:-BeamNet}" <<'PY'
import glob, html, json, math, os, re, sys, time

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
        return fh.read(limit).decode("utf-8", "replace")


def load(path):
    try:
        return json.loads(read_nofollow(path))
    except Exception:
        return None


def num(v, default=0.0):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return default
    try:
        return v if math.isfinite(v) and abs(v) < 1e15 else default
    except OverflowError:
        return default


cfg = load(os.path.join(shared, "config.json"))
cfg = cfg if isinstance(cfg, dict) else {}
xp_km, xp_min, base = num(cfg.get("xpPerKm"), 10), num(cfg.get("xpPerMinute"), 1), num(cfg.get("levelBase"), 25) or 25
base = min(max(base, 1), 10000)
leagues = cfg.get("leagues")
if not (isinstance(leagues, list) and leagues and all(isinstance(l, dict) and isinstance(l.get("name"), str) for l in leagues)):
    leagues = [{"xp": 0, "name": "Bronze"}, {"xp": 500, "name": "Silber"}, {"xp": 2000, "name": "Gold"},
               {"xp": 6000, "name": "Platin"}, {"xp": 15000, "name": "Diamant"}, {"xp": 40000, "name": "Legende"}]


def xp_of(r):
    if num(r.get("xp"), None) is not None:
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

# Saison-Titel (Platz 1-3 der archivierten Saisons) je Spieler-ID, neueste zuerst.
TITLES = {}
season_team = ""          # Team der letzten archivierten Saison (fuer den Saison-Abschnitt)
for path in sorted(glob.glob(os.path.join(shared, "seasons", "*.json")), reverse=True):
    a = load(path)
    m = a.get("month") if isinstance(a, dict) else None
    if not (isinstance(m, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}", m) and 1 <= int(m[5:7]) <= 12):
        continue
    t = a.get("team")
    if not season_team and m < month and isinstance(t, dict) and isinstance(t.get("name"), str) and 0 < num(t.get("xp")) < 1e9:
        season_team = (f'<p>🏅 Team der Saison {MONTHS[int(m[5:7]) - 1]} {m[:4]}: <b>{E(t["name"][:32])}</b> '
                       f'({int(num(t.get("xp")))} XP)</p>')
    for place, e in enumerate((a.get("top") if isinstance(a.get("top"), list) else [])[:3], 1):
        if isinstance(e, dict) and e.get("id") is not None:
            TITLES.setdefault(str(e["id"]), []).append((m, place))
PLACE_TEXT = {1: "🥇 Saisonsieger", 2: "🥈 Saison-Zweiter", 3: "🥉 Saison-Dritter"}


def weeks_chart(r):
    """Kilometer der letzten Wochen (Verlauf des Plugins plus laufende Woche) als kleines SVG-Balkendiagramm."""
    rows = []
    for e in (r.get("weeks") if isinstance(r.get("weeks"), list) else [])[-12:]:
        if isinstance(e, dict) and isinstance(e.get("week"), str) and re.fullmatch(r"[0-9]{4}-W[0-9]{2}", e["week"]):
            rows.append((e["week"], max(0.0, num(e.get("km")))))
    # Laufende Woche – oder die zuletzt gefahrene, wenn der Spieler seitdem nicht da war (dann ist r["week"] alt).
    rw = r.get("week")
    if isinstance(rw, str) and re.fullmatch(r"[0-9]{4}-W[0-9]{2}", rw) and num(r.get("weekKm")) > 0 \
            and all(wk != rw for wk, _ in rows):
        rows.append((rw, num(r.get("weekKm"))))
    rows = sorted(rows)[-12:]
    if len(rows) < 2 or max(v for _, v in rows) <= 0:
        return ""
    top = max(v for _, v in rows)
    w, h, bw = 40 * len(rows), 110, 28
    bars = []
    for i, (wk, v) in enumerate(rows):
        bh = max(1, round(v / top * (h - 24))) if v > 0 else 0
        x = i * 40 + 6
        bars.append(f'<rect x="{x}" y="{h - 16 - bh}" width="{bw}" height="{bh}"><title>KW {int(wk[6:])}: {km(v)}</title></rect>'
                    f'<text x="{x + bw / 2}" y="{h - 3}" text-anchor="middle">{int(wk[6:])}</text>')
    return (f'<section><h2>Kilometer je Woche</h2><svg class=chart viewBox="0 0 {w} {h}" role="img" aria-label="Kilometer je Woche">'
            f'{"".join(bars)}</svg><p class=small>Kalenderwochen{", die letzte ist die laufende Woche" if rows[-1][0] == week else ""}.</p></section>')
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

# Demnaechst: geplante Ansagen (announcements.json) und ein laufendes XP-Event (event.json), beides vom Plugin.
upcoming = []
ann = load(os.path.join(shared, "announcements.json"))
for a in (ann.get("list") if isinstance(ann, dict) and isinstance(ann.get("list"), list) else [])[:50]:
    at = num(a.get("at")) if isinstance(a, dict) else 0
    if now < at < now + 14 * 86400:
        txt = " ".join(__import__("re").sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(a.get("text", ""))).split())[:300]
        upcoming.append((at, f"📢 {E(txt)}"))
ev = load(os.path.join(shared, "event.json"))
if isinstance(ev, dict) and now < num(ev.get("until")) < now + 2 * 86400 and 1 < num(ev.get("factor")) <= 5:
    f = num(ev.get("factor"))
    fs = (f"{f:.1f}".replace(".", ",") if f != int(f) else str(int(f)))
    upcoming.append((now, f"🎉 XP-Event läuft: {fs}-fache XP bis {time.strftime('%H:%M', time.localtime(num(ev.get('until'))))} Uhr"))
xa = load(os.environ.get("BEAMNET_XPABEND") or os.path.join(shared, "xpabend.json"))
if isinstance(xa, dict) and now < num(xa.get("next")) < now + 8 * 86400 and 1.5 <= num(xa.get("factor")) <= 5 and 0 < num(xa.get("sec")) <= 6 * 3600:
    f, at = num(xa.get("factor")), num(xa.get("next"))
    fs = (f"{f:.1f}".replace(".", ",") if f != int(f) else str(int(f)))
    upcoming.append((at, f"🎉 XP-Abend: {fs}-fache XP auf allen Servern bis {time.strftime('%H:%M', time.localtime(at + num(xa.get('sec'))))} Uhr"))
bm = load(os.path.join(shared, "bonusmap.json"))
if not (isinstance(bm, dict) and bm.get("map") == os.environ.get("BEAMNET_BONUS_OWN")):
    bm = None
if (isinstance(bm, dict) and isinstance(bm.get("map"), str) and __import__("re").fullmatch(r"[A-Za-z0-9_.-]+", bm["map"])
        and 1 < num(bm.get("factor")) <= 3 and now < num(bm.get("until")) < now + 2 * 86400):
    upcoming.append((now, f"🗺️ Bonus-Map heute: {E(bm['map'])} – +{int((num(bm.get('factor')) - 1) * 100 + 0.5)} % XP beim Fahren bis Mitternacht"))
    bonus_map = bm["map"]
else:
    bonus_map = None
# Tagesaufgabe aus dem frischesten Lebenszeichen (BeamNetCore ab 1.80).
challenge = max(((num(s.get("updated")), s.get("challenge")) for s in servers if isinstance(s.get("challenge"), str)),
                default=(0, ""))[1]
# Nur in bekannter Form (die Dateien darf der Dienst schreiben).
if not __import__("re").fullmatch(r"(Fahre heute [0-9]{1,3} km( auf (einer Map|der Bonus-Map \(/server\)))?|Erreiche heute [0-9]{1,3} km/h|Sei heute [0-9]{1,3} Minuten unterwegs|Fahre heute auf [0-9] verschiedenen Servern|Beende heute [0-9] Rennen|Erledige heute [0-9] Aufträge \(/auftrag\))", challenge):
    challenge = ""
if challenge:
    upcoming.append((now, f"✅ Tagesaufgabe: {E(challenge)} (im Spiel: /aufgabe, alles für heute: /heute)"))
upcoming.sort(key=lambda x: x[0])
DAYS = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
upcoming_rows = [f"<tr><td>{'jetzt' if at <= now else DAYS[time.localtime(at).tm_wday] + ' ' + time.strftime('%d.%m. %H:%M', time.localtime(at))}</td><td>{t}</td></tr>"
                 for at, t in upcoming[:8]]

# Orte fuer Fahrauftraege (places/<Map>.json, vom Plugin): je Map die Anzahl je Typ.
PLACE_ICONS = {"krankenhaus": "🚑", "schule": "🚌", "feuerwehr": "🚒", "polizei": "🚓", "tankstelle": "⛽",
               "werkstatt": "🔧", "supermarkt": "🛒", "bahnhof": "🚕", "flughafen": "✈️", "hafen": "⚓", "hotel": "🏨",
               "ort": "📦"}
place_rows = []
pl_dir = os.path.join(shared, "places")
if os.path.isdir(pl_dir) and not os.path.islink(pl_dir):
    for path in sorted(glob.glob(os.path.join(pl_dir, "*.json"))):
        data = load(path)
        places = data.get("places") if isinstance(data, dict) else None
        if not isinstance(places, list):
            continue
        counts = {}
        for p in places[:100]:
            if isinstance(p, dict) and isinstance(p.get("type"), str) and p["type"] in PLACE_ICONS:
                counts[p["type"]] = counts.get(p["type"], 0) + 1
        if counts:
            kinds = " ".join(f"{PLACE_ICONS[k]} {n}" for k, n in sorted(counts.items(), key=lambda x: (-x[1], x[0])))
            place_rows.append(f"<tr><td>{E(map_name(os.path.basename(path)[:-5]))}</td><td>{kinds}</td>"
                              f"<td class=n>{sum(counts.values())}</td></tr>")

# Rennserien (races/<Map>.json, "series"): Map, Name, Strecken, Bestzeit.
series_rows = []
for path in sorted(glob.glob(os.path.join(shared, "races", "*.json"))):
    data = load(path)
    ser = data.get("series") if isinstance(data, dict) else None
    if not isinstance(ser, dict):
        continue
    for sn, sd in sorted(ser.items())[:20]:
        if not isinstance(sd, dict) or not isinstance(sd.get("tracks"), list):
            continue
        tracks = " → ".join(E(str(t)) for t in sd["tracks"][:5])
        recs = sd.get("records") if isinstance(sd.get("records"), list) else []
        b = recs[0] if recs and isinstance(recs[0], dict) else None
        series_rows.append(f"<tr><td>{E(map_name(os.path.basename(path)[:-5]))}</td><td><b>{E(str(sn))}</b><div class=small>{tracks}</div></td>"
                           f"<td>{E(str(b.get('name', '?'))) if b else '–'}</td><td class=n>{race_time(b.get('time')) if b else '–'}</td></tr>")

ID_OK = __import__("re").compile(r"^[A-Za-z0-9_-]{1,64}$")


def link(r, prefix=""):
    """Name als Link auf die Profilseite (nur bei unbedenklicher ID)."""
    name = E(str(r.get("name", "?")))
    rid = str(r.get("id", ""))
    return f'<a href="{prefix}p/{rid}.html">{name}</a>' if ID_OK.fullmatch(rid) else name


online = sum(int(num(s.get("players"))) for s in servers)
# Neue Fahrer der letzten 7 Tage (erstes Mal im BeamNet), fuer die Kopfzeile.
new_week = sum(1 for r in players if now - 7 * 86400 <= num(r.get("firstSeen")) <= now + 60)
new_text = f" · {new_week} neue{'r' if new_week == 1 else ''} Fahrer in 7 Tagen" if new_week else ""
profile_ids = {str(r.get("id")) for r in players if ID_OK.fullmatch(str(r.get("id", "")))}
rows = []
for s in servers:
    names = s.get("names") if isinstance(s.get("names"), list) else []
    ids = s.get("ids") if isinstance(s.get("ids"), list) and len(s.get("ids")) == len(names) else [""] * len(names)
    # Namen mit Profilseite (BeamNetCore 1.14+ meldet die IDs) werden verlinkt, Gaeste und Neue nicht.
    who = ", ".join(link({"name": n, "id": i}) if isinstance(i, str) and i in profile_ids else E(str(n))
                    for n, i in zip(names, ids))
    rows.append(f"<tr><td><b>{E(str(s.get('name', '?')))}</b>" + (f"<div class=small>{who}</div>" if who else "") +
                f"</td><td>{E(map_name(s.get('map', '?')))}" + (" <span class=small>⭐ Bonus-Map</span>" if bonus_map and s.get("map") == bonus_map else "") + "</td>"
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
    if num(r.get("monthXp"), None) is not None:
        return int(r["monthXp"])
    if num(r.get("monthStartXp"), None) is not None:
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
# Teams (teams.json des Plugins): Kilometer = Summe der Mitglieder.
km_by_id = {str(r.get("id")): num(r.get("km")) for r in players}
week_by_id = {str(r.get("id")): num(r.get("weekKm")) for r in players if r.get("week") == week}
month_by_id = {str(r.get("id")): month_xp(r) for r in players if 0 < month_xp(r) < 1e9}
teams_data = load(os.path.join(shared, "teams.json"))
# Wochen- und Saisonwertung wie im Spiel: Mitglieder zaehlen erst ab der Woche bzw. Saison nach ihrem Beitritt.
day0 = int(now // 86400) * 86400
week_start = day0 - time.gmtime(now).tm_wday * 86400
month_start = day0 - (time.gmtime(now).tm_mday - 1) * 86400
def counted(t, since):
    joined = t.get("joined") if isinstance(t.get("joined"), dict) else {}
    def ts(v):   # wie tonumber im Plugin: jede Zahl zaehlt (auch riesige = Zukunft), nur Fehlendes nicht
        return v if isinstance(v, (int, float)) and not isinstance(v, bool) and v == v else None
    def at(i):
        v = ts(joined.get(i))
        v = ts(t.get("created")) if v is None else v
        return 0 if v is None else v
    return [str(i) for i in list(t["members"])[:200] if at(i) < since]
teams, season_lead = [], None
for t in (teams_data.get("teams") or {}).values() if isinstance(teams_data, dict) and isinstance(teams_data.get("teams"), dict) else []:
    if isinstance(t, dict) and isinstance(t.get("members"), dict) and t.get("name"):
        teams.append((sum(km_by_id.get(str(i), 0) for i in t["members"]), len(t["members"]), str(t["name"])[:20],
                      sum(week_by_id.get(i, 0) for i in counted(t, week_start)), int(min(num(t.get("weekWins")), 999))))
        sxp = sum(month_by_id.get(i, 0) for i in counted(t, month_start))
        if sxp > 0 and (season_lead is None or (-sxp, str(t["name"])) < (-season_lead[0], season_lead[1])):
            season_lead = (sxp, str(t["name"])[:32])
teams.sort(key=lambda x: (-x[0], x[2]))
if season_lead:
    season_team = f'<p>🏅 Führendes Team dieser Saison: <b>{E(season_lead[1])}</b> ({season_lead[0]} XP)</p>' + season_team
# Team je Fahrer (fuer die Profilseiten).
team_of = {}
for t in (teams_data.get("teams") or {}).values() if isinstance(teams_data, dict) and isinstance(teams_data.get("teams"), dict) else []:
    if isinstance(t, dict) and isinstance(t.get("members"), dict) and t.get("name"):
        for i in list(t["members"])[:200]:
            team_of[str(i)] = str(t["name"])[:20]
# Team der Vorwoche aus der Momentaufnahme des Plugins (teamweek-<Woche>.json), wie im Spiel angesagt.
last_week = time.strftime("%G-W%V", time.gmtime(now - 7 * 86400))
tw = load(os.path.join(shared, f"teamweek-{last_week}.json"))
team_week = ""
if isinstance(tw, dict) and tw.get("week") == last_week and isinstance(tw.get("name"), str) and 0 < num(tw.get("km")) < 1e7:
    team_week = (f'<p>🏅 Team der Woche (KW {int(last_week[-2:])}): <b>{E(tw["name"][:32])}</b> – {km(num(tw.get("km")))}'
                 f'{" · " + str(len(tw["members"])) + " Fahrer" if isinstance(tw.get("members"), dict) else ""}</p>')
team_rows = [f"<tr><td class=n>{i}</td><td>{E(n)}" + (f" <span class=small>🏅 {wins}× Team der Woche</span>" if wins > 0 else "") +
             f"</td><td class=n>{m}</td><td class=n>{km(w)}</td><td class=n>{km(k)}</td></tr>"
             for i, (k, m, n, w, wins) in enumerate(teams[:10], 1)]
fastest = sorted([r for r in players if 0 < num(r.get("topSpeedKmh")) <= 600],
                 key=lambda r: (-num(r.get("topSpeedKmh")), str(r.get("name", ""))))[:10]
speed_rows = [f"<tr><td class=n>{i}</td><td>{link(r)}</td><td class=n>{int(round(num(r.get('topSpeedKmh'))))} km/h</td></tr>"
              for i, r in enumerate(fastest, 1)]
workers = sorted([r for r in players if 0 < num(r.get("jobsDone")) < 1e7],
                 key=lambda r: (-num(r.get("jobsDone")), str(r.get("name", ""))))[:10]
job_rows = [f"<tr><td class=n>{i}</td><td>{link(r)}</td><td class=n>{int(num(r.get('jobsDone')))}</td></tr>"
            for i, r in enumerate(workers, 1)]
convoyers = sorted([r for r in players if 0 < num(r.get("convoyKm")) < 1e7],
                   key=lambda r: (-num(r.get("convoyKm")), str(r.get("name", ""))))[:10]
convoy_rows = [f"<tr><td class=n>{i}</td><td>{link(r)}</td><td class=n>{km(num(r.get('convoyKm')))}</td></tr>"
               for i, r in enumerate(convoyers, 1)]
# Wochenziel fuer alle: Ziel aus community.json (vom Plugin), Fortschritt = Wochen-km aller Fahrer.
community = ""
cg = load(os.path.join(shared, "community.json"))
if isinstance(cg, dict) and cg.get("week") == week and 0 < num(cg.get("goal")) < 1e7:
    done = sum(num(r.get("weekKm")) for r in players if r.get("week") == week and 0 < num(r.get("weekKm")) < 1e6)
    goal = num(cg.get("goal"))
    pct = min(100, int(done / goal * 100))
    community = (f'<section><h2>Wochenziel für alle</h2><p>{km(done)} von {km(goal)} ({pct} %)'
                 f'{" – geschafft! 🎉" if done >= goal else ""}</p><div class=bar><span style="width:{pct}%"></span></div>'
                 f'<p class=small>Alle fahren zusammen; wer diese Woche mitfährt, bekommt Bonus-XP. Im Spiel: <b>/ziel</b></p></section>')
popular_rows = [f"<tr><td>{E(map_name(m))}</td><td class=n>{km(v)}</td><td class=n>{d}</td></tr>"
                for m, (v, d) in sorted(popular.items(), key=lambda x: (-x[1][0], x[0]))[:10]]
TRACK_OK = __import__("re").compile(r"^[A-Za-z0-9_-]{1,64}$")
def track_link(m, n):
    """Streckenname als Link auf die Streckenseite t/<Map>/<Strecke>.html (nur bei unbedenklichen Namen)."""
    if TRACK_OK.match(m) and TRACK_OK.match(str(n)):
        return f'<a href="t/{m}/{n}.html">{E(str(n))}</a>'
    return E(str(n))
records = [f"<tr><td>{E(map_name(m))}</td><td>{track_link(m, n)}</td><td>{E(str(b.get('name', '?')))}</td><td class=n>{race_time(b.get('time'))}</td></tr>"
           for m, n, b in races]


peak = load(os.path.join(shared, "peak.json"))
wt = load(os.path.join(shared, "weekly-track.json"))
weekly_track = ""
if isinstance(wt, dict) and wt.get("week") == week and wt.get("name"):
    weekly_track = (f'<p class=small>⭐ Strecke der Woche: <b>{E(str(wt.get("name")))}</b> auf {E(map_name(str(wt.get("map", "?"))))}'
                    f' – {int(num(wt.get("xp")))} Bonus-XP für den ersten Lauf der Woche (<b>/rennen {E(str(wt.get("name")))}</b>)</p>')
peak_text = ""
if isinstance(peak, dict) and 0 < num(peak.get("allTime")) < 1e6:
    peak_text = f" · Rekord: {int(num(peak.get('allTime')))} gleichzeitig"
    if 0 < num(peak.get("allTimeAt")) < 4e9:
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
.grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(300px,1fr)); gap:16px; margin-bottom:16px; }} .grid section {{ margin:0; }}
footer {{ color:var(--muted); font-size:12px; margin-top:24px; }}
a {{ color:inherit; text-decoration:none; border-bottom:1px dotted var(--muted); }} a:hover {{ color:var(--accent); }}
.stats {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; margin:0; }}
.stats div {{ background:var(--bg); border-radius:8px; padding:10px 12px; }} .stats b {{ display:block; font-size:20px; }}
.tags span {{ display:inline-block; background:var(--bg); border-radius:999px; padding:3px 10px; margin:0 6px 6px 0; font-size:13px; }}
svg.chart {{ width:100%; height:auto; display:block; }} svg.chart rect {{ fill:var(--accent); }}
.bar {{ height:12px; border-radius:6px; background:var(--line); overflow:hidden; }} .bar span {{ display:block; height:100%; background:var(--accent); }}
svg.chart rect:hover {{ fill:var(--text); }} svg.chart .grid {{ stroke:var(--line); }} svg.chart text {{ fill:var(--muted); font-size:11px; }}
.days {{ position:relative; height:18px; font-size:12px; color:var(--muted); }} .days span {{ position:absolute; top:2px; padding-left:3px; }}
.days i {{ font-style:normal; }} @media (max-width:560px) {{ .days i {{ display:none; }} }}
</style>"""


page = f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60"><title>{E(title)} – Status</title>
{STYLE}</head><body><main>
<h1><span>{E(title)}</span> Status</h1>
<div class=sub>{len(servers)} Server online · {online} Spieler{peak_text}{new_text} · Stand {time.strftime('%d.%m.%Y %H:%M', time.localtime(now))} (aktualisiert sich jede Minute)</div>
<section><h2>Server</h2>{table(["Server", "Map", "Spieler#"], rows, "Gerade meldet sich kein Server.")}</section>
{('<section><h2>Demnächst</h2>' + table(["Wann", "Was"], upcoming_rows, "") + '</section>') if upcoming_rows else ""}
{hours_chart()}
{community}
<section><h2>Bestenliste</h2>{table(["#", "Name", "Level#", "Liga", "XP#", "Kilometer#", "Erfolge#"], top, "Noch keine Einträge – einfach losfahren!")}</section>
<div class=grid>
<section><h2>Diese Woche</h2>{table(["#", "Name", "Kilometer#"], weekly, "Diese Woche ist noch niemand gefahren.")}</section>
<section><h2>Saison {E(season_title)}</h2>{season_team}{table(["#", "Name", "XP#"], season_rows, "In dieser Saison noch keine Punkte.")}</section>
<section><h2>Streckenrekorde</h2>{weekly_track}{table(["Map", "Strecke", "Name", "Zeit#"], records, "Noch keine Rekorde.")}</section>
<section><h2>Beliebteste Maps</h2>{table(["Map", "Kilometer#", "Fahrer#"], popular_rows, "Noch keine Kilometer je Map.")}</section>
<section><h2>Schnellste Fahrer</h2>{table(["#", "Name", "Spitze#"], speed_rows, "Noch keine Geschwindigkeiten.")}</section>
<section><h2>Meiste Aufträge</h2>{table(["#", "Name", "Aufträge#"], job_rows, "Noch keine Aufträge – im Spiel: /auftrag")}</section>
<section><h2>Meiste Konvoi-km</h2>{table(["#", "Name", "Kilometer#"], convoy_rows, "Noch niemand im Konvoi – im Spiel: /konvoi")}</section>
<section><h2>Rennserien</h2>{table(["Map", "Serie", "Bester", "Gesamt#"], series_rows, "Noch keine Serien – Admins im Spiel: /serie neu &lt;Name&gt; &lt;Strecke1&gt; &lt;Strecke2&gt;")}</section>
<section><h2>Orte für Aufträge</h2>{table(["Map", "Orte", "Anzahl#"], place_rows, "Noch keine Orte – Admins legen sie im Spiel an: /ort neu krankenhaus &lt;Name&gt;")}</section>
<section><h2>Teams</h2>{team_week}{table(["#", "Team", "Fahrer#", "Diese Woche#", "Kilometer#"], team_rows, "Noch keine Teams – im Spiel: /team gründen &lt;Name&gt;")}</section>
</div>
<footer><a href="hilfe.html">Hilfe, Befehle &amp; Regeln</a> · Chat-Befehle im Spiel: /hilfe · /stats · /top · /wo · /event · /regeln · /lang en · <a href="api.json">api.json</a></footer>
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
       "maps8": "Kenner aller Welten (8 Maps)", "level10": "Level 10", "km5000": "5000 km",
       "hours50": "50 Stunden unterwegs", "race50": "50 Rennen", "record5": "5 Streckenrekorde", "job1": "Erster Auftrag",
       "job25": "25 Aufträge", "job100": "Profi-Fahrer (100 Aufträge)", "chase1": "Erste Jagd gewonnen",
       "chase10": "Jagd-Legende (10 Jagden gewonnen)", "convoy10": "Konvoi-Fahrer (10 km)",
       "convoy100": "Kolonnenführer (100 km im Konvoi)", "explorer25": "Entdecker (25 km auf Bonus-Maps)",
       "explorer100": "Pionier (100 km auf Bonus-Maps)", "teamweek1": "Teamplayer (Team der Woche)",
       "teamweek5": "Dauerbrenner (5-mal Team der Woche)"}
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


def streak_text(r):
    """Laufende Tages-Serie (zaehlt nur, wenn zuletzt heute oder gestern gefahren) und die beste."""
    day = int(now // 86400)
    sd, cur, best_s = num(r.get("streakDay")), int(num(r.get("streak"))), int(num(r.get("bestStreak")))
    cur = cur if 0 < cur < 100000 and day - 1 <= sd <= day else 0
    best_s = max(cur, best_s if 0 <= best_s < 100000 else 0)
    if best_s < 2:
        return "–"
    return f"{cur} {'Tag' if cur == 1 else 'Tage'} (beste: {best_s})"


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
        stat("Aufträge", int(num(r.get("jobsDone")))),
        stat("Tages-Serie", streak_text(r)),
        stat("Im Konvoi", km(num(r.get("convoyKm")))),
        stat("Auf Bonus-Maps", km(num(r.get("bonusMapKm")))),
        stat("Team", E(team_of[rid]) if rid in team_of else "–"),
        stat("Team der Woche", f"{int(min(num(r.get('teamWeeks')), 999))}×" if num(r.get("teamWeeks")) >= 1 else "–"),
    ])
    profile = f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60"><title>{name} – {E(title)}</title>
{STYLE}</head><body><main>
<div class=sub><a href="../index.html">← {E(title)} Status</a></div>
<h1>{name}</h1>
<div class=sub>Level {lvl} · Liga {E(league_of(xp))}{(" · zuletzt auf " + E(str(r.get("lastServer")))) if r.get("lastServer") else ""}</div>
{("<div class=tags>" + "".join(f"<span>{PLACE_TEXT[p]} {MONTHS[int(m[5:7]) - 1]} {m[:4]}</span>" for m, p in TITLES.get(rid, [])[:6]) + "</div>") if TITLES.get(rid) else ""}
<section><div class=stats>{body}</div></section>
{weeks_chart(r)}
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

# --- Streckenseite je Strecke: Top 10, Laenge, Zahl der Fahrer -------------------------------------------------------
# t/<Map>/<Strecke>.html; hoechstens 200 Strecken je Map und 2000 insgesamt (gegen untergeschobene Riesenlisten).
tdir = os.path.join(os.path.dirname(out), "t")
os.makedirs(tdir, exist_ok=True)
twritten = set()
races_dir = os.path.join(shared, "races")
race_files = [] if os.path.islink(races_dir) else sorted(glob.glob(os.path.join(races_dir, "*.json")))
for path in race_files:
    m = os.path.basename(path)[:-5]
    data = load(path)
    tracks = data.get("tracks") if isinstance(data, dict) else None
    if not TRACK_OK.match(m) or not isinstance(tracks, dict):
        continue
    per_map = 0
    for n, t in sorted(tracks.items()):
        if not isinstance(t, dict) or not TRACK_OK.match(str(n)):
            continue
        per_map += 1
        if per_map > 200 or len(twritten) >= 2000:
            break
        recs = [r for r in (t.get("records") if isinstance(t.get("records"), list) else []) if isinstance(r, dict)][:50]
        rows = []
        for i, r in enumerate(recs[:10], 1):
            at = num(r.get("at"))
            when = time.strftime("%d.%m.%Y", time.localtime(at)) if 0 < at < 4e9 else "–"
            rows.append(f"<tr><td class=n>{i}</td><td>{link(r, '../../')}</td><td class=n>{race_time(r.get('time'))}</td><td>{when}</td></tr>")
        length = num(t.get("lengthM"))
        info = [f"Map {E(map_name(m))}"]
        if 0 < length < 1e6:
            info.append(f"Länge {length / 1000:.1f} km".replace(".", ","))
        info.append(f"{len(recs)} {'Fahrer' if len(recs) != 1 else 'Fahrer'} mit Zeit")
        page_t = f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60"><title>{E(str(n))} – {E(title)}</title>
{STYLE}</head><body><main>
<div class=sub><a href="../../index.html">← {E(title)} Status</a></div>
<h1>{E(str(n))}</h1>
<div class=sub>{" · ".join(info)}</div>
<section><h2>Bestenliste</h2>{table(["#", "Name", "Zeit#", "Am"], rows, "Noch keine Zeit – im Spiel: /rennen " + E(str(n)))}</section>
<footer>Im Spiel starten: <b>/rennen {E(str(n))}</b> · gemeinsam: <b>/rennen gruppe {E(str(n))}</b> · Stand {time.strftime('%d.%m.%Y %H:%M', time.localtime(now))}</footer>
</main></body></html>
"""
        os.makedirs(os.path.join(tdir, m), exist_ok=True)
        write(os.path.join(tdir, m, f"{n}.html"), page_t)
        twritten.add(f"{m}/{n}.html")
for old in glob.glob(os.path.join(tdir, "*.html")) + glob.glob(os.path.join(tdir, "*", "*.html")):
    if os.path.relpath(old, tdir) not in twritten:
        os.remove(old)
for d in glob.glob(os.path.join(tdir, "*")):
    if os.path.isdir(d) and not os.path.islink(d) and not os.listdir(d):
        os.rmdir(d)

# Hilfeseite fuer Spieler: Befehle, XP, Ligen, Erfolge, Regeln (eigene Regeln aus config.json wie im Plugin).
RULES = ["Fair fahren: kein absichtliches Rammen oder Blockieren.", "Freundlich im Chat – keine Beleidigungen, kein Spam.",
         "Den Anweisungen der Admins folgen."]
rules = cfg.get("rules")
if not (isinstance(rules, list) and len(rules) <= 10 and all(isinstance(r, str) and len(r.encode()) <= 200 for r in rules)):
    rules = RULES
COMMANDS = [
    ("/hilfe", "Alle Befehle im Chat"), ("/start", "Einsteiger-Pfad: fünf kleine Schritte mit Bonus-XP für neue Fahrer"), ("/stats [Name]", "Deine Werte oder die eines anderen Fahrers"),
    ("/top [km|xp|speed|auftraege|konvoi|jagd|woche|vorwoche|teams]", "Bestenliste (XP, Kilometer, Spitze, Aufträge, Konvoi, Verfolgungsjagden, diese oder letzte Woche, Teams dieser Woche)"),
    ("/liga", "Ligen und was dir bis zur nächsten fehlt"), ("/saison", "Saisonwertung des Monats mit führendem Team und deinem Abstand zum nächsten Platz – in den letzten 3 Tagen erinnert dich das Betreten an deinen Platz"),
    ("/aufgabe", "Tagesaufgabe mit Bonus-XP"), ("/erfolge", "Deine Erfolge"),
    ("/server", "Alle BeamNet-Server mit Map und Spielerzahl"), ("/wo &lt;Name&gt;", "Auf welchem Server fährt jemand gerade?"),
    ("/freund &lt;Name&gt;", "Freundesliste: Nachricht, sobald ein Freund irgendwo online kommt (/freund zeigt alle, /freund weg &lt;Name&gt; entfernt)"),
    ("/team", "Teams: /team gründen &lt;Name&gt;, /team beitreten &lt;Name&gt;, /team verlassen, /team woche – montags das Team der Woche (+50 XP für alle, die mitgefahren sind), am Monatsende das Team der Saison"),
    ("/auftrag", "Fahrauftrag holen: Patient ins Krankenhaus, Kinder zur Schule, Taxi, Lieferung … mit Zeitlimit und XP (/auftrag stop bricht ab)"),
    ("/orte", "Alle Orte (Krankenhaus, Schule, Feuerwache …) auf dieser Map"),
    ("/ort vorschlag &lt;Typ&gt; &lt;Name&gt;", "Einen Ort für Aufträge vorschlagen (z. B. krankenhaus, schule) – die Admins entscheiden"),
    ("/ziel", "Wochenziel für alle: zusammen Kilometer sammeln – wer mitfährt, bekommt Bonus-XP"),
    ("/heute", "Alles für heute auf einen Blick: Tagesaufgabe, XP-Event oder XP-Abend, Bonus-Map, Serie, Wochenziel"),
    ("/fangen", "Verfolgungsjagd: einer flüchtet, alle anderen jagen ihn – XP fürs Fangen und fürs Entkommen (/fangen mit)"),
    ("/konvoi", "Zusammen fahren: wer nah bei anderen Spielern fährt, bekommt Bonus-XP – zeigt auch, wer in der Nähe ist"),
    ("/duell &lt;Name&gt; &lt;Strecke&gt;", "Fordere einen Spieler zum Zeitrennen heraus (annehmen: /duell ja) – der Sieger bekommt Bonus-XP"),
    ("/km", "Kilometer dieser Sitzung"), ("/rennen &lt;Strecke&gt;", "Zeitrennen starten (Strecken: /rennen)"),
    ("/serie [Name]", "Rennserie: mehrere Strecken nacheinander, die Zeiten werden addiert – eigene Bestenliste"),
    ("/rekorde", "Streckenrekorde dieser Map"), ("/vote map &lt;Name&gt;", "Abstimmung über eine andere Map"),
    ("/event", "Läuft gerade ein XP-Event? Wann ist der nächste XP-Abend?"), ("/melden &lt;Name&gt; &lt;Grund&gt;", "Meldung an die Admins"),
    ("/stats", "zeigt auch deine Tages-Serie: jeden Tag ab 1 km fahren gibt ab dem 2. Tag Bonus-XP"),
    ("/regeln", "Die Regeln"), ("/lang en", "English (zurück: /lang de)"),
]
cmd_rows = [f"<tr><td><b>{c}</b></td><td>{d}</td></tr>" for c, d in COMMANDS]
# Bonus-XP mit den Werten aus config.json (ausgeschaltete fehlen).
def cv(k, d):
    v = num(cfg.get(k), d)
    return int(v) if v == int(v) else v
def g(v):
    return f"{v:g}".replace(".", ",")
bonus = []
if cv("jobXpPerKm", 25) > 0:
    bonus.append(f"<b>Aufträge</b> (/auftrag): {g(cv('jobXpPerKm', 25))} XP je km Luftlinie, ab 1 km +{g(cv('jobXp', 20))}, "
                 "Notfälle ×1,5, schnelle Fahrer +50 %; <b>Schicht</b>: beim 3., 5. und ab dem 10. Auftrag in Folge "
                 f"+25/+50/+100 (höchstens {g(cv('jobXpPerHour', 600))} Auftrags-XP je Stunde)")
if cv("convoyXp", 20) > 0:
    bonus.append(f"<b>Konvoi</b> (/konvoi): je {g(cv('convoyKm', 3))} km zusammen mit anderen +{g(cv('convoyXp', 20))}")
if cv("alertEverySec", 1800) > 0 and cv("alertXp", 50) > 0:
    bonus.append(f"<b>Einsatz-Alarm</b>: wer zuerst am Ziel ist, +{g(cv('alertXp', 50))}")
bonus.append("<b>Verfolgungsjagd</b> (/fangen): Fangen +60, Entkommen +100")
if cv("streakXp", 10) > 0:
    bonus.append(f"<b>Tages-Serie</b>: jeden Tag ab {g(cv('streakMinKm', 1))} km fahren, ab dem 2. Tag +{g(cv('streakXp', 10))} je Serientag")
if cv("teamWeekXp", 50) > 0:
    bonus.append(f"<b>Team der Woche</b> (/team): +{g(cv('teamWeekXp', 50))} für alle Mitglieder, die mitgefahren sind")
if cv("communityXp", 100) > 0:
    bonus.append(f"<b>Wochenziel</b> (/ziel): +{g(cv('communityXp', 100))} für alle, die mitgefahren sind")
if cv("comebackXp", 50) > 0:
    bonus.append(f"<b>Willkommen zurück</b>: nach {g(cv('comebackDays', 14))} Tagen Pause einmal +{g(cv('comebackXp', 50))}")
xa = load(os.environ.get("BEAMNET_XPABEND") or os.path.join(shared, "xpabend.json"))
if isinstance(xa, dict) and now < num(xa.get("next")) < now + 8 * 86400 and 1.5 <= num(xa.get("factor")) <= 5:
    at = num(xa.get("next"))
    bonus.append(f"<b>XP-Abend</b>: {g(num(xa.get('factor')))}-fache XP am {['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'][time.localtime(at).tm_wday]} ab {time.strftime('%H:%M', time.localtime(at))} Uhr")
if isinstance(bm, dict) and isinstance(bm.get("map"), str) and bm["map"] and 1 < num(bm.get("factor")) <= 3 and now < num(bm.get("until")):
    bonus.append("<b>Bonus-Map des Tages</b>: auf der am wenigsten gefahrenen Map gibt es mehr XP beim Fahren "
                 "(steht unter „Demnächst“ und bei /event)")
bonus_items = "".join(f"<li>{b}</li>" for b in bonus)
league_rows = [f"<tr><td>{E(str(l.get('name', '?')))}</td><td class=n>ab {int(num(l.get('xp')))} XP</td></tr>"
               for l in leagues if isinstance(l, dict)]
rule_items = "".join(f"<li>{E(r)}</li>" for r in rules)
ach_tags = "".join(f"<span>{E(v)}</span>" for v in ACH.values())
help_page = f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hilfe – {E(title)}</title>
{STYLE}</head><body><main>
<div class=sub><a href="index.html">← {E(title)} Status</a></div>
<h1>Hilfe &amp; <span>Regeln</span></h1>
<div class=sub>Alles, was du im BeamNet wissen musst – Kilometer und XP zählen auf allen Servern.</div>
<section><h2>Regeln</h2>{"<ol>" + rule_items + "</ol>" if rule_items else "<p class=empty>Keine Regeln eingetragen.</p>"}</section>
<section><h2>Chat-Befehle</h2>{table(["Befehl", "Was er macht"], cmd_rows, "")}</section>
<div class=grid>
<section><h2>So bekommst du XP</h2><p>{num(xp_km):g} XP je Kilometer und {num(xp_min):g} XP je Minute Fahrzeit
(nur in Bewegung). Dazu Bonus-XP für Erfolge, die Tagesaufgabe, Rennen und Streckenrekorde. Bei einem
<b>XP-Event</b> gibt es ein Vielfaches – schau mit <b>/event</b> nach.</p><ul>{bonus_items}</ul></section>
<section><h2>Ligen</h2>{table(["Liga", "XP#"], league_rows, "")}</section>
</div>
<section><h2>Erfolge ({len(ACH)})</h2><div class=tags>{ach_tags}</div></section>
<footer>Stand {time.strftime('%d.%m.%Y %H:%M', time.localtime(now))}</footer>
</main></body></html>
"""
write(os.path.join(os.path.dirname(out), "hilfe.html"), help_page)

# Kennzahlen im Prometheus-Textformat (fuer Grafana o. Ae.: http://<server>:<port>/metrics.txt abfragen).
def metric_label(v):
    return re.sub(r'["\\\n]', "_", str(v))[:64]
metrics = [
    "# HELP beamnet_players Spieler je Server (laut BeamNetCore-Lebenszeichen)",
    "# TYPE beamnet_players gauge",
]
for srv in servers:
    metrics.append(f'beamnet_players{{port="{int(num(srv.get("port")))}",map="{metric_label(srv.get("map", "?"))}"}} {int(num(srv.get("players")))}')
metrics += ["# HELP beamnet_players_max Plaetze je Server", "# TYPE beamnet_players_max gauge"]
for srv in servers:
    metrics.append(f'beamnet_players_max{{port="{int(num(srv.get("port")))}"}} {int(num(srv.get("max")))}')
metrics += [
    "# HELP beamnet_players_online Spieler im ganzen Netzwerk", "# TYPE beamnet_players_online gauge",
    f"beamnet_players_online {online}",
    "# HELP beamnet_servers_online Server mit aktuellem Lebenszeichen", "# TYPE beamnet_servers_online gauge",
    f"beamnet_servers_online {len(servers)}",
    "# HELP beamnet_players_record Meiste Spieler gleichzeitig (Rekord)", "# TYPE beamnet_players_record gauge",
    f"beamnet_players_record {int(num(peak.get('allTime'))) if isinstance(peak, dict) else 0}",
    "# HELP beamnet_drivers_registered Fahrer mit Spielerdatei", "# TYPE beamnet_drivers_registered gauge",
    f"beamnet_drivers_registered {len(players)}",
    "# HELP beamnet_km_total Gefahrene Kilometer aller Fahrer", "# TYPE beamnet_km_total counter",
    f"beamnet_km_total {sum(num(r.get('km')) for r in players):.1f}",
]
write(os.path.join(os.path.dirname(out), "metrics.txt"), "\n".join(metrics) + "\n")
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
TimeoutStartSec=120
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
  beamnet slots [apply|<nr> <plätze>|<nr> auto]  Spielerplätze: Auslastung 30 Tage, mehr Plätze für beliebte Server
  beamnet logs <nr> [zeilen]     Letzte Zeilen des Server-Protokolls
  beamnet plugins                Installierte Server-Plugins je Server
  beamnet plugin-disable <name>  Plugin auf allen Servern abschalten (verschiebt nach Server.disabled)
  beamnet plugin-enable <name>   … und wieder einschalten
  beamnet players [json]         Wer gerade fährt, je Server mit Namen (mit Plugin BeamNetCore)
  beamnet heute|woche|teams|saison  Überblick wie im Telegram-Chat (Boni, Wochenbeste, Teams, Saison)
  beamnet backup                 Sichert Konfigurationen, Plugins und Dienste nach $BACKUP_DIR
  beamnet restore [JJJJ-MM-TT|check]   Tägliche Datensicherungen anzeigen, prüfen oder einen Stand zurückholen
  beamnet install-core           Installiert das Plugin BeamNetCore (km, XP, Liga, Rennen, Moderation) auf allen Servern
  beamnet bans · unban <Name> · modlog [n]   Banns ansehen/aufheben, Moderationsprotokoll
  beamnet ansage [HH:MM] <Text>  Ansage auf allen Servern, sofort oder zur Uhrzeit (ohne Text: geplante zeigen)
  beamnet event [start <Faktor> <Dauer>|stop]   XP-Event auf allen Servern (z. B. start 2 2h)
  beamnet event auto <Tage> <HH:MM> <Faktor> <Dauer>|aus   Automatischer XP-Abend, z. B. auto fr,sa 20:00 2 2h
  beamnet admin list · add <Name …> · remove <Name …>   Admins für Rennen und Moderation
  beamnet config [<Schlüssel> <Wert>|standard]   Spiel-Einstellungen (XP, Aufträge, Konvoi, Tagesaufgaben …)
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
    load_heartbeats     # einmal je Aufruf (Befehlsersetzungen $(...) koennen den Zwischenspeicher nicht fuellen)
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
        slots|plaetze|plätze) cmd_slots "$@" ;;
        heute|today) telegram_today ;;
        woche|week) telegram_week ;;
        teams) telegram_teams ;;
        saison|season) telegram_season ;;
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
        ansage|announce) cmd_ansage "$@" ;;
        event|xp-abend) cmd_event "$@" ;;
        config|einstellungen) cmd_config "$@" ;;
        self-update) cmd_self_update ;;
        update|aktualisieren) cmd_update ;;
        version|--version) echo "BeamNet $VERSION" ;;
        hilfe|help|-h|--help) cmd_help ;;
        *) cmd_help; exit 1 ;;
    esac
}

main "$@"
