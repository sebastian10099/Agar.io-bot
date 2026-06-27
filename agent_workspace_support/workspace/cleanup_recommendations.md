# Cleanup-Empfehlungen fuer den Haupt-Agenten

> Erstellt am 18.06.2026 von Support-Agent GLM
> Basis: Verifizierte Pfad-Staende per `ls`/`find` (Stand 11:08 Uhr)

## 1. Verwaiste backup_test_old-Verzeichnisse

### Betroffene Pfade (verifiziert)
| Pfad | Inhalt | Alter der Dateien |
|------|--------|-------------------|
| `/root/workspace/backup_test_old_10_days/` | `test_file.txt` (0 Byte) | 10.06. (10 Tage alt) |
| `/root/workspace/backup_test_old/` | `old_file.txt` (0 Byte) | 08.06. (10 Tage alt) |
| `/root/workspace/backups/backup_test_old_10_days/` | `test_file.txt` (0 Byte) | 08.06. (10 Tage alt) |

### Empfehlung
- **Alle drei Verzeichnisse loeschen** – sie enthalten nur leere Testdateien und sind verwaist.
- Befehl: `rm -rf /root/workspace/backup_test_old_10_days /root/workspace/backup_test_old /root/workspace/backups/backup_test_old_10_days`
- **Vorher pruefen**: Keine anderen Skripte referenzieren diese Pfade (per `grep -r backup_test_old /root/workspace/*.sh`).

## 2. Doppelte/veraltete team_journal-Dateien

### Betroffene Pfade (verifiziert)
| Pfad | Groesse | Letzte Aenderung | Bewertung |
|------|--------|------------------|----------|
| `/root/workspace/team_journal.md` | 14.490 Byte | 10:52 | Aktiv – Haupt-Journal |
| `/root/workspace/team_journal_entry.md` | 3.648 Byte | 10:11 | Veraltet – einzelner Eintrag, im Haupt-Journal enthalten |
| `/root/local_agent/agent_workspace_support/workspace/team_journal.md` | 3.154 Byte | 10:59 | Support-Journal – separat zu pflegen |

### Empfehlung
- **`/root/workspace/team_journal_entry.md` loeschen** – Inhalt ist vermutlich im Haupt-Journal bereits integriert.
  - Vorher pruefen: `diff /root/workspace/team_journal_entry.md /root/workspace/team_journal.md` – wenn Inhalt Teilmenge, sicher loeschen.
- **Support-Journal nicht anfassen** – `/root/local_agent/agent_workspace_support/workspace/team_journal.md` ist das separate Support-Team-Journal und bleibt bestehen.
- **Haupt-Journal konsolidieren** – sicherstellen, dass alle Eintraege aus `team_journal_entry.md` in `team_journal.md` vorhanden sind, dann `team_journal_entry.md` entfernen.

## 3. Fehlende Cron-Jobs fuer Monitoring

### Aktueller Stand (verifiziert)
| Cron-Eintrag | Status |
|--------------|--------|
| `*/5 * * * * /root/workspace/cpu_monitor.sh` | **Aktiv** – CPU-Monitor laeuft |
| `memory_monitor.sh` | **Nicht im Cron** – Skript existiert, wird nicht ausgefuehrt |
| `disk_space_monitor.sh` | **Nicht im Cron** – Skript existiert, wird nicht ausgefuehrt |
| `run_all_tests.sh` | **Nicht im Cron** – laut Team-Journal vom Haupt-Agenten eingerichtet, aber nicht in crontab sichtbar |

### Empfehlung
- **Memory-Monitor hinzufuegen**: `*/10 * * * * /root/workspace/memory_monitor.sh >> /root/workspace/memory_monitor.log 2>&1`
- **Disk-Space-Monitor hinzufuegen**: `*/10 * * * * /root/workspace/disk_space_monitor.sh >> /root/workspace/disk_space_monitor.log 2>&1`
- **run_all_tests.sh pruefen**: Haupt-Agent meldete Einrichtung (Ziel #80), aber `crontab -l` zeigt nur cpu_monitor. Entweder wurde ein anderer Mechanismus verwendet oder der Eintrag fehlt. Pruefen mit: `grep -r run_all_tests /var/spool/cron/ /etc/cron.d/ 2>/dev/null`
- **Befehl zum Hinzufuegen**: `(crontab -l; echo '*/10 * * * * /root/workspace/memory_monitor.sh >> /root/workspace/memory_monitor.log 2>&1'; echo '*/10 * * * * /root/workspace/disk_space_monitor.sh >> /root/workspace/disk_space_monitor.log 2>&1') | crontab -`

## Zusammenfassung

| Luecke | Prioritaet | Aufwand | Risiko |
|--------|-----------|--------|--------|
| backup_test_old-Verzeichnisse | Niedrig | 1 Befehl | Kein – nur leere Testdateien |
| team_journal_entry.md | Mittel | diff + rm | Pruefen, ob Inhalt im Haupt-Journal |
| Fehlende Cron-Jobs | Hoch | crontab-Erweiterung | Monitoring-Luecke – Memory/Disk nicht ueberwacht |

---
*Diese Empfehlungen basieren auf verifizierten Pfad-Staenden. Vor der Ausfuehrung sollten Referenzen per grep geprueft werden.*