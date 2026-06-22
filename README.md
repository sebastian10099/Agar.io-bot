# Hilfsskripte Übersicht

Dieses Verzeichnis enthält mehrere Hilfsskripte zur Systemüberwachung und Workspace-Analyse. Die folgenden Skripte sind verfügbar:

## 1. workspace_status.sh

### Verwendungszweck
Dieses Skript gibt einen Überblick über den aktuellen Workspace, einschließlich Dateianzahl und -größen.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Aktuelles Verzeichnis
- Verzeichnisliste mit Größenangaben
- Gesamtzahl der Dateien (einschließlich versteckter Dateien)
- Größte Dateien im Workspace
- Zusammenfassung mit Gesamtgröße des Workspaces und Gesamtzahl der Dateien

## 2. system_health.sh

### Verwendungszweck
Dieses Skript überwacht den Systemzustand und gibt Informationen über Speicher, Festplatte, CPU-Last und Netzwerk aus.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Verfügbare Festplattenkapazität
- Speicherstatus
- Top 5 Prozesse nach Speichernutzung
- CPU-Last
- Netzwerkschnittstellen
- Systemlaufzeit
- Zusammenfassung des Systemzustands mit Warnungen bei hoher Ressourcennutzung

## 3. log_checker.sh

### Verwendungszweck
Dieses Skript sucht nach Fehlermeldungen in den Systemlogs und zeigt eine Zusammenfassung der gefundenen Einträge an.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Anzahl der gefundenen Einträge für die Suchbegriffe 'error', 'warning' und 'failed'
- Beispiele für Log-Einträge zu jedem Suchbegriff
- Zusammenfassung der Trefferzahlen
- Empfehlungen zur weiteren Analyse

## 4. process_monitor.sh

### Verwendungszweck
Dieses Skript zeigt Echtzeit-Informationen über laufende Prozesse an.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Aktive Prozesse (Top 10 nach CPU-Nutzung)
- Prozessbaum
- Speicherintensive Prozesse (Top 5)
- Zusammenfassung mit Anzahl laufender Prozesse und Prozessen mit höchster CPU-/Speicherauslastung

## 5. disk_usage_monitor.sh

### Verwendungszweck
Dieses Skript überwacht den Festplattenverbrauch der Home- und Workspace-Verzeichnisse und warnt bei kritischen Schwellenwerten.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Belegung der Home- und Workspace-Verzeichnisse in absoluter Größe und Prozent
- Mountpoint-Übersicht mit Belegungsinformationen
- Warnungen bei Schwellenwertüberschreitung (80% Warnung, 90% Kritisch)
- Hinweise zur Systemkonfiguration

## 6. cleanup_report.sh

### Verwendungszweck
Dieses Skript identifiziert alte temporäre Dateien, große Dateien, Duplikate und leere Verzeichnisse als potenzielle Kandidaten für die Bereinigung. Es führt keine tatsächliche Löschung durch, sondern dient nur zur Information.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Liste temporärer Dateien, die älter als 7 Tage sind
- Liste großer Dateien (größer als 100MB)
- Liste doppelter Dateien (benötigt das Tool fdupes)
- Liste leerer Verzeichnisse
- Datumsstempel und Konfigurationsinformationen

## 7. file_permissions_check.sh

### Verwendungszweck
Dieses Skript überprüft Dateiberechtigungen im Workspace auf potenzielle Sicherheitsprobleme, ohne Änderungen vorzunehmen. Es identifiziert:
- Welt-beschreibbare Dateien (Sicherheitsrisiko)
- Welt-ausführbare Dateien (Information)
- Dateien ohne Besitzer oder Gruppe (Sicherheitsrisiko)
- Übermäßig restriktive Dateiberechtigungen (Information)

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Liste von Dateien mit potenziellen Sicherheitsproblemen
- Warnungen bei kritischen Berechtigungen
- Informationen über ungewöhnliche Berechtigungen
- Zusammenfassung der Überprüfung

## 8. memory_monitor.sh

### Verwendungszweck
Dieses Skript überwacht die RAM- und Swap-Auslastung des Systems und gibt entsprechende Warnungen bei kritischen Schwellenwerten aus. Es wertet die Prozentsätze der Belegung aus und gibt Statusmeldungen (OK, WARNING, CRITICAL) basierend auf vordefinierten Schwellenwerten aus.

