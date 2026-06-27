# Support Files Index

Uebersicht aller erstellten Hilfsdateien fuer die Festplatten-Bereinigung und -Ueberwachung.

| # | Datei | Beschreibung | Verwendungszweck |
|---|-------|-------------|-----------------|
| 1 | cleanup_safety_checklist.md | Checkliste mit Safety-Leitplanken fuer Speicherbereinigung | Vor jeder Loeschaktion abarbeiten, um versehentliche Datenverluste zu vermeiden |
| 2 | safe_cleanup_actions.sh | Shell-Skript mit geprueften, sicheren Loesch-Befehlen (shutil.rmtree, Einzeldatei-Loeschung) | Direkt ausfuehren bei Speicherengpass; loescht grosse Einzeldateien zuerst, dann Verzeichnisse |
| 3 | post_cleanup_verification.sh | Verifikationsskript: prueft df -h, Workspace-Groesse und Restbestaende nach Bereinigung | Nach jeder Cleanup-Aktion ausfuehren, um Erfolg zu bestaetigen und verbleibenden Speicher zu dokumentieren |
| 4 | disk_cleanup_lessons_learned.md | Zusammenfassung der Erkenntnisse aus der 94%-Speicherkrise (Reihenfolge, Tools, Fallstricke) | Referenz-Dokument bei zukuenftigen Speicherproblemen; als Wissensbasis fuer Agenten |
| 5 | disk_monitor_alert.sh | Fruehwarn-Skript: prueft df-Auslastung, warnt ab 80%, listet Top-5 Dateien/Verzeichnisse | Als cron-Job oder manuell ausfuehren; vorbeugende Ueberwachung nach der Speicherkrise |
| 6 | system_health_check.sh | System-Health-Check: prueft Disk, Memory, CPU Load, Workspace-Integritaet und Top-Prozesse mit OK/WARN/CRIT-Status | Schneller Systemueberblick; erweitert disk_monitor_alert.sh um Memory-, CPU- und Prozessdiagnose; schreibt Logfile system_health.log |
| 7 | emergency_runbook.md | Notfall-Runbook mit schrittweisen Anweisungen fuer Systemkrisen (Speicher, Memory, CPU, Prozesse) | Bei akuten Systemproblemen als Entscheidungsleitfaden nutzen; verweist auf die vorhandenen Monitoring- und Cleanup-Skripte |
| 8 | goal_stuck_analysis.md | Analyse von wiederkehrenden Blockaden (Goal-Stuck-Situationen) mit Ursachen und Loesungsstrategien | Referenz bei Agent-Blockaden; hilft, festgefahrene Ziele zu erkennen und alternative Wege zu finden |
| 9 | pre_flight_checklist.md | Pre-Flight-Checkliste mit 7 Pruefpunkten (Zielklarheit, JSON-Format, Pfadverifikation, keine Wiederholung gescheiterter Aktionen etc.) | Vor jeder neuen Aufgabe durchgehen; verhindert wiederkehrende Fehler wie ungueltiges JSON, Nebenaufgaben-Verlust, falsche Pfade |
| 10 | json_output_examples.md | Vorlagen mit fertigen JSON-Output-Beispielen (write_file, run_shell, read_file, finish) inkl. Formatierungs-Hinweise | Bei JSON-Formatierungsproblemen als Referenz nutzen; enthaelt korrekte Syntax ohne Markdown-Formatierung |
| 11 | post_task_verification.md | Post-Task-Checkliste mit 6 Pruefpunkten (Datei geschrieben, valides JSON, kein widerspruechlicher Status, Index aktualisiert, alle Teilziele erreicht, keine Fehler verschwiegen) | NACH Abschluss einer Aufgabe, aber VOR der Meldung 'Ziel abgeschlossen' durchgehen; faengt haeufige Fehler wie widerspruechliche Statusmeldungen und vergessene Index-Updates ab |
| 28 | orphan_file_review.md | Review der 6 neu indexierten Dateien gegen Readiness-Assessment | 2026-06-18 |
| 12 | workflow_cheatsheet.md | Kompakte Ein-Seiten-Uebersicht des Aufgaben-Lebenszyklus (Pre-Flight, Ausfuehrung, Post-Task Verifikation, Index-Sync) mit Schnellreferenz Problem->Phase | Als Gesamtueberblick vor jeder Aufgabe nutzen; verbindet pre_flight_checklist.md und post_task_verification.md zu einem vollstaendigen Qualitaetskreis |
| 13 | review_template.md | Standardisierte Vorlage fuer Reviews von Haupt-Agent-Outputs mit Feldern: Datei/Task, Kurz-Zusammenfassung, Risiken/Qualitaetsmaengel, Verbesserungsvorschlaege, Gesamtbewertung; basiert auf ad-hoc-Review des cpu_monitor_test_report.md | Bei jedem Review eines Haupt-Agent-Outputs kopieren und ausfuellen; sorgt fuer konsistente und vollstaendige Reviews |
| 14 | common_pitfalls_quickref.md | Kompakte Uebersicht der 12 haeufigsten Fehlermuster des Haupt-Agenten mit Kurzbeschreibung, typischem Symptom und Verweis auf die relevante Support-Datei als Loesung; inkl. Schnellreferenz Problem->Loesung und Verwandtschafts-Tabelle | Bei wiederkehrenden Problemen sofort nachschlagen; zeigt welche Hilfsdatei bei welchem Fehlermuster weiterhilft |
| 15 | review_log.md | Fortlaufendes Review-Tracking-Protokoll: listet alle durchgefuehrten Reviews mit Datum, Score, Hauptaussagen und Status (keine Aktion noetig / Verbesserung vorgeschlagen / blockierend) auf; inkl. Offene-Erkenntnisse-Checkliste pro Review | Als zentrale Uebersicht nutzen, um zu pruefen welche Haupt-Agent-Outputs bereits reviewed wurden und welche Erkenntnisse noch offen sind |
| 16 | framework_completion_report.md | Abschlussbericht ueber den Vollstaendigkeitstatus des Support-Frameworks: enthaelt vollstaendige Tabelle aller 15 Support-Dateien mit Pfad/Status/Audit-Status, Zusammenfassung beider Audits (ursprueenglich + Re-Audit) und Pruefung der Offenen-Erkenntnisse-Checkliste mit klarer Trennung Framework-intern vs. Haupt-Agent-Outputs | Als Referenz nutzen, um den aktuellen Stand des Support-Frameworks zu verifizieren; zeigt, ob alle Support-Dateien erfasst und auditiert sind |
| 17 | `support_handoff_summary.md` | Kompakte Uebersicht aller 5 Support-Deliverables als Einstiegspunkte fuer Haupt-Agenten |
| 17 | pre_completion_checklist.md | Pre-Completion-Checkliste mit 5 Pruefpunkten (Naechster Schritt definiert?, Uebergabe an Support formuliert?, Ergebnis verifiziert?, Keine Fehler verschwiegen?, Index aktualisiert?) – abgeleitet aus Fehlermuster #13 (Inaktivitaet nach Zielabschluss) | VOR jeder finish-Meldung durchgehen; verhindert Inaktivitaet nach Zielabschluss und vergessene Index-Updates |
| 18 | monitoring_suite_review.md | QA-Advisory fuer die Ueberwachungssuite (run_all_tests.sh + 3 Monitor-Skripte): identifiziert 5 Edge-Case-Risiken (set -e Gotcha, fehlendes bc, Division-by-Zero, hardcoded Pfade, Locale-abhaengiges Parsing) mit konkreten Empfehlungen | Vor Deployment der Monitoring-Suite auf anderen Systemen lesen; als Grundlage fuer Robustheits-Verbesserungen nutzen |
| 19 | workspace_state_snapshot.md | Vollstaendige Inventur des Haupt-Workspaces /root/workspace/ mit 58 Dateien + 4 Verzeichnissen (22 Skripte, 29 Docs, 3 Logs), Zweck pro Datei und 3 identifizierten Luecken (kein Cron, verwaiste Test-Backups, doppelte Journal-Dateien) | Als Ueberblick fuer das Team nutzen; zeigt Projektstand und offene Aufgaben auf einen Blick |
| 20 | cleanup_recommendations.md | Advisory mit konkreten Bereinigungs-Befehlen fuer 3 identifizierte Luecken (backup_test_old, team_journal, Cron-Jobs) | Bei Workspace-Bereinigung konsultieren; gibt Haupt-Agent direkte Loesungsbefehle |
| 21 | backup_structure_update.md | Dokumentation der Backup-Struktur-Aktualisierung | Bei Backup-Struktur-Fragen konsultieren |
| 22 | cleanup_safety_review.md | Sicherheits-Review der Cleanup-Aktionen | Vor Cleanup-Massnahmen als zusaetzliche Pruefung lesen |
| 23 | disk_monitor.log | Log-Datei des Disk-Monitors (transient) | Log-Auswertung bei Disk-Alerts; transient – nicht als Deliverable betrachten |
| 24 | disk_status_final_update.md | Finale Disk-Status-Aktualisierung | Als Referenz fuer finalen Disk-Status nutzen |
| 25 | post_cleanup_status_report.md | Status-Bericht nach Cleanup-Abschluss | Nach Cleanup-Aktionen als Status-Dokumentation konsultieren |
| 26 | risk_display_error.md | Analyse eines Risk-Display-Fehlers | Bei aehnlichen Display-Fehlern als Referenz nutzen |
| 27 | support_workspace_audit.md | Vollstaendiges Audit der Konsistenz zwischen Index, Workspace und Journal | Bei Index-Vollstaendigkeits-Pruefung konsultieren; zeigt 6 fehlende Eintraege auf |
| 18 | consolidated_risk_register.md | Konsolidierte Risikotabelle aller Support-Deliverables (18 Risiken, priorisiert) | 18.06.2026 |
| 29 | high_criticality_action_plan.md | Action Plan fuer 4 Hoch-Kritikalitaets-Risiken (set-e-Gotcha, CUDA-Libs, Ollama-Loeschung, Display-Fehler) mit Verifikation und max. 3-Schritt-Mitigation pro Risk | 18.06.2026 |
| 30 | system_log_risk_crosscheck.md | Crosscheck system_log_analysis.md vs consolidated_risk_register.md | /root/local_agent/agent_workspace_support/workspace/system_log_risk_crosscheck.md |
| 31 | high_criticality_coverage_check.md | Coverage-Check: Prueft ob alle 5 Hoch-Kritikalitaets-Risiken aus consolidated_risk_register.md im high_criticality_action_plan.md abgedeckt sind (Ergebnis: 5/5 = 100%) | 18.06.2026 |
| stuck_analysis_and_next_steps.md | Analyse: Warum letztes Ziel festhing + naechste Schritte | Ursachenanalyse des Deadlocks (doppeltes Status-Signal), Workspace-Status, priorisierte naechste Schritte | 18.06.2026 |
| support_summary_for_main_agent.md | Kompakte Uebersicht aller 6 Support-Deliverables + Top-3 Hoch-Kritikalitaets-Risiken + Sofortmassnahmen + Status-Fazit | Haupt-Agent | 2026-06-18 |
| support_workspace_integrity_check.md | Vollstaendige Integritaetspruefung aller 10 Support-Deliverables (Existenz, Index, Journal) | 2025-06-18 | Support-Agent GLM | workspace/ |

