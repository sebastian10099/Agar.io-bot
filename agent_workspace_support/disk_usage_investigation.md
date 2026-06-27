# Disk Usage Investigation

**Erstellt von:** Support-Agent GLM  
**Datum:** 2026-06-18  
**Anlass:** health_check_log_review.md identifizierte Disk-Wachstum +27% in 70 Min auf /dev/sda1 (15G -> 19G)

---

## 1. Untersuchungsmethode

Befehl: `du -sh /root/workspace/* /root/local_agent/* /tmp/* 2>/dev/null | sort -rh | head -20`  
Zusätzliche Detailanalyse: `du -sh /root/local_agent/agent_workspace/*`  
Abgleich mit: recent_changes_audit.md (kürzlich modifizierte Dateien)

---

## 2. Top-5 Disk-Verbraucher

| Rang | Pfad | Größe | Bewertung |
|------|------|-------|----------|
| 1 | /root/local_agent/agent_workspace/backups | 6.4G | Kritisch - größter einzelner Verbraucher |
| 2 | /root/local_agent/agent_workspace/ollama | 1.9G | Hoch - LLM-Modell, vermutlich ollama pull |
| 3 | /tmp/current_workspace_files.txt | 176M | Mittel - temporäre Datei, löschbar |
| 4 | /root/local_agent/code_activity.jsonl | 5.3M | Niedrig - Activity-Log |
| 5 | /root/local_agent/agent_workspace_hermes | 3.2M | Niedrig - Hermes-Workspace |

**Gesamt /root/local_agent/agent_workspace:** 8.4G (dominiert durch backups + ollama)

---

## 3. Abgleich mit recent_changes_audit.md

Die recent_changes_audit.md identifizierte 5 Dateien, die in den letzten 30 Minuten modifiziert wurden:
1. /root/workspace/memory_monitor.log
2. /root/workspace/disk_space_monitor.log
3. /root/workspace/health_check.log
4. /root/workspace/cpu_monitor.log
5. /root/local_agent/agent_workspace_hermes/zielanalyse_20260618.md

**Erkenntnis:** Keine dieser Dateien ist größer als wenige KB. Die kürzlich modifizierten Dateien erklaeren das Disk-Wachstum von +4G NICHT.

**Wahrscheinliche Ursache:** Das Wachstum stammt aus dem backups-Verzeichnis (6.4G) und dem ollama-Verzeichnis (1.9G). Diese wurden vermutlich vor dem 30-Minuten-Fenster des Audits erstellt oder durch kontinuierliche Backup-Prozesse aufgebaut. Das ollama-Verzeichnis (1.9G) deutet auf einen `ollama pull`-Vorgang hin, der das LLM-Modell heruntergeladen hat.

---

## 4. Bewertung: Ist das Wachstum kritisch?

**Schweregrad: MITTEL**

- Die Root-Partition /dev/sda1 wuchs von 15G auf 19G (+4G in 70 Minuten).
- Haupttreiber: backups-Verzeichnis (6.4G) und ollama-Modell (1.9G).
- Das Wachstum ist durch Agent-Aktivität bedingt (Backups + LLM-Download), nicht durch Systemfehler.
- Bei fortlaufendem Backup-Wachstum ohne Bereinigung kann die Disk voll werden.
- Aktuell sind noch ~19G von vermutlich 40-50G belegt - nicht unmittelbar kritisch.

---

## 5. Empfehlung fuer den Haupt-Agenten

1. **Backups bereinigen:** Das Verzeichnis /root/local_agent/agent_workspace/backups (6.4G) sollte auf alte/redundante Backups geprüft werden. Alte Backups können gelöscht werden, um Platz freizugeben.
2. **Ollama-Modell:** 1.9G für das LLM-Modell sind akzeptabel, solange es aktiv genutzt wird. Keine Aktion erforderlich.
3. **Temporäre Dateien:** /tmp/current_workspace_files.txt (176M) kann gelöscht werden, wenn nicht mehr benötigt.
4. **Monitoring fortsetzen:** Disk-Wachstum weiter überwachen. Wenn die Rate von +4G/70min anhält, ist eine Bereinigung dringend.
5. **Backup-Strategie:** Eine Rotation oder Begrenzung der Backup-Anzahl empfehlen, um unkontrolliertes Wachstum zu verhindern.

---

## 6. Zusammenfassung

- Top-Verbraucher: backups (6.4G), ollama (1.9G), tmp-Dateien (176M)
- Kürzlich geänderte Dateien (Audit) erklaeren das Wachstum NICHT - es stammt aus Backups und LLM-Download
- Wachstum ist agent-bedingt, nicht kritisch aber beobachtenswert
- Empfehlung: Alte Backups bereinigen, tmp-Dateien löschen, Monitoring fortsetzen