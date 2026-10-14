#!/usr/bin/env bash
# Richtet die lokale KI auf deinem Mac (oder Linux-PC) ein: Ollama + ein Code-Modell + Aider.
# Aufruf (im Projektordner):  bash BeamNet/lokale-ki/einrichten.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/.modell"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# 1. Arbeitsspeicher -> passendes Modell (q4, damit es locker in den Speicher passt).
if [[ $(uname) == Darwin ]]; then
    ram_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
else
    ram_gb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
fi
if   (( ram_gb >= 48 )); then model="qwen3-coder:30b"
elif (( ram_gb >= 32 )); then model="qwen3-coder:30b"
elif (( ram_gb >= 24 )); then model="qwen2.5-coder:14b"
elif (( ram_gb >= 16 )); then model="qwen2.5-coder:7b"
else model="qwen2.5-coder:3b"; fi
model=${MODELL:-$model}
say "Arbeitsspeicher: ${ram_gb} GB → Modell: $model   (anderes Modell: MODELL=devstral:24b bash $0)"

# 2. Ollama (fuehrt die Modelle lokal aus).
if ! command -v ollama >/dev/null; then
    say "Ollama installieren …"
    if command -v brew >/dev/null; then
        brew install ollama
    elif [[ $(uname) == Linux ]]; then
        curl -fsSL https://ollama.com/install.sh | sh
    else
        echo "Bitte Ollama von https://ollama.com/download installieren und dieses Skript erneut starten."
        exit 1
    fi
fi
if ! curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    say "Ollama starten …"
    (ollama serve >/tmp/ollama.log 2>&1 &)
    sleep 3
fi
say "Modell laden (einmalig, kann je nach Größe 5–20 GB sein) …"
ollama pull "$model" || { echo "Modell konnte nicht geladen werden."; exit 1; }

# 3. Aider (programmiert mit dem lokalen Modell direkt im Git-Projekt).
if ! command -v aider >/dev/null; then
    say "Aider installieren …"
    python3 -m pip install --user --upgrade aider-install && python3 -m aider_install \
        || { echo "Aider-Installation fehlgeschlagen – siehe https://aider.chat/docs/install.html"; exit 1; }
fi

# 4. Fuer die Plugin-Tests: lupa (Lua in Python).
python3 -m pip install --user --quiet lupa 2>/dev/null || echo "Hinweis: lupa nicht installiert – Plugin-Tests laufen dann nur in GitHub."

echo "$model" >"$CONF"
say "Fertig. Eine Aufgabe ausführen:  bash BeamNet/lokale-ki/aufgabe.sh BeamNet/lokale-ki/aufgaben/<datei>.md"
