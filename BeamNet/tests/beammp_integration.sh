#!/usr/bin/env bash
# Integrationstest: startet den echten BeamMP-Server (offizielle Linux-Version von GitHub) mit BeamNetCore
# und prueft im Server-Protokoll, ob das Plugin fehlerfrei laedt und alle BeamMP-Funktionen findet.
# Laeuft in der CI (braucht Internet). Optional: BEAMMP_AUTH_KEY fuer einen voll angemeldeten Server.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$HERE/../server/BeamNetCore/main.lua"
WORK=$(mktemp -d)
RUN_SECONDS=${BEAMMP_RUN_SECONDS:-40}
trap 'rm -rf "$WORK"' EXIT

auth=()
[[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
release=$(curl -fsSL "${auth[@]}" https://api.github.com/repos/BeamMP/BeamMP-Server/releases/latest) || {
    echo "Release-Liste von BeamMP nicht erreichbar"; exit 1; }
read -r tag url < <(python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assets = [a for a in d.get("assets", []) if "x86_64" in a["name"] and not a["name"].endswith((".sig", ".asc", ".sha256"))]
pref = [a for a in assets if "ubuntu.24.04" in a["name"]] or [a for a in assets if "ubuntu" in a["name"]] or assets
print(d.get("tag_name", "?"), pref[0]["browser_download_url"] if pref else "")
' <<<"$release")
[[ -n ${url:-} ]] || { echo "Keine Linux-Version im Release $tag gefunden"; exit 1; }
echo "BeamMP-Server $tag: $url"
curl -fsSL "$url" -o "$WORK/BeamMP-Server" || { echo "Download fehlgeschlagen"; exit 1; }
chmod +x "$WORK/BeamMP-Server"
ldd "$WORK/BeamMP-Server" | grep "not found" && echo "(fehlende Bibliotheken – siehe oben)"

mkdir -p "$WORK/Resources/Server/BeamNetCore" "$WORK/Resources/Client" "$WORK/shared"
cp "$PLUGIN" "$WORK/Resources/Server/BeamNetCore/main.lua"
# Ohne AuthKey startet BeamMP nicht. Ein Platzhalter genuegt, damit Plugins geladen werden; die Anmeldung beim
# BeamMP-Backend schlaegt dann fehl, das ist fuer diesen Test egal.
cat >"$WORK/ServerConfig.toml" <<TOML
[General]
Name = "BeamNet | CI-Test"
Port = 30814
AuthKey = "${BEAMMP_AUTH_KEY:-00000000-0000-4000-8000-000000000000}"
Private = true
MaxPlayers = 8
MaxCars = 1
Map = "/levels/gridmap_v2/info.json"
Description = "Integrationstest"
ResourceFolder = "Resources"
Debug = true
LogChat = true
InformationPacket = true
IP = "::"
Tags = "Freeroam"
AllowGuests = true

[Misc]
ImScaredOfUpdates = true
UpdateReminderTime = "30s"
TOML

# Last: viele Spielerdateien und ein frischer Bestenlisten-Index (Format 2, wie ihn der Waechter schreibt). Das Plugin
# baut im ersten Takt das Saisonarchiv des Vormonats und liest dafuer die Spieler – ueber den Index.
LOAD_PLAYERS=${BEAMNET_LOAD_PLAYERS:-5000}
python3 -I - "$WORK/shared" "$LOAD_PLAYERS" <<'PY'
import calendar, json, os, sys, time
shared, n = sys.argv[1], int(sys.argv[2])
os.makedirs(os.path.join(shared, "players"), exist_ok=True)
now = time.time()
t = time.gmtime(now)
prev = f"{t.tm_year - 1}-12" if t.tm_mon == 1 else f"{t.tm_year}-{t.tm_mon - 1:02d}"
lines = [f"# beamnet-index 2 {int(now)}"]
for i in range(n):
    pid = str(100000 + i)
    rec = {"id": pid, "name": f"Last {i}", "km": i * 1.5, "seconds": i * 60, "bonusXp": i % 50,
           "lastMonth": prev, "lastMonthXp": i % 997, "topSpeedKmh": 100 + i % 200}
    with open(os.path.join(shared, "players", pid + ".json"), "w") as f:
        json.dump(rec, f)
    lines.append("\t".join([pid, rec["name"], str(rec["km"]), str(rec["seconds"]), str(rec["bonusXp"]), "", "", "", "",
                            "", "", prev, str(rec["lastMonthXp"]), str(rec["topSpeedKmh"])]))
with open(os.path.join(shared, "players-index.tsv"), "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"{n} Spielerdateien und Index angelegt")
PY

export BEAMNET_SHARED="$WORK/shared"
started=$(date +%s)
echo "Starte den Server für $RUN_SECONDS s …"
(cd "$WORK" && timeout --signal=INT "$RUN_SECONDS" ./BeamMP-Server >"$WORK/out.log" 2>&1 </dev/null) &
server=$!
# Nach 15 s das Plugin aendern: laedt BeamMP es im laufenden Betrieb neu (wie nach "beamnet install-core")?
sleep 15
printf '\n-- Integrationstest: geaendert\n' >>"$WORK/Resources/Server/BeamNetCore/main.lua"
wait "$server"
code=$?
echo "Server beendet (Code $code). Protokoll:"
log="$WORK/out.log"
[[ -f $WORK/Server.log ]] && log="$WORK/Server.log"
sed 's/^/  | /' "$log" | tail -n 120

fails=0
check() { if eval "$2"; then echo "OK   $1"; else echo "FEHLER $1"; fails=$((fails + 1)); fi; }
# shellcheck disable=SC2034  # wird in den eval-Pruefungen benutzt
all=$(cat "$WORK/out.log" "$WORK/Server.log" 2>/dev/null)
check "Plugin geladen" 'grep -q "\[BeamNetCore\] [0-9.]* geladen" <<<"$all"'
check "keine Lua-Fehler von BeamNetCore" '! grep -qiE "BeamNetCore.*(error|fehler)|(error|fehler).*BeamNetCore" <<<"$all"'
check "keine fehlenden BeamMP-Funktionen" '! grep -q "\[BeamNetCore\] Warnung" <<<"$all"'
check "Status-Datei geschrieben" '[[ -f $WORK/shared/servers/30814.json ]]'
if [[ -f $WORK/shared/servers/30814.json ]]; then
    cat "$WORK/shared/servers/30814.json"; echo
    updated=$(grep -o '"updated":[0-9]*' "$WORK/shared/servers/30814.json" | grep -o '[0-9]*$')
    # Der Status wird alle 15 s aus dem Takt (MP.CreateEventTimer) geschrieben – ist er spaeter als der Start, laeuft der Takt.
    check "Takt läuft (Status $(( ${updated:-0} - started )) s nach dem Start erneuert)" '[[ -n $updated ]] && (( updated - started >= 20 ))'
    check "Bestenliste ueber den Index gelesen (${LOAD_PLAYERS} Spieler)" "grep -q '\"board\":\"index\"' '$WORK/shared/servers/30814.json'"
    for f in positions vehicles identifiers timers files; do
        check "BeamMP-Funktion vorhanden: $f" "grep -q '\"$f\":true' '$WORK/shared/servers/30814.json'"
    done
fi
loads=$(grep -c "\[BeamNetCore\] [0-9.]* geladen" "$log")
if (( loads >= 2 )); then
    echo "INFO Neu laden im laufenden Betrieb: ja ($loads-mal geladen)"
else
    echo "INFO Neu laden im laufenden Betrieb: nein (nur nach Neustart)"
fi
prevmonth=$(python3 -c 'import time; t=time.gmtime(); print(f"{t.tm_year - 1}-12" if t.tm_mon == 1 else f"{t.tm_year}-{t.tm_mon - 1:02d}")')
check "Saisonarchiv aus ${LOAD_PLAYERS} Spielern gebaut" "[[ -f '$WORK/shared/seasons/$prevmonth.json' ]] && grep -q '\"xp\":996' '$WORK/shared/seasons/$prevmonth.json'"
echo
if [[ $fails -eq 0 ]]; then echo "Integrationstest bestanden ($tag)"; else echo "$fails Prüfung(en) fehlgeschlagen ($tag)"; fi
[[ $fails -eq 0 ]]
