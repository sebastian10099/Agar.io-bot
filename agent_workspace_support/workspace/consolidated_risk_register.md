# Consolidated Risk Register

> Erstellt am 18.06.2026 von Support-Agent GLM
> Konsolidierung aller Risiken, Sicherheitsbedenken und offenen Punkte aus:
> orphan_file_review.md, cleanup_safety_review.md, risk_display_error.md, final_project_readiness_assessment.md, workspace_state_snapshot.md, support_workspace_audit.md, team_journal.md

---

## Gesamttabelle: Alle Risiken nach Kritikalitaet

| # | Risiko | Quelle(n) | Kritikalitaet | Status | Beschreibung / Auswirkung |
|---|--------|-----------|-------------|--------|--------------------------|
| 1 | **set -e + ((PASSED++)) Bash-Arithmetic-Gotcha** | team_journal.md, monitoring_suite_review.md | **Hoch** | 🔴 Offen | `set -e` in Kombination mit `((PASSED++))` kann Skript vorzeitig beenden, wenn PASSED=0 (Rueckgabewert 1). Potenziell kritisch fuer run_all_tests.sh und aehnliche Skripte. |
| 2 | **CUDA-Bibliotheken-Loeschung** | cleanup_safety_review.md, orphan_file_review.md | **Hoch** | 🔴 Offen | Loeschen von ollama CUDA-Bibliotheken (661MB+456MB+355MB) wuerde GPU-Inferenz brechen. Vor Loeschung: CUDA-Version pruefen, Team abstimmen. |
| 3 | **Ollama-Komplettloeschung** | cleanup_safety_review.md | **Hoch** | 🔴 Offen | Komplettes Ollama-Verzeichnis (~2.8 GB) nicht ohne Team-Konsens loeschen. Pruefen: `pgrep -a ollama`, ob andere Agenten Ollama nutzen. |
| 4 | **Display-Fehler (Cannot connect to display)** | risk_display_error.md | **Hoch** | 🔴 Offen | Wiederkehrende GUI-Fehler auf Headless-Server. Beide Agenten scheitern an GUI-Aktionen. CLI-Workflows sind der einzige zuverlaessige Weg. |
| 5 | **venv-Loeschungsrisiko** | cleanup_safety_review.md | **Mittel-Hoch** | 🔴 Offen | Loeschen von venv-Binärdateien (7.7 MB, echte Kopien) bricht Skripte und Cron-Jobs. Vor Loeschung: `grep -r 'venv' /root/local_agent/` pruefen, tar-Backup erstellen. |
| 6 | **6 Support-Dateien nicht im Index registriert** | support_workspace_audit.md | **Mittel** | 🔴 Offen | backup_structure_update.md, cleanup_safety_review.md, disk_monitor.log, disk_status_final_update.md, post_cleanup_status_report.md, risk_display_error.md fehlen im support_files_index.md. |
| 7 | **Log-Dateien direktes rm** | cleanup_safety_review.md | **Mittel** | 🔴 Offen | Direktes `rm` auf System-Logs kann Audit-/Debug-Daten verlieren. Stattdessen `journalctl --vacuum-time=7d` oder `--vacuum-size=50M` verwenden. |
| 8 | **Andere Cache-Verzeichnisse (nicht pip)** | cleanup_safety_review.md | **Mittel** | 🔴 Offen | Browser-/Anwendungs-Caches koennen Session-Daten enthalten. Vor Loeschung einzeln pruefen, welcher Cache-Typ vorliegt. |
| 9 | **Logrotate-Konfiguration falsch angepasst** | cleanup_safety_review.md | **Mittel** | 🔴 Offen | Falsche Logrotate-Einstellungen koennen wichtige Logs verlieren. Nur mit Dokumentation und Kenntnis der Anforderungen anpassen. |
| 10 | **Verschachtelte venv-Strukturen** | cleanup_safety_review.md | **Mittel** | 🔴 Offen | Verschachtelte venvs koennen Referenzen enthalten. Vor Aufraeumen: `grep -r 'venv'` und `find` nach activate-Scripten ausfuehren. |
| 11 | **Alte Backups als Restore-Point** | cleanup_safety_review.md | **Niedrig** | 🔴 Offen | Alte Backups koennen noch als Restore-Point benoetigt werden. Vor Loeschung pruefen, ob aktuelle Backups existieren. |
| 12 | **Alte Testdateien mit Referenzdaten** | cleanup_safety_review.md | **Niedrig** | 🔴 Offen | Testdateien koennen Referenzdaten enthalten. Vor Loeschung einzeln begutachten. |
| 13 | **Miniconda3-Installer (156 MB)** | orphan_file_review.md, cleanup_safety_review.md, final_project_readiness_assessment.md | **Niedrig** | 🟡 Teilweise behoben | 3 Dateien empfehlen Loeschung des Installers. Readiness-Assessment sagt 'keine offenen Aufgaben'. Status unklar – physische Verifizierung noetig. |
| 14 | **Cron-Job-Luecke fuer Monitoring-Skripte** | workspace_state_snapshot.md | **Hoch** | ✅ Behoben | Kein automatisierter Cron-Job fuer memory_monitor.sh und disk_space_monitor.sh. final_project_readiness_assessment.md bestaetigt: 4 Cron-Jobs aktiv (cpu, tests, memory, disk). |
| 15 | **Verwaiste backup_test_old-Verzeichnisse** | workspace_state_snapshot.md | **Niedrig** | ✅ Behoben | 3 verwaiste backup_test_old-Verzeichnisse. final_project_readiness_assessment.md bestaetigt: alle 3 Pfade existieren nicht mehr. |
| 16 | **Doppelte/veraltete team_journal-Dateien** | workspace_state_snapshot.md | **Niedrig** | ✅ Behoben | team_journal_entry.md war veraltet/duplikat. final_project_readiness_assessment.md bestaetigt: Datei existiert nicht mehr. |
| 17 | **Monitoring-Suite nicht robust gegen fehlende Abhaengigkeiten** | team_journal.md (monitoring_suite_review) | **Mittel** | 🔴 Offen | Suite funktioniert im aktuellen Setup, ist aber nicht robust gegen fehlende Abhaengigkeiten, andere Locales oder Non-Root-Ausfuehrung. |
| 18 | **Historische Referenz auf team_journal_entry.md** | support_workspace_audit.md | **Niedrig** | 🔴 Offen | team_journal.md erwaehnt team_journal_entry.md, die Datei existiert nicht mehr. Dokumentarische Referenz – keine kritische Abweichung, aber Inkonsistenz. |
| 19 | **Kernel: ext4-Journal-Korruption** | system_log_analysis.md, system_log_risk_crosscheck.md | **Mittel** | 🔴 Offen | dmesg zeigt ext4-Journal-Fehler (Journal-Checksummen-Fehler). Dateisystem-Integritaet gefaehrdet – moeglicher Datenverlust bei Crash. fsck und Backup-Strategie pruefen. |
| 20 | **Kernel: CPU-Workqueue-Ueberlastung** | system_log_analysis.md, system_log_risk_crosscheck.md | **Mittel** | 🔴 Offen | dmesg zeigt Workqueue-Blockierungen und CPU-Softlockup-Warnungen. Kann zu System-Haengern unter Last fuehren. CPU-Auslastung und Prozesse mit top/htop ueberwachen. |
| 21 | **llama-server Speicherengpaesse** | system_log_analysis.md, system_log_risk_crosscheck.md | **Hoch** | 🔴 Offen | dmesg zeigt wiederholt 'Out of memory' und 'Killed process' fuer llama-server. Agenten-Server-Betrieb akut gefaehrdet. Swap vergroessern, Speicherlimit anpassen oder llama-Server-Parameter (n_ctx, threads) reduzieren. |

