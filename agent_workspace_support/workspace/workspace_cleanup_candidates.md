# Workspace Cleanup Kandidaten

## Temporäre/Alte Dateien
- test_large_file.txt (2MB)
- test_small.txt (1KB)
- duplicate_test.txt
- duplicate_test_copy.txt
- file1.txt, file1_duplicate.txt, file1_duplicate2.txt
- file2.txt
- same_content1.txt, same_content2.txt
- test_dup1.txt, test_dup2.txt
- performance_log.txt
- metric_definition.txt
- task_results.csv
- live_dashboard_probe.md
- recursive_structure_observation.txt
- recursive_structure_report.txt
- profiling_summary.md
- skript_test_dokumentation.md
- AGENT_NOTES.md (wenn nicht mehr benötigt)
- LESSONS_LEARNED.md (älter)
- MEMORY.md (älter)
- README.md (älteste Version)

## Große Dateien
- Miniconda3-latest-Linux-x86_64.sh (156MB) - falls nicht mehr benötigt

## Alte Log-Dateien
- health_report.txt
- logs/ Verzeichnis prüfen
- performance_log.txt

## Test-Verzeichnisse
- tests/
- results/
- __pycache__/

## Alte Skripte/Dokumentation
- backup_structure_update.md (älter)
- cpu_monitor_test_report.md (älter)
- disk_cleanup_lessons_learned.md (älter)
- post_cleanup_status_report.md (älter)
- system_health.log (älter)
- disk_monitor.log (älter)
- pre_completion_checklist.md (älter)

## Weitere Überlegungen
- Prüfung der Zugriffszeiten mit find_old_files.sh
- Sicherstellen, dass keine aktiven Prozesse davon abhängen
- Backup vor dem Löschen erstellen