### Aufrufparameter
- --test: Aktiviert den Testmodus mit simulierten Werten für RAM und Swap

### Ausgabe
- Aktueller RAM-Status mit Gesamt-, Belegt- und Verfügbarem Speicher
- Aktuelle Swap-Nutzung mit Gesamt-, Belegt- und Verfügbarem Speicher
- Prozentuale Auslastung von RAM und Swap
- Statusmeldung (OK, WARNING, CRITICAL) basierend auf Schwellenwerten:
  - RAM: 80% = WARNING, 90% = CRITICAL
  - Swap: 60% = WARNING, 80% = CRITICAL
- Empfehlungen bei WARNING/CRITICAL-Zuständen

### Rueckgabewerte
- 0: Alles OK (RAM < 80%, Swap < 60%)
- 1: WARNING (RAM >= 80% oder Swap >= 60%)
- 2: CRITICAL (RAM >= 90% oder Swap >= 80%)

## 9. memory_usage.sh

### Verwendungszweck
Dieses Skript überwacht die Speicher-/RAM-Auslastung und zeigt verwendeten/freien Speicher, Swap-Nutzung und Top-Prozesse nach Speicherverbrauch an.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- RAM-Auslastung mit Gesamt-, Belegt- und Verfügbarem Speicher
- Swap-Nutzung mit Details zur Auslagerungsdatei
- Top 5 Prozesse nach Speicherverbrauch
- Zusammenfassung mit prozentualer Auslastung von RAM und Swap

## 10. log_analyzer.sh

### Verwendungszweck
Dieses Skript analysiert Log-Dateien im 'logs'-Verzeichnis und zählt die Anzahl der Einträge pro Tag.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Anzahl der Log-Einträge gruppiert nach Datum für jede Log-Datei im 'logs'-Verzeichnis
- Fehlermeldung, falls das 'logs'-Verzeichnis nicht existiert

## 11. service_status.sh

### Verwendungszweck
Dieses Skript überprüft den Status wichtiger Systemdienste und gibt eine Übersicht der aktiven/inaktiven Dienste aus - ohne Änderungen vorzunehmen.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Status der folgenden Dienste:
  - SSH-Service
  - Cron-Service
  - Systemd-Journald-Service
- Anzeige ob Dienste aktiv oder inaktiv sind
- Übersichtliche Darstellung des Dienstestatus

### Rueckgabewerte
- 0: Alle überwachten Dienste sind aktiv
- 1: Mindestens ein Dienst ist inaktiv

## 12. network_status.sh

### Verwendungszweck
Dieses Skript überprüft den Netzwerkstatus und gibt detaillierte Informationen über Netzwerkschnittstellen, offene Ports, aktive Verbindungen, Routing und DNS-Server aus.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Liste der aktiven Netzwerkschnittstellen mit IP-Adressen
- Übersicht der offenen Ports (Listening)
- Aktive Netzwerkverbindungen
- Routing-Tabelle
- DNS-Server Konfiguration
- Netzwerkstatistik (Pakete)
- Zusammenfassung der Netzwerkaktivitäten

## 13. workspace_backup.sh

### Verwendungszweck
Dieses Skript erstellt ein Backup wichtiger Workspace-Dateien (.sh-Dateien und README.md) in ein Zeitstempel-Verzeichnis unter 'backups/'.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Pfad zum erstellten Backup-Verzeichnis
- Bestätigung bei erfolgreichem Backup
- Fehlermeldung wenn keine Dateien zum Sichern gefunden wurden

### Rueckgabewerte
- 0: Backup erfolgreich erstellt
- 1: Keine Dateien zum Sichern gefunden

## 14. workspace_analyzer.sh

### Verwendungszweck
Dieses Skript analysiert den Speicherverbrauch im Workspace und zeigt die 10 größten Dateien/Verzeichnisse an. Es hilft bei der Identifikation von Speicherfressern bei kritischer Festplattenbelegung.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Liste der 10 größten Dateien und Verzeichnisse im Workspace mit Größenangaben
- Zusammenfassung der Analyse

## 15. memory_check.sh

