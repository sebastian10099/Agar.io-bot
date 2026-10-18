#!/usr/bin/env bash
# Alle Pruefungen auf einmal: Plugin (Lua 5.3, 5.4, LuaJIT), Werkzeug und shellcheck.
# Ergebnis 0 nur, wenn wirklich alles gruen ist – vor jedem Commit ausfuehren:  bash BeamNet/tests/alle.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
rc=0

echo "== Plugin BeamNetCore =="
lua_out=$(python3 tests/run_lua_tests.py 2>&1)
lua_rc=$?
grep -E "Prüfungen|FEHLER" <<<"$lua_out"
if (( lua_rc != 0 )) || grep -q "FEHLER" <<<"$lua_out" || ! grep -q "Prüfungen bestanden, 0 fehlgeschlagen" <<<"$lua_out"; then
    echo "-> Plugin: ROT"; rc=1
fi

echo "== Fenster BeamNetUI =="
for rt in luajit21 lua53; do
    if ! BEAMNET_LUA=$rt python3 tests/run_client_tests.py; then echo "-> Fenster (Spielseite): ROT"; rc=1; fi
done
if command -v node >/dev/null; then
    if ! node tests/ui_window_test.js; then echo "-> Fenster (Darstellung): ROT"; rc=1; fi
else
    echo "(node nicht installiert – Fenster-Darstellung übersprungen)"
fi

echo "== Werkzeug beamnet.sh =="
sh_out=$(bash tests/beamnet_test.sh 2>&1)
sh_rc=$?
grep -E "FEHLER|Prüfungen" <<<"$sh_out"
if (( sh_rc != 0 )) || grep -q "^FEHLER" <<<"$sh_out"; then
    echo "-> Werkzeug: ROT"; rc=1
fi

echo "== shellcheck =="
if command -v shellcheck >/dev/null; then
    if shellcheck -S warning beamnet.sh tests/beamnet_test.sh tests/alle.sh; then echo "ok"; else echo "-> shellcheck: ROT"; rc=1; fi
else
    echo "(shellcheck nicht installiert – übersprungen)"
fi

(( rc == 0 )) && echo "== ALLES GRÜN ==" || echo "== NICHT GRÜN – nicht committen =="
exit "$rc"
