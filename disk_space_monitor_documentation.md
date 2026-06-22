## 24. disk_space_monitor.sh

### Verwendungszweck
Dieses Skript überwacht den Speicherplatz auf wichtigen Partitionen und warnt bei kritischen Schwellenwerten. Es prüft alle relevanten Partitionen und gibt entsprechende Warnungen bei Überschreitung der konfigurierten Schwellenwerte aus.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Statusmeldungen für jede Partition mit Belegungsprozentsatz
- WARNUNG bei Belegung über 80%
- KRITISCH bei Belegung über 90%
- OK-Meldung für Partitionen unter 80% Belegung (in Logs)
- Protokollierung aller Prüfungen in /var/log/disk_space_monitor.log

### Rueckgabewerte
- 0: Standard-Exit-Code (Skript beendet sich nach Ausführung)
- Das Skript gibt keine spezifischen Fehlercodes zurück, meldet Status aber über Ausgaben und Logs