### Verwendungszweck
Dieses Skript überwacht die Arbeitsspeicher-Auslastung und gibt Warnungen bei hoher Nutzung aus.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Aktueller Speicherstatus mit Gesamt-, Belegt-Speicher und prozentualer Auslastung
- Warnung bei Speicherauslastung über 80%
- Bestätigung bei normaler Speicherauslastung

## 16. disk_usage_alert.sh

### Verwendungszweck
Dieses Skript überwacht die Festplattenbelegung und gibt Warnungen bei Überschreitung vordefinierter Schwellenwerte aus. Es warnt bei Belegung über 80% (Warnung) und 90% (kritisch).

### Aufrufparameter
- --test: Aktiviert den Testmodus mit simulierten Partitionen

### Ausgabe
- Statusmeldungen für jede Partition mit Belegungsprozentsatz
- WARNUNG bei Belegung über 80%
- KRITISCH bei Belegung über 90%
- OK-Meldung für Partitionen unter 80% Belegung (nur im Testmodus sichtbar)

### Rueckgabewerte
- 0: Alle Partitionen unter 80% Belegung
- 1: Mindestens eine Partition zwischen 80% und 90% Belegung
- 2: Mindestens eine Partition über 90% Belegung

## 17. cpu_monitor.sh

### Verwendungszweck
Dieses Skript überwacht die CPU-Auslastung des Systems und gibt entsprechende Warnungen bei kritischen Schwellenwerten aus. Es wertet die Prozentsätze der Belegung aus und gibt Statusmeldungen (OK, WARNING, CRITICAL) basierend auf vordefinierten Schwellenwerten aus.

### Aufrufparameter
- --test: Aktiviert den Testmodus mit simulierten Werten für die CPU-Auslastung

### Ausgabe
- Aktuelle CPU-Auslastung in Prozent
- Statusmeldung (OK, WARNING, CRITICAL) basierend auf Schwellenwerten:
  - CPU: 70% = WARNING, 85% = CRITICAL
- Empfehlungen bei WARNING/CRITICAL-Zuständen

### Rueckgabewerte
- 0: Alles OK (CPU < 70%)
- 1: WARNING (CPU >= 70%)
- 2: CRITICAL (CPU >= 85%)

## 18. health_check.sh

### Verwendungszweck
Dieses Skript führt eine umfassende Systemgesundheitsprüfung durch, indem es nacheinander die folgenden vier Monitor-Skripte ausführt:
- disk_usage_alert.sh (Festplattenspeicher)
- memory_monitor.sh (RAM und Swap)
- cpu_monitor.sh (CPU-Auslastung)
- process_monitor.sh (Prozessüberwachung)

Das Skript erstellt einen zusammenfassenden Bericht aller Überprüfungen und zeigt detaillierte Informationen zu jeder Komponente an.

### Aufrufparameter
- --test: Aktiviert den Testmodus für alle vier enthaltenen Skripte mit simulierten Werten

### Ausgabe
- Übersichtlicher Gesundheitsbericht mit Zeitstempel
- Detaillierte Ergebnisse der Festplattenüberprüfung
- Detaillierte Ergebnisse der Speicherüberprüfung
- Detaillierte Ergebnisse der CPU-Auslastung
- Detaillierte Ergebnisse der Prozessüberwachung
- Abschließende Zusammenfassung des Systemzustands

### Rueckgabewerte
- 0: Skript erfolgreich ausgeführt (unabhängig von den einzelnen Testergebnissen)
- 124: Timeout bei der Ausführung eines der enthaltenen Skripte (wird nach 30 Sekunden abgebrochen)

## 19. process_monitor.sh

### Verwendungszweck
Dieses Skript überwacht die Anzahl laufender Prozesse und erkennt Zombie-Prozesse. Es gibt Warnungen aus, wenn ungewöhnlich viele Prozesse oder Zombie-Prozesse erkannt werden.

### Aufrufparameter
- --test: Aktiviert den Testmodus mit simulierten Werten
- --max-processes [ZAHL]: Legt die maximale Anzahl erlaubter Prozesse fest (Standard: 500)
- --max-zombies [ZAHL]: Legt die maximale Anzahl erlaubter Zombie-Prozesse fest (Standard: 5)

