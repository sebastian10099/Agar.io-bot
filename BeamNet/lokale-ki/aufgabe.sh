#!/usr/bin/env bash
# Laesst die lokale KI eine Aufgabe erledigen und laedt das Ergebnis als eigenen Branch hoch.
# Aufruf (im Projektordner):  bash BeamNet/lokale-ki/aufgabe.sh BeamNet/lokale-ki/aufgaben/01-beispiel.md
#
# Aufbau einer Aufgabendatei (schreibt Claude):
#   Branch: lokal/<name>
#   Dateien: <Datei, die geaendert werden darf> [<weitere> …]
#   Lesen: <Datei nur als Hintergrund> [<weitere> …]      (optional)
#   Test: <Befehl fuer den schnellen Test>                 (optional)
#   ---
#   <Beschreibung der Aufgabe>
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(git -C "$HERE" rev-parse --show-toplevel)"
task=${1:?Aufruf: aufgabe.sh <aufgabendatei.md>}
[[ -f $task ]] || { echo "Aufgabe $task nicht gefunden."; exit 1; }
model=${MODELL:-$(cat "$HERE/.modell" 2>/dev/null || echo qwen2.5-coder:14b)}
export OLLAMA_API_BASE=${OLLAMA_API_BASE:-http://127.0.0.1:11434}

field() { grep -m1 -E "^$1:" "$task" | cut -d: -f2- | sed 's/^ *//'; }
branch=$(field Branch)
files=$(field Dateien)
reads=$(field Lesen)
testcmd=$(field Test)
[[ $branch =~ ^lokal/[A-Za-z0-9._-]+$ ]] || { echo "Branch muss lokal/<name> heißen."; exit 1; }
[[ -n $files ]] || { echo "Zeile 'Dateien:' fehlt."; exit 1; }
body=$(sed -n '/^---$/,$p' "$task" | tail -n +2)

cd "$TOP" || exit 1
[[ -z $(git status --porcelain) ]] || { echo "Erst offene Änderungen sichern oder verwerfen (git status)."; exit 1; }
git fetch -q origin claude/friendly-goldberg-31l8fp
git checkout -q -B "$branch" origin/claude/friendly-goldberg-31l8fp || exit 1

rules="Regeln: Ändere nur die genannten Dateien. Halte dich an den Stil des vorhandenen Codes (Kommentare auf Deutsch).
Spieler-Texte auf Deutsch mit Umlauten; jeder neue deutsche Chat-Text im Plugin braucht einen englischen Eintrag in der EN-Tabelle.
Schreibe zu jeder Änderung einen Test. Keine Versionsnummern, README oder ROADMAP ändern."

args=(--model "ollama_chat/$model" --yes-always --no-show-model-warnings --message "$rules

$body")
for r in $reads; do args+=(--read "$r"); done
[[ -n $testcmd ]] && args+=(--test-cmd "$testcmd" --auto-test)
# shellcheck disable=SC2086
aider "${args[@]}" $files

echo
echo "Schnelltest …"
ok=1
if [[ -n $testcmd ]]; then bash -c "$testcmd" || ok=0; fi
git log --oneline origin/claude/friendly-goldberg-31l8fp..HEAD | head -20
if [[ $(git rev-list --count origin/claude/friendly-goldberg-31l8fp..HEAD) -eq 0 ]]; then
    echo "Die KI hat nichts geändert."
    exit 1
fi
git push -q -u origin "$branch" --force-with-lease && {
    echo
    if [[ $ok == 1 ]]; then echo "✅ Hochgeladen. Sag Claude: \"prüfe Branch $branch\""
    else echo "⚠️ Hochgeladen, aber der Schnelltest ist rot. Sag Claude: \"prüfe Branch $branch (Test rot)\""; fi
}
git checkout -q claude/friendly-goldberg-31l8fp 2>/dev/null || true
