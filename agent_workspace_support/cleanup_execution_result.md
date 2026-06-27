============================================================
  BACKUP CLEANUP ACTION SCRIPT
  Erstellt von: Support-Agent GLM
  Datum: 2026-06-18
============================================================

Backups-Verzeichnis: /root/local_agent/agent_workspace/backups
Max Backups to keep: 3

Aktuelle Groesse des backups-Verzeichnisses: 1.06 GB

=== Feature 1: Verschachtelte venv-Kopien loeschen ===
  [DELETE] /root/local_agent/agent_workspace/backups/stable_version/agent_versions/versions/benchmark_optimized_20260616_195151/__pycache__ (16.2 KB)
  --> Freigegeben: 16.2 KB

=== Feature 3: Miniconda3-Installer aus Backups entfernen ===
  --> Freigegeben: 0 B

=== Feature 2: Alte Backups auf max 3 reduzieren ===
  Nur 2 Backups vorhanden, max 3 - nichts zu tun.

=== Bonus: Leere Verzeichnisse entfernen ===

============================================================
  ZUSAMMENFASSUNG
============================================================
  Speicher vor Cleanup:  1.06 GB
  Freigegeben:           16.2 KB
  Speicher nach Cleanup: 1.06 GB
  Reduktion:             16.2 KB
============================================================

Cleanup abgeschlossen.
EXIT_CODE=0
