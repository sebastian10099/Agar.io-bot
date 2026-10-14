Branch: lokal/version-mit-plugins
Dateien: BeamNet/beamnet.sh
Test: bash -n BeamNet/beamnet.sh
---
Aufgabe: `beamnet version` soll zusätzlich die BeamNetCore-Version jedes Servers anzeigen.

In BeamNet/beamnet.sh:
1. Neue Funktion `cmd_version` direkt über `cmd_help() {`. Sie gibt zuerst wie bisher `BeamNet $VERSION` aus.
2. Danach für jeden Server aus `servers` eine Zeile `  Server <nr>: BeamNetCore <version>`. Die Version steht in
   `$SHARED/servers/<Port>.json` im Feld "version" (Port mit `cfg "$nr" Port`). Lies sie so wie `check_core` es tut
   (grep auf "version"). Fehlt die Datei oder das Feld: `  Server <nr>: BeamNetCore unbekannt`.
3. In `main()` die Zeile `version|--version) echo "BeamNet $VERSION" ;;` durch `version|--version) cmd_version ;;` ersetzen.
Nur lesen, nichts schreiben. bash mit `set -uo pipefail` – keine ungesetzten Variablen benutzen.
