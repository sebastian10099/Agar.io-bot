# Gedächtnis-Notiz: Überblick über erstellte Skripte

## 1. health_check.sh

### Funktion
Führt eine umfassende Systemgesundheitsprüfung durch, indem es folgende Skripte ausführt:
- disk_usage_alert.sh (Festplattenspeicher)
- memory_monitor.sh (RAM und Swap)
- cpu_monitor.sh (CPU-Auslastung)
- process_monitor.sh (Prozessüberwachung)

### Integration
Dies ist das zentrale Überwachungsskript, das alle anderen Überwachungsskripte zusammenfasst.

### Rückgabewerte
- 0: Skript erfolgreich ausgeführt
- 124: Timeout bei der Ausführung eines der enthaltenen Skripte

## 2. security_audit.sh

### Funktion
Analysiert fehlgeschlagene SSH-Login-Versuche aus den Auth-Logs und gibt eine Zusammenfassung potenzieller Sicherheitsrisiken.

### Integration
Ergänzt die bestehenden Monitor-Skripte um eine Sicherheits-Ebene.

### Rückgabewerte
- 0: LOW Security Risk (0-10 fehlgeschlagene Logins)
- 1: MEDIUM Security Risk (11-100 fehlgeschlagene Logins)
- 2: HIGH Security Risk (über 100 fehlgeschlagene Logins)

## 3. workspace_backup.sh

### Funktion
Erstellt ein Backup wichtiger Workspace-Dateien (.sh-Dateien und README.md) in ein Zeitstempel-Verzeichnis unter 'backups/'.

### Integration
Wird vom health_check.sh aufgerufen, um regelmäßige Backups zu gewährleisten.

### Rückgabewerte
- 0: Backup erfolgreich erstellt
- 1: Keine Dateien zum Sichern gefunden

## 4. backup_cleanup.sh

### Funktion
Löscht Backup-Verzeichnisse im 'backups/'-Verzeichnis, die älter als 7 Tage sind.

### Integration
Automatisierte Bereinigung alter Backups zur Verhinderung von Speicherüberlastung.

### Rückgabewerte
- 0: Bereinigung erfolgreich abgeschlossen oder keine alten Backups gefunden
- 1: Backup-Verzeichnis nicht gefunden

## 5. service_status.sh

### Funktion
Überprüft den Status wichtiger Systemdienste (SSH, Cron, Systemd-Journald) und gibt eine Übersicht der aktiven/inaktiven Dienste aus.

### Integration
Wird vom health_check.sh aufgerufen, um den Dienstestatus zu überwachen.

### Rückgabewerte
- 0: Alle überwachten Dienste sind aktiv
- 1: Mindestens ein Dienst ist inaktiv

## 6. unified_report.sh

### Funktion
Erstellt einen umfassenden Systembericht durch Integration der Ergebnisse aus health_check.sh, security_audit.sh und service_status.sh. Gibt eine strukturierte Zusammenfassung aller Systemaspekte aus.

### Integration
Zentrales Reporting-Skript, das die Ergebnisse aller Monitor-Skripte zusammenfasst.

### Rückgabewerte
- 0: Bericht erfolgreich erstellt und ausgegeben
- 1: Fehler bei der Ausführung eines der enthaltenen Skripte

## 7. disk_space_monitor.sh

### Funktion
Prüft den verfügbaren Speicherplatz auf wichtigen Partitionen und warnt bei Überschreitung konfigurierbarer Schwellenwerte (Standard: WARNUNG bei 80%, KRITISCH bei 90%).

### Integration
Ergänzt die bestehenden Monitor-Skripte um eine Storage-Ebene.

### Rückgabewerte
- 0: Prüfung erfolgreich abgeschlossen, keine kritischen Schwellen überschritten
- 1: Mindestens eine Partition hat kritische Schwellen überschritten
- 2: Mindestens eine Partition hat Warnschwellen überschritten

## 8. process_monitor.sh

### Funktion
Überwacht die CPU- und RAM-Auslastung aller laufenden Prozesse und gibt Warnungen für Prozesse aus, die die konfigurierten Schwellenwerte überschreiten.

### Integration
Ergänzt die bestehenden Monitor-Skripte um eine Prozess-Ebene. Wird vom health_check.sh aufgerufen.

### Rückgabewerte
- 0: Prüfung erfolgreich abgeschlossen, keine auffälligen Prozesse gefunden
- 1: Mindestens ein Prozess überschreitet die CPU-Schwellenwerte
- 2: Mindestens ein Prozess überschreitet die RAM-Schwellenwerte