---

## Zusammenfassung nach Status

### 🔴 Offene Risiken: 17

| Kritikalitaet | Anzahl | Risiken |
|-------------|-------|--------|
| **Hoch** | 5 | #1 (set -e Gotcha), #2 (CUDA-Libs), #3 (Ollama-Komplett), #4 (Display-Fehler), #21 (llama-server Speicher) |
| **Mittel-Hoch** | 1 | #5 (venv-Loeschung) |
| **Mittel** | 7 | #6 (Index-Luecken), #7 (Log-rm), #8 (Cache), #9 (Logrotate), #10 (verschachtelte venvs), #17 (Monitoring-Robustheit), #19 (ext4-Journal-Korruption), #20 (CPU-Workqueue) |
| **Niedrig** | 4 | #11 (Backups), #12 (Testdateien), #13 (Miniconda3), #18 (historische Referenz) |

### ✅ Behobene Risiken: 3

| Kritikalitaet | Risiko | Loesung |
|-------------|--------|---------|
| **Hoch** | #14 (Cron-Job-Luecke) | 4 Cron-Jobs aktiv (cpu, tests, memory, disk) |
| **Niedrig** | #15 (backup_test_old verwaist) | Alle 3 Verzeichnisse entfernt |
| **Niedrig** | #16 (Doppelte team_journal) | team_journal_entry.md geloescht |

