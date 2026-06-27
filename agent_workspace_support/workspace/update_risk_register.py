from pathlib import Path

filepath = Path('/root/local_agent/agent_workspace_support/workspace/consolidated_risk_register.md')
content = filepath.read_text()

# 1. Zusammenfassung aktualisieren: 14 -> 17 offene Risiken
content = content.replace('### Offene Risiken: 14', '### Offene Risiken: 17')

# 2. Hoch-Kritikalitaet: 4 -> 5, und #21 hinzufuegen
content = content.replace('| **Hoch** | 4 | #1 (set -e Gotcha), #2 (CUDA-Libs), #3 (Ollama-Komplett), #4 (Display-Fehler) |',
                          '| **Hoch** | 5 | #1 (set -e Gotcha), #2 (CUDA-Libs), #3 (Ollama-Komplett), #4 (Display-Fehler), #21 (llama-server Speicher) |')

# 3. Mittel-Kritikalitaet: 5 -> 7, #19 und #20 hinzufuegen
content = content.replace('| **Mittel** | 5 | #6 (Index-Luecken), #7 (Log-rm), #8 (Cache), #9 (Logrotate), #10 (verschachtelte venvs), #17 (Monitoring-Robustheit) |',
                          '| **Mittel** | 7 | #6 (Index-Luecken), #7 (Log-rm), #8 (Cache), #9 (Logrotate), #10 (verschachtelte venvs), #17 (Monitoring-Robustheit), #19 (ext4-Journal-Korruption), #20 (CPU-Workqueue) |')

# 4. Quellen-Verweis Tabelle: system_log_analysis.md und system_log_risk_crosscheck.md hinzufuegen
old_sources_end = '| monitoring_suite_review.md | #1, #17 |'
new_sources = old_sources_end + '\n| system_log_analysis.md | #19, #20, #21 |\n| system_log_risk_crosscheck.md | #19, #20, #21 |'
content = content.replace(old_sources_end, new_sources)

# 5. Empfehlungen: #21 zur Sofort-Sektion hinzufuegen
old_prio_end = '4. **#4 \u2013 Display-Fehler vermeiden**: GUI-Aktionen vermeiden. Standardmaessig CLI/Datei-Operationen nutzen. Bei Cannot connect to display sofort CLI-Alternative waehlen.'
new_prio = old_prio_end + '\n5. **#21 \u2013 llama-server Speicherengpaesse**: Swap vergroessern, Speicherlimit pruefen, llama-server-Parameter (n_ctx, threads) reduzieren. Akute Gefaehrdung des Agenten-Betriebs.'
content = content.replace(old_prio_end, new_prio)

# 6. Mittlere Prioritaet: #19 und #20 hinzufuegen
old_mid_end = '7. **#17 \u2013 Monitoring-Suite haerten**: Abhaengigkeitspruefung, Locale-Unabhaengigkeit, Non-Root-Kompatibilitaet testen.'
new_mid = old_mid_end + '\n8. **#19 \u2013 ext4-Journal-Korruption**: fsck auf Root-Dateisystem vornehmen (im Wartungsfenster). Backup-Strategie verifizieren.\n9. **#20 \u2013 CPU-Workqueue-Ueberlastung**: CPU-Auslastung mit top/htop ueberwachen. Prozesse identifizieren, die Workqueues blockieren.'
content = content.replace(old_mid_end, new_mid)

filepath.write_text(content)
print(f'Aktualisiert. Dateigroesse: {filepath.stat().st_size} Bytes')
print()
print('Verifikation:')
print(f'  Offene Risiken 17: {content.count("Offene Risiken: 17")}')
print(f'  Hoch 5: {content.count("Hoch\\\" | 5")}')
print(f'  Mittel 7: {content.count("Mittel\\\" | 7")}')
print(f'  system_log_analysis in Quellen: {content.count("system_log_analysis.md | #19")}')
print(f'  system_log_risk_crosscheck in Quellen: {content.count("system_log_risk_crosscheck.md | #19")}')
print(f'  Empfehlung #21: {content.count("#21 \u2013 llama-server Speicherengpaesse")}')
print(f'  Empfehlung #19: {content.count("#19 \u2013 ext4-Journal")}')
print(f'  Empfehlung #20: {content.count("#20 \u2013 CPU-Workqueue")}')