### Ausgabe
- Aktuelle Anzahl laufender Prozesse
- Aktuelle Anzahl Zombie-Prozesse
- Statusmeldung (OK, WARNING, CRITICAL) basierend auf Schwellenwerten:
  - WARNING: Anzahl Prozesse über dem festgelegten Limit
  - CRITICAL: Anzahl Zombie-Prozesse über dem festgelegten Limit
- Performance-Daten im Format: processes=aktuell;;max zombies=aktuell;;max

### Rueckgabewerte
- 0: Alles OK (Prozesse und Zombies unter den Limits)
- 1: WARNING (Zu viele Prozesse)
- 2: CRITICAL (Zu viele Zombie-Prozesse)

## 20. log_error_check.sh

### Verwendungszweck
Dieses Skript durchsucht System-Logs auf Fehler und Warnungen und gibt eine Zusammenfassung aus. Es ergänzt die bestehenden Monitor-Skripte um eine Log-Analyse-Ebene.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Analyse der folgenden Log-Dateien:
  - /var/log/syslog
  - /var/log/kern.log
  - /var/log/dmesg
  - /var/log/auth.log
- Anzahl gefundener Fehler und Warnungen pro Log-Datei
- Beispiele für gefundene Fehler/Warnungen
- Gesamtzusammenfassung aller Fehler und Warnungen
- Farbliche Darstellung (Rot=ERROR, Gelb=WARNING, Grün=OK)

### Rueckgabewerte
- 0: Keine Fehler oder Warnungen gefunden
- 1: Warnungen gefunden
- 2: Fehler gefunden

## 21. security_audit.sh

### Verwendungszweck
Dieses Skript analysiert fehlgeschlagene SSH-Login-Versuche aus den Auth-Logs und gibt eine Zusammenfassung potenzieller Sicherheitsrisiken. Es ergänzt die bestehenden Monitor-Skripte um eine Sicherheits-Ebene im erlaubten Bereich.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Analyse der /var/log/auth.log auf SSH-Login-Fehler
- Zählung verschiedener Arten von fehlgeschlagenen SSH-Logins:
  - Failed Password Attempts
  - Invalid User Attempts
  - Failed Public Key Attempts
  - Connection Refused
- Gesamtzahl der fehlgeschlagenen SSH-Login-Versuche
- Sicherheitsbewertung (LOW/MEDIUM/HIGH)
- Empfehlungen basierend auf der Sicherheitsbewertung

### Rueckgabewerte
- 0: LOW Security Risk (0-10 fehlgeschlagene Logins)
- 1: MEDIUM Security Risk (11-100 fehlgeschlagene Logins)
- 2: HIGH Security Risk (über 100 fehlgeschlagene Logins)

## 22. backup_cleanup.sh

### Verwendungszweck
Dieses Skript löscht Backup-Verzeichnisse im 'backups/'-Verzeichnis, die älter als 7 Tage sind. Es dient zur automatisierten Bereinigung alter Backups und verhindert so eine Überlastung des Speichers durch alte Sicherungen.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Meldung über die Suche nach alten Backup-Verzeichnissen
- Anzahl gefundener alter Backup-Verzeichnisse
- Liste der gelöschten Verzeichnisse
- Bestätigung bei erfolgreichem Abschluss der Bereinigung
- Fehlermeldung wenn das Backup-Verzeichnis nicht existiert

### Rueckgabewerte
- 0: Bereinigung erfolgreich abgeschlossen oder keine alten Backups gefunden
- 1: Backup-Verzeichnis nicht gefunden

## 23. unified_report.sh

### Verwendungszweck
Dieses Skript führt eine Kombination mehrerer Monitor-Skripte aus und generiert einen zusammenfassenden Gesamtbericht. Es führt nacheinander health_check.sh, security_audit.sh und service_status.sh aus und speichert die Ergebnisse in einer Zeitstempel-Datei.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Erstellung einer kombinierten Berichtsdatei mit Zeitstempel im Dateinamen
- Ausführung und Integration der Ergebnisse von:
  - health_check.sh (Systemgesundheitsprüfung)
  - security_audit.sh (Sicherheitsanalyse)
  - service_status.sh (Dienststatus-Überprüfung)
- Anzeige des Pfades zur erstellten Berichtsdatei

### Rueckgabewerte
- 0: Unified Report erfolgreich erstellt## 24. disk_space_monitor.sh

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

