# Agenten

Eine Kette von LLM-Agenten, die dieses Projekt eigenstaendig weiterentwickelt.
Laeuft auf deinem Rechner, ueber [OpenRouter](https://openrouter.ai), ohne
Abhaengigkeiten ausser Node 18+.

```
Scout  ->  Critic  ->  Implementer  <->  Reviewer  ->  Curator
```

Jeder Agent bekommt das Ergebnis des vorigen als Nachricht. Wer wem was
geschrieben hat, steht nach jedem Lauf in `agents/logs/`.

| Rolle | Aufgabe | Werkzeuge |
| --- | --- | --- |
| **Scout** | Sucht im Code nach konkreten Verbesserungen | lesen, suchen |
| **Critic** | Waehlt hoechstens eine aus - oder stoppt den Lauf | lesen, suchen |
| **Implementer** | Schreibt den Patch, nur den beauftragten | lesen, suchen, `propose_edit` |
| **Reviewer** | Prueft den Patch, kann ihn zurueckgeben | lesen, suchen |
| **Curator** | Schreibt Backlog und Journal fort | - |

## Einrichten

```bash
export OPENROUTER_API_KEY=sk-or-...        # https://openrouter.ai/keys
node agents/run.js --list-models           # verfuegbare Modell-Slugs ansehen
```

Dann in `agents/config.json` pro Rolle ein Modell eintragen. Sinnvoll ist ein
gemischtes Feld: ein guenstiges Modell fuer Scout und Curator, ein starkes fuer
Implementer und Reviewer. Wer es einfach mag, setzt ein Modell fuer alle:

```bash
export OPENROUTER_MODEL=<slug>
```

Beim Start prueft `run.js` die Slugs gegen die Live-Modellliste und schlaegt bei
Tippfehlern aehnliche Namen vor.

## Laufen lassen

```bash
node agents/run.js              # Probelauf: schreibt nur nach agents/out/
node agents/run.js --apply      # wendet den Patch auf die Dateien an
node agents/run.js --commit     # wendet an und committet lokal (pusht nicht)
```

Nuetzliche Optionen: `--budget=2.50` (Kostendeckel in USD),
`--max-reviews=3`, `--model=<slug>`, `--no-model-check`.

Fang mit Probelaeufen an. Erst wenn dir gefaellt, was in `agents/out/` landet,
schalte auf `--apply`.

## Warum das nicht endlos im Kreis laeuft

Der eigentliche Trick ist nicht die Schleife, sondern das **Gedaechtnis**.
`agents/state/backlog.json` (lesbar als `BACKLOG.md`) haelt fest, was erledigt
und was bewusst verworfen wurde. Der Scout bekommt diesen Verlauf und darf
nichts davon erneut vorschlagen. Ohne das schlaegt dir jeder frische Lauf zum
fuenften Mal dasselbe Refactoring vor.

Dazu kommen harte Grenzen. Ein Lauf endet **immer**, auf genau eine dieser
Arten:

- Der **Critic stoppt** - ausdruecklich erwuenscht, wenn nichts Sinnvolles
  offen ist. Ein Lauf, der nichts tut, ist besser als einer, der sich
  Beschaeftigung erfindet.
- Der **Reviewer lehnt** nach `maxReviewRounds` endgueltig ab. Das Vorhaben
  landet als "verworfen" im Backlog und kommt nicht wieder.
- Das **Budget** ist aufgebraucht. Dann wird nichts angewendet.
- Ein Agent haengt und erreicht sein Schritt-Limit.
- Die Datei `agents/STOP` existiert. Dann startet ueberhaupt kein Lauf.

Wiederholung ist bewusst **nicht** eingebaut. Ein Aufruf = ein Lauf. Wenn du
willst, dass es regelmaessig passiert, macht das cron oder launchd - siehe
unten. So kannst du es jederzeit abstellen, ohne einen Prozess zu jagen.

## Taeglich laufen lassen (macOS)

`~/Library/LaunchAgents/io.agar.bot.agents.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>              <string>io.agar.bot.agents</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/node</string>
    <string>/PFAD/ZU/Agar.io-bot/agents/run.js</string>
    <string>--commit</string>
    <string>--budget=1.00</string>
  </array>
  <key>WorkingDirectory</key>   <string>/PFAD/ZU/Agar.io-bot</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OPENROUTER_API_KEY</key> <string>sk-or-...</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key>    <string>/tmp/agar-agents.log</string>
  <key>StandardErrorPath</key>  <string>/tmp/agar-agents.err</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/io.agar.bot.agents.plist
```

Pfad zu `node` vorher mit `which node` pruefen. Abschalten:
`launchctl unload ...` oder einfach `touch agents/STOP`.

## Sicherungen

- Die Agenten duerfen nur Dateien aendern, die in `editablePaths` stehen.
  `.git/`, `agents/state/` und `agents/logs/` sind grundsaetzlich gesperrt.
- Jede Aenderung ist ein Suchen-Ersetzen-Paar, dessen Suchtext **genau einmal**
  in der Datei vorkommen muss. Passt er nicht mehr eindeutig, bricht der Lauf
  ab, bevor irgendetwas geschrieben wird.
- Ohne `--apply` wird nichts geschrieben. Ohne `--commit` wird nichts committet.
- Gepusht wird nie automatisch. Das bleibt deine Entscheidung.

## Die ehrliche Einschraenkung

Dieses Projekt hat keine Tests, keine CI und keinen Build - die Userscripts
laufen nur live im Browser gegen echte Gegner. Die Agenten koennen ihre
Aenderung also **nicht ausfuehren und nicht messen**. Sie arbeiten nach
Plausibilitaet, nicht nach Beweis.

Das ist in den Rollen-Prompts verankert (kleine, lokale Aenderungen; im Zweifel
die kleinere; Kosmetik ist ein Ablehnungsgrund), aber es bleibt eine echte
Grenze. Lies die Patches, bevor du sie mergst.

Der groesste Hebel fuer dieses Setup waere deshalb ein Messsignal: eine
Simulation, in der zwei `botList`-Strategien gegeneinander antreten und Masse
oder Ueberlebenszeit gemessen wird. Dann koennte der Reviewer eine Zahl
verlangen statt einer Begruendung.
