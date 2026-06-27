from pathlib import Path

filepath = Path('/root/local_agent/agent_workspace_support/workspace/consolidated_risk_register.md')
content = filepath.read_text()

# 1. Offene Risiken: 14 -> 17
content = content.replace('Offene Risiken: 14', 'Offene Risiken: 17')

# 2. Hoch: 4 -> 5 und #21 ergaenzen
content = content.replace('| **Hoch** | 4 |', '| **Hoch** | 5 |')
content = content.replace('#4 (Display-Fehler) |', '#4 (Display-Fehler), #21 (llama-server Speicher) |')

# 3. Empfehlung #21 zur Sofort-Sektion hinzufuegen (nach #4)
marker = "CLI-Alternative waehlen."
if '#21' not in content.split('### Mittlere Prioritaet')[0]:
    content = content.replace(
        marker,
        marker + "\n5. **#21 - llama-server Speicherengpaesse**: Swap vergroessern, Speicherlimit pruefen, llama-server-Parameter reduzieren. Akute Gefaehrdung des Agenten-Betriebs."
    )

filepath.write_text(content)

# Verifikation
print(f'Dateigroesse: {filepath.stat().st_size} Bytes')
print(f'Offene Risiken 17: {content.count("Offene Risiken: 17")}')
print(f'Hoch 5: {content.count("| **Hoch** | 5")}')
print(f'Mittel 7: {content.count("| **Mittel** | 7")}')
print(f'#19 in Tabelle: {content.count("| 19 |")}')
print(f'#20 in Tabelle: {content.count("| 20 |")}')
print(f'#21 in Tabelle: {content.count("| 21 |")}')
print(f'Empfehlung #21: {content.count("#21 - llama-server")}')
print(f'Empfehlung #19: {content.count("#19 - ext4")}')
print(f'Empfehlung #20: {content.count("#20 - CPU")}')
print(f'Quelle system_log_analysis: {content.count("system_log_analysis.md | #19")}')
print(f'Quelle system_log_risk_crosscheck: {content.count("system_log_risk_crosscheck.md | #19")}')