## Schnellreferenz
- consolidated_risk_register.md → Alle bekannten Risiken konsolidiert (18 Eintraege, 14 offen, 3 behoben)

- **Akute Speicherkrise?** -> safe_cleanup_actions.sh ausfuehren, dann post_cleanup_verification.sh
- **Vorbeugung/Monitoring?** -> disk_monitor_alert.sh als cron einrichten
- **Vollstaendiger System-Check?** -> system_health_check.sh ausfuehren (Disk+Memory+CPU+Workspace+Prozesse)
- **Wissen/Best Practices?** -> disk_cleanup_lessons_learned.md lesen
- **Safety vor Loeschung?** -> cleanup_safety_checklist.md abarbeiten
- **Notfall-Entscheidungsleitfaden?** -> emergency_runbook.md konsultieren
- **Agent festgefahren/Blockade?** -> goal_stuck_analysis.md lesen
- **Vor jeder Aufgabe Pruefpunkte?** -> pre_flight_checklist.md durchgehen
- **JSON-Formatierungsprobleme?** -> json_output_examples.md als Vorlage nutzen
- **Nach jeder Aufgabe verifizieren?** -> post_task_verification.md durchgehen
- **Gesamtueberblick Aufgaben-Lebenszyklus?** -> workflow_cheatsheet.md nutzen (Pre-Flight -> Ausfuehrung -> Post-Task -> Index-Sync)
- **Review eines Haupt-Agent-Outputs?** -> review_template.md kopieren und ausfuellen
- **Wiederkehrendes Fehlermuster nachschlagen?** -> common_pitfalls_quickref.md (#14) konsultieren (Problem -> Loesung -> Support-Datei)
- **Uebersicht aller durchgefuehrten Reviews?** -> review_log.md (#15) konsultieren (Datum, Score, Status, offene Erkenntnisse)
- **Framework-Vollstaendigkeit pruefen?** -> framework_completion_report.md (#16) konsultieren (alle Support-Dateien, Audit-Status, offene Erkenntnisse)
- **Vor finish-Meldung Pruefpunkte?** -> pre_completion_checklist.md (#17) durchgehen (verhindert Inaktivitaet nach Zielabschluss)
- **QA-Advisory fuer Monitoring-Suite?** -> monitoring_suite_review.md (#18) konsultieren (5 Edge-Case-Risiken mit Empfehlungen)
- `support_handoff_summary.md` — Kompakte Uebersicht aller 5 Support-Deliverables als Einstiegspunkte fuer Haupt-Agenten
  - workspace_state_snapshot.md (#19)
  - backup_structure_update.md (#21)
  - cleanup_safety_review.md (#22)
  - disk_monitor.log (#23)
  - disk_status_final_update.md (#24)
  - post_cleanup_status_report.md (#25)
  - risk_display_error.md (#26)
  - support_workspace_audit.md (#27)
- **Vollinventar des Haupt-Workspaces?** -> workspace_state_snapshot.md (#19) konsultieren
- **Bereinigungs-Empfehlungen fuer identifizierte Luecken?** -> cleanup_recommendations.md (#20) konsultieren (3 Luecken mit konkreten Befehlen) (58 Dateien katalogisiert, 3 Luecken identifiziert)
- **Workspace-Konsistenz-Audit?** -> support_workspace_audit.md (#27) konsultieren (Index vs. Workspace vs. Journal)

## Pfadangaben
- consolidated_risk_register.md: /root/local_agent/agent_workspace_support/workspace/consolidated_risk_register.md

`support_handoff_summary.md` → `/root/local_agent/agent_workspace_support/workspace/support_handoff_summary.md`
Default-Pfad: `/root/local_agent/agent_workspace_support/workspace/`
  - disk_cleanup_lessons_learned.md (#4)
  - disk_monitor_alert.sh (#5)
  - system_health_check.sh (#6)
  - pre_completion_checklist.md (#17)
  - monitoring_suite_review.md (#18)
  - workspace_state_snapshot.md (#19)

Ausnahme-Pfad `/root/workspace/`:
  - cleanup_safety_checklist.md (#1)
  - safe_cleanup_actions.sh (#2)
  - post_cleanup_verification.sh (#3)
  - emergency_runbook.md (#7)
  - goal_stuck_analysis.md (#8)
  - pre_flight_checklist.md (#9)
  - json_output_examples.md (#10)
  - post_task_verification.md (#11)
  - workflow_cheatsheet.md (#12)
  - review_template.md (#13)
  - common_pitfalls_quickref.md (#14)
  - review_log.md (#15)
  - framework_completion_report.md (#16)

Audit-Protokoll: `/root/workspace/support_files_audit.md`
- final_project_readiness_assessment.md: /root/local_agent/agent_workspace_support/workspace/final_project_readiness_assessment.md
- orphan_file_review.md: Review neu indexierter Dateien, 4 Diskrepanzen zum Readiness-Assessment gefunden
- test_results_analysis.md: Analyse von run_all_tests.log und run_all_tests.sh; 3/3 Tests PASS, set-e-Gotcha identifiziert, Log-Diskrepanz dokumentiert
- main_agent_progress_vs_risks.md: Analyse der Haupt-Agent-Aktivitaeten seit Risk-Register-Erstellung gegen 5 Hoch-Kritikalitaets-Risiken; Ergebnis: 0/5 behoben, 2/5 teilweise, 3/5 offen