### Testprotokoll
- Test 1: Normale Schwellwerte (80%) - keine Warnungen ausgegeben (erwartetes Verhalten)
- Test 2: Niedrige Schwellwerte (1%) - korrekte Warnung für Prozess mit hoher CPU-Auslastung ausgegeben
- Test 3: Schwellwerte auf 80% zurückgesetzt - Bestätigung der normalen Funktionsweise

## 9. log_monitor.sh

### Funktion
Überwacht System-Logs auf Fehler und Warnungen, indem es bestimmte Schlüsselwörter in den Log-Dateien sucht und deren Vorkommen zählt. Es unterscheidet zwischen Fehlern (error, crit, alert, emerg) und Warnungen (warning, fail) und wertet diese gegen konfigurierbare Schwellenwerte aus.

### Integration
Ergänzt die bestehenden Monitor-Skripte um eine Log-Analyse-Ebene.

### Rückgabewerte
- 0: Prüfung erfolgreich abgeschlossen, keine kritischen Fehler oder Warnungen gefunden
- 1: Warnungsschwellen überschritten (zu viele Warnungen)
- 2: Kritische Fehlerschwellen überschritten (zu viele Fehler)

### Testprotokoll
- Test 1: Normale Schwellwerte - kritische Fehler gefunden (33 Fehler, 127 Warnungen), Skript gibt korrekten Fehlercode 2 aus

## 10. disk_usage_monitor.sh

### Funktion
Überwacht die Belegung aller Partitionen und gibt eine Warnung aus, wenn die Belegung einen konfigurierbaren Schwellenwert (standardmäßig 80%) überschreitet. Es werden nur diejenigen Partitionen angezeigt, die den Schwellenwert überschreiten.

### Integration
Ergänzt die bestehenden Monitor-Skripte um eine Festplattennutzungs-Ebene. Kann eigenständig oder als Teil des master_monitor.sh ausgeführt werden.

### Rückgabewerte
- 0: Prüfung erfolgreich abgeschlossen. Es werden keine Rückgabecodes für Warnungen verwendet, da die Ausgabe direkt erfolgt.

## 11. master_monitor.sh

### Funktion
Führt eine Sammlung von Monitor-Skripten aus (process_monitor.sh, log_monitor.sh, disk_usage_monitor.sh) und fasst deren Ergebnisse in einer strukturierten Ausgabe zusammen. Dient als zentrale Instanz für die Systemüberwachung.

### Integration
Zentrales Master-Skript, das andere Monitor-Skripte aufruft und deren Ausgaben aggregiert. Vereinfacht die Überwachung durch einen einzigen Aufrufpunkt.

### Rückgabewerte
- 0: Master-Monitor erfolgreich ausgeführt. Die Rückgabewerte der einzelnen Skripte werden nicht weitergeleitet, sondern deren Ausgaben direkt angezeigt.

## 12. process_monitor.sh (neue Version)

### Funktion
Überwacht die CPU- und RAM-Auslastung aller laufenden Prozesse und gibt Warnungen für Prozesse aus, die die konfigurierten Schwellenwerte überschreiten (Standard: CPU 80%, RAM 80%).

### Integration
Ergänzt die bestehenden Monitor-Skripte um eine Prozess-Ebene. Kann eigenständig oder als Teil des master_monitor.sh ausgeführt werden.

### Rückgabewerte
- 0: Prüfung erfolgreich abgeschlossen, keine auffälligen Prozesse gefunden
- 1: Mindestens ein Prozess überschreitet die CPU-Schwellenwerte
- 2: Mindestens ein Prozess überschreitet die RAM-Schwellenwerte

## 13. backup_scripts.sh

### Funktion
Sichert alle wichtigen Skripte (.sh-Dateien) und Dokumentationsdateien (.md-Dateien) im Workspace in ein Zeitstempel-Archiv. Dient zur Sicherung der Arbeitsinfrastruktur und ist eine nützliche Wartungsfunktion im erlaubten Bereich.

### Integration
Ergänzt die bestehenden Skripte um eine Backup-Funktion für die gesamte Arbeitsumgebung.

### Rückgabewerte
- 0: Backup erfolgreich erstellt
- 1: Fehler beim Erstellen des Backups

## 14. System-Monitor Bericht

### Funktion
Dokumentiert die Ergebnisse der regelmäßigen Systemprüfung mit dem Master-Monitor.

### Integration
Dient als Protokoll der durchgeführten Systemgesundheitsprüfung und enthält detaillierte Ergebnisse sowie Empfehlungen für notwendige Maßnahmen.

### Inhalt
- Zusammenfassung der Systemprüfung
- Detaillierte Ergebnisse der einzelnen Monitore (Prozess-Monitor, Log-Monitor, Festplatten-Nutzung-Monitor)
- Empfehlungen für notwendige Maßnahmen