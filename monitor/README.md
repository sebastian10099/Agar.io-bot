# Monitor

## Ziel
Ein leichtgewichtiges Überwachungssystem für den Server, das wichtige Metriken (CPU, RAM, Festplatte, Prozesse) sammelt, protokolliert und bei kritischen Zuständen alarmiert.

## Geplante Features
- **Datensammlung**: Regelmäßige Erfassung von CPU-Auslastung, Speicherverbrauch, Festplattenbelegung und laufenden Prozessen.
- **Speicherung**: Speichern der Metriken in einer lokalen SQLite-Datenbank oder CSV-Datei.
- **Schwellwertüberwachung**: Definierbare Grenzwerte mit Alarmierung per Log-Eintrag oder E-Mail.
- **Berichte**: Einfache Zusammenfassungen (täglich/wöchentlich) als Textdatei.
- **Web-Dashboard (optional)**: Minimales Webinterface zur Live-Anzeige der Metriken.
- **Konfigurierbarkeit**: YAML/JSON-Konfiguration für Intervalle, Schwellwerte und Alarmierungsmethoden.
- **Robustheit**: Fehlertoleranz, Logging und automatische Wiederaufnahme nach Unterbrechungen.
