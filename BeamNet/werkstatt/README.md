# BeamNet-Werkstatt – deine lokale KI programmiert, Claude prüft

Ein Programm zum Doppelklicken. Es läuft auf deinem Laptop, holt die Aufgaben, die Claude vorbereitet hat, lässt sie
von **deiner lokalen KI** erledigen (auf dem Laptop oder auf deinem Server), testet das Ergebnis und lädt es als eigenen
Branch hoch. Danach wartet es auf neue Aufgaben und macht von selbst weiter. Claude muss nur noch drüberschauen.

```
Claude legt Aufgaben ab  →  Werkstatt (dein Laptop) + lokale KI  →  Test  →  Branch lokal/…  →  Claude prüft, übernimmt
```

## Herunterladen

- **Windows:** https://github.com/sebastian10099/Agar.io-bot/releases/download/werkstatt/BeamNet-Werkstatt-Windows.exe
  – doppelklicken. Beim ersten Start warnt Windows (unbekannter Herausgeber): *Weitere Informationen → Trotzdem ausführen*.
- **Mac:** https://github.com/sebastian10099/Agar.io-bot/releases/download/werkstatt/BeamNet-Werkstatt-Mac.zip – entpacken, dann im Terminal:
  `xattr -d com.apple.quarantine ~/Downloads/BeamNet-Werkstatt; ~/Downloads/BeamNet-Werkstatt`

## Einmal vorbereiten

1. **Git** installieren (Windows: https://git-scm.com/download/win – alles mit Standard-Einstellungen; Mac: ist meist da).
2. **Ollama** installieren (https://ollama.com) und ein Code-Modell laden, je nach Arbeitsspeicher:
   - 32 GB und mehr: `ollama pull qwen3-coder:30b`
   - 24 GB: `ollama pull qwen2.5-coder:14b`
   - 16 GB: `ollama pull qwen2.5-coder:7b` (nur kleine Aufgaben)
   LM Studio geht auch – dort den lokalen Server starten, die Werkstatt findet ihn selbst.
3. Werkstatt starten. Beim ersten Mal lädt sie das Projekt nach `BeamNet-Werkstatt/Agar.io-bot` in deinem
   Benutzerordner. Beim ersten Hochladen fragt Git einmal nach deinem GitHub-Login (Browserfenster).

## Die KI läuft auf deinem Server

Ollama auf dem Server nicht offen ins Internet stellen. Am einfachsten ein SSH-Tunnel vom Laptop aus:

```
ssh -N -L 11434:127.0.0.1:11434 root@<dein-server>
```

Solange das Fenster offen ist, findet die Werkstatt die KI wie eine lokale. Ohne Tunnel (nur im eigenen Netz):
`BeamNet-Werkstatt --url http://<server>:11434`.

## Optionen

| Option | Wirkung |
|---|---|
| `--modell qwen3-coder:30b` | bestimmtes Modell (sonst wählt sie das beste vorhandene Code-Modell) |
| `--url http://…:11434` | Adresse der KI |
| `--kontext 65536` | wie viel Text die KI auf einmal sieht (größer = mehr Speicher) |
| `--einmal` | nur einen Durchlauf |
| `--nicht-hochladen` | ausprobieren, ohne etwas hochzuladen |

Einstellungen, Protokoll (`werkstatt.log`) und die Liste erledigter Aufgaben liegen in `BeamNet-Werkstatt` in deinem
Benutzerordner. Eine Aufgabe noch einmal machen lassen: ihre Zeile aus `erledigt.json` löschen und den Branch auf
GitHub entfernen.

## Wie die Werkstatt arbeitet

- Die KI schreibt nur **Änderungsblöcke** (gesucht/ersetzt) statt ganzer Dateien – das geht auch mit großen Dateien.
- Sie darf nur die Dateien ändern, die in der Aufgabe stehen.
- Passt ein Block nicht oder ist der Schnelltest rot, bekommt sie die Fehlermeldung und versucht es erneut
  (höchstens 3-mal). Auch ein rotes Ergebnis wird hochgeladen – deutlich markiert –, damit Claude entscheiden kann.
- Die Plugin-Tests sind ins Programm eingebaut (kein Python nötig). Die Werkzeug-Tests laufen in GitHub.
- Aufgaben schreibt Claude nach `BeamNet/lokale-ki/aufgaben/` (Format siehe `BeamNet/lokale-ki/README.md`).