---

## Priorisierte Empfehlungen

### Sofort zu adressieren (Hoch-Kritikalitaet, offen)

1. **#1 – set -e Gotcha beheben**: `set -e` durch `set -eo pipefail` ersetzen ODER `((PASSED++))` zu `((PASSED++)) || true` aendern in run_all_tests.sh und aehnlichen Skripten.
2. **#2 – CUDA-Bibliotheken schuetzen**: Vor jeder Cleanup-Aktion CUDA-Bibliotheken (ollama/lib/ollama/cuda_v*) explizit ausschliessen. Kein `rm -rf` auf ollama-Verzeichnis ohne Team-Abstimmung.
3. **#3 – Ollama-Verzeichnis schuetzen**: `pgrep -a ollama` pruefen. Wenn aktiv: NICHT loeschen. Wenn inaktiv: Team-Konsens einholen, tar-Backup erstellen, dann erst loeschen.
4. **#4 – Display-Fehler vermeiden**: GUI-Aktionen (`open_app`, `click_text`, `see_screen`) vermeiden. Standardmaessig CLI/Datei-Operationen nutzen. Bei 'Cannot connect to display' sofort CLI-Alternative waehlen.

### Mittlere Prioritaet (Mittel, offen)

5. **#5 – venv-Referenzen pruefen**: `grep -r 'venv' /root/local_agent/` ausfuehren. Wenn keine Referenzen: tar-Backup, dann loeschen. Wenn Referenzen: NICHT loeschen.
6. **#6 – Index aktualisieren**: 6 fehlende Dateien in support_files_index.md registrieren.
7. **#17 – Monitoring-Suite haerten**: Abhaengigkeitspruefung, Locale-Unabhaengigkeit, Non-Root-Kompatibilitaet testen.
8. **#19 – ext4-Journal-Korruption**: fsck auf Root-Dateisystem vornehmen (im Wartungsfenster). Backup-Strategie verifizieren.
9. **#20 – CPU-Workqueue-Ueberlastung**: CPU-Auslastung mit top/htop ueberwachen. Prozesse identifizieren, die Workqueues blockieren.

### Niedrige Prioritaet (Niedrig, offen)

8. **#13 – Miniconda3-Installer**: `ls -la /root/Miniconda3-latest-Linux-x86_64.sh` verifizieren. Wenn vorhanden und Installation abgeschlossen: loeschen.
9. **#18 – Historische Referenz bereinigen**: team_journal.md-Eintrag zu team_journal_entry.md als 'geloescht' markieren oder Referenz entfernen.

---

## Quellen-Verweis

| Quelle | Enthaltene Risiken |
|--------|-------------------|
| cleanup_safety_review.md | #2, #3, #5, #7, #8, #9, #10, #11, #12 |
| risk_display_error.md | #4 |
| orphan_file_review.md | #2, #13 |
| final_project_readiness_assessment.md | #13, #14, #15, #16 (Status-Bestaetigung) |
| workspace_state_snapshot.md | #14, #15, #16 |
| support_workspace_audit.md | #6, #18 |
| team_journal.md | #1, #4, #17 |
| monitoring_suite_review.md | #1, #17 |
| system_log_analysis.md | #19, #20, #21 |
| system_log_risk_crosscheck.md | #19, #20, #21 |

---

*Erstellt von Support-Agent GLM am 18.06.2026 um 11:21 Uhr.*
*Diese Datei konsolidiert alle bekannten Risiken an einem Ort fuer das Team.*