## 25. process_monitor.sh

### Verwendungszweck
Dieses Skript überwacht CPU- und RAM-Auslastung von Prozessen und gibt Warnungen bei Überschreitung konfigurierbarer Schwellenwerte aus. Es ergänzt die bestehenden Monitor-Skripte um eine Prozess-Ebene und folgt dem bewährten Erstellungs-Muster im erlaubten Bereich.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Warnungen bei hoher CPU-Auslastung pro Prozess (Standard: >80%)
- Warnungen bei hoher RAM-Auslastung pro Prozess (Standard: >80%)
- Liste betroffener Prozesse mit PID, PPID, Befehl und Auslastungswerten

### Rueckgabewerte
- 0: Skript erfolgreich ausgeführt

## 26. log_monitor.sh

### Verwendungszweck
Dieses Skript überwacht System-Logs auf Fehler und Warnungen und gibt entsprechende Warnungen bei Überschreitung konfigurierbarer Schwellenwerte aus. Es analysiert mehrere Log-Dateien nach vordefinierten Schlüsselwörtern und bewertet die Systemgesundheit basierend auf der Anzahl der gefundenen Einträge.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Anzahl der gefundenen Fehler und Warnungen pro Log-Datei
- Zusammenfassung der Gesamtfehler und -warnungen
- Statusmeldung (OK, WARNING, CRITICAL) basierend auf Schwellenwerten:
  - Fehler: >10 = CRITICAL
  - Warnungen: >50 = WARNING
- Protokollierung der Analyseergebnisse

### Rueckgabewerte
- 0: Keine Fehler oder Warnungen gefunden bzw. unter den Schwellenwerten
- 1: Warnungen gefunden (Anzahl Warnungen > 50)
- 2: Fehler gefunden (Anzahl Fehler > 10)

## 27. master_monitor.sh

### Verwendungszweck
Dieses Skript führt eine zentrale Überwachung durch, indem es nacheinander die folgenden drei Monitor-Skripte ausführt:
- process_monitor.sh (Prozessüberwachung)
- log_monitor.sh (Log-Analyse)
- disk_usage_monitor.sh (Festplattennutzung)

Das Skript erstellt einen zusammenfassenden Bericht aller Überprüfungen und zeigt detaillierte Informationen zu jeder Komponente an.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Übersichtliche Ausgabe der Ergebnisse aller drei enthaltenen Skripte
- Klare Trennung der einzelnen Überwachungsbereiche
- Abschließende Trennung zur Markierung des Skript-Endes

### Rueckgabewerte
- 0: Skript erfolgreich ausgeführt (unabhängig von den einzelnen Testergebnissen)

## 28. backup_scripts.sh

### Verwendungszweck
Dieses Skript sichert alle wichtigen Skripte (.sh-Dateien) und Dokumentationsdateien (.md-Dateien) im Workspace in ein Zeitstempel-Archiv. Es dient zur Sicherung der Arbeitsinfrastruktur und ist eine nützliche Wartungsfunktion im erlaubten Bereich.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Pfad zum erstellten Backup-Archiv (.tar.gz)
- Bestätigung bei erfolgreichem Backup
- Fehlermeldung wenn das Archiv nicht erstellt werden konnte

### Rueckgabewerte
- 0: Backup erfolgreich erstellt
- 1: Fehler beim Erstellen des Backups

## 29. auth_log_summary.sh

### Verwendungszweck
Dieses Skript analysiert wiederkehrende Fehlermuster in /var/log/auth.log und gibt eine Zusammenfassung der häufigsten Fehlerquellen aus. Es identifiziert fehlgeschlagene SSH-Anmeldeversuche, ungültige Benutzer und IP-Adressen mit vielen Fehlversuchen.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Liste der häufigsten fehlgeschlagenen SSH-Anmeldeversuche (Top 10 Benutzer)
- Liste der häufigsten ungültigen Benutzer (Top 10 Benutzer)
- Liste der IP-Adressen mit den meisten Fehlversuchen (Top 10 IPs)
- Anzahl der Verbindungsabbrüche (Connection closed/dropped)
- Zusammenfassender Bericht über die Auth-Log-Aktivitäten

### Rueckgabewerte
- 0: Skript erfolgreich ausgeführt