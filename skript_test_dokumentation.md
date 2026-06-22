# Testdokumentation der Hilfsskripte

## system_health.sh

### Ausführung
Das Skript wurde erfolgreich ausgeführt. Es prüft und zeigt an:
- Festplattenspeicher
- Speicherstatus
- Top 5 Prozesse nach Speichernutzung
- CPU-Auslastung
- Netzwerkschnittstellen
- Systemlaufzeit

### Ergebnis
- Ausgabe ist strukturiert und übersichtlich
- Alle erwarteten Systeminformationen werden angezeigt
- Statusmeldungen am Ende geben eine Zusammenfassung (OK/Warning/Critical)

## log_checker.sh

### Ausführung
Das Skript wurde erfolgreich ausgeführt. Es sucht und zählt:
- 'error'-Einträge
- 'warning'-Einträge
- 'failed'-Einträge

### Ergebnis
- Gibt die Anzahl der gefundenen Einträge pro Kategorie aus
- Zeigt die ersten fünf Treffer pro Kategorie
- Bietet am Ende eine Zusammenfassung und Empfehlungen für weiterführende Analysen

## Fazit
Beide Skripte funktionieren ordnungsgemäß und liefern nützliche Informationen zur Systemüberwachung. Sie sind für die tägliche Systemwartung geeignet und liefern klare, strukturierte Ausgaben.