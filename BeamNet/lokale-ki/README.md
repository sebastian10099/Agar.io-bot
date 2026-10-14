# Lokale KI: Dein Rechner programmiert, Claude prüft

Ziel: Die eigentliche Programmierarbeit macht ein **Code-Modell auf deinem Mac** (kostet keine Tokens). Claude
schreibt nur die Aufgaben und prüft danach das Ergebnis – übernehmen oder verwerfen.

```
Claude schreibt Aufgabe  →  dein Mac (Ollama + Aider) programmiert und testet  →  Branch lokal/…  →  Claude prüft
```

## Einmal einrichten

```bash
cd Agar.io-bot                       # dein lokaler Klon des Projekts
git pull
bash BeamNet/lokale-ki/einrichten.sh
```

Das Skript installiert [Ollama](https://ollama.com) (führt Modelle lokal aus) und [Aider](https://aider.chat)
(lässt das Modell direkt im Git-Projekt programmieren) und wählt nach deinem Arbeitsspeicher ein Modell:

| Arbeitsspeicher | Modell | Hinweis |
|---|---|---|
| 32 GB und mehr | `qwen3-coder:30b` | beste Wahl für die großen Dateien des Projekts |
| 24 GB | `qwen2.5-coder:14b` | gut für kleinere Aufgaben |
| 16 GB | `qwen2.5-coder:7b` | nur kleine, klar umrissene Aufgaben |

Anderes Modell ausprobieren: `MODELL=devstral:24b bash BeamNet/lokale-ki/einrichten.sh` (auch z. B. `gpt-oss:20b`).

## Eine Aufgabe erledigen lassen

```bash
bash BeamNet/lokale-ki/aufgabe.sh BeamNet/lokale-ki/aufgaben/01-hilfe-zu-befehl.md
```

Das Skript legt den Branch aus der Aufgabe an, lässt die KI programmieren, führt den Schnelltest aus, lädt den
Branch hoch und sagt dir am Ende, was du Claude schreiben sollst – z. B. **„prüfe Branch lokal/hilfe-zu-befehl“**.
Claude schaut sich dann nur die Änderung an, lässt die GitHub-Tests laufen und übernimmt sie (oder sagt, was fehlt).

## Gut zu wissen

- Lokale Modelle sind schwächer als Claude: Die Aufgaben in `aufgaben/` sind deshalb klein und sehr genau beschrieben.
  Klappt eine nicht, einfach Claude Bescheid sagen – dann wird die Aufgabe kleiner geschnitten oder Claude macht sie.
- Die Werkzeug-Tests (`beamnet_test.sh`) brauchen Linux-Befehle und laufen deshalb erst in GitHub; die Plugin-Tests
  laufen auch auf dem Mac (braucht `pip install lupa`, macht das Einrichtungs-Skript).
- Nichts davon greift auf deine Server zu – es ändert nur den Code im Projekt.
