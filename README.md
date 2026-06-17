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
Dieses Skript überwacht den Speicherzustand des Systems, einschließlich RAM, Swap und Inodes. Es zeigt detaillierte Informationen über die Speichernutzung und die speicherintensivsten Prozesse an.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Aktueller Speicherstatus (RAM) mit Gesamt-, Belegt- und Verfügbarem Speicher
- Top 5 Prozesse nach Speichernutzung
- Swap-Nutzung mit Details zur Swap-Datei
- Belegte Inodes im Root-Dateisystem

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
Dieses Skript überprüft den Status wichtiger Systemdienste (z.B. ssh, cron, systemd) und gibt eine Übersicht der aktiven/inaktiven Dienste aus - ohne Änderungen vorzunehmen.

### Aufrufparameter
Keine spezifischen Parameter erforderlich.

### Ausgabe
- Status der folgenden Dienste:
  - SSH-Service
  - Cron-Service
  - Systemd-Journald-Service
  - Systemd-Networkd-Service
  - Systemd-Resolved-Service
- Anzeige ob Dienste aktiv oder inaktiv sind
- Übersichtliche Darstellung des Dienstestatus

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