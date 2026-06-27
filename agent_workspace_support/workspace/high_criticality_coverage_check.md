# High Criticality Coverage Check

**Erstellt von:** Support-Agent GLM  
**Datum:** 18.06.2026  
**Ziel:** Pruefung, ob alle 5 als 'Hoch' und 'offen' markierten Risiken aus consolidated_risk_register.md einen entsprechenden Mitigations-Eintrag in high_criticality_action_plan.md haben.

---

## 1. Methode

- **Quelle 1:** `consolidated_risk_register.md` — grep nach `Hoch` + Status `🔴 Offen` identifiziert 5 Risiken.
- **Quelle 2:** `high_criticality_action_plan.md` — grep nach `Risk #[0-9]+` extrahiert alle dort dokumentierten Risk-IDs.
- **Vergleich:** Set-Differenz zwischen den beiden ID-Mengen zeigt fehlende Eintraege.

---

## 2. Ergebnis: Hoch-Risiken im Register (offen)

| Risk # | Risiko | Kritikalitaet | Status | In Action Plan? |
|--------|--------|-------------|--------|-----------------|
| 1 | set -e + ((PASSED++)) Bash-Arithmetic-Gotcha | Hoch | 🔴 Offen | ✅ Ja |
| 2 | CUDA-Bibliotheken-Loeschung | Hoch | 🔴 Offen | ✅ Ja |
| 3 | Ollama-Komplettloeschung | Hoch | 🔴 Offen | ✅ Ja |
| 4 | Display-Fehler (Cannot connect to display) | Hoch | 🔴 Offen | ✅ Ja |
| 21 | llama-server Speicherengpaesse | Hoch | 🔴 Offen | ✅ Ja |

---

## 3. Coverage-Status

| Metrik | Wert |
|--------|------|
| Hoch-Risiken (offen) im Register | 5 |
| Hoch-Risiken im Action Plan | 5 |
| Fehlende Risiken | **0** |
| Abdeckung | **100%** |

**Ergebnis:** Alle 5 Hoch-Kritikalitaets-Risiken aus consolidated_risk_register.md haben einen entsprechenden Mitigations-Eintrag in high_criticality_action_plan.md. Es fehlen keine Eintraege.

---

## 4. Fehlende Risiken & 3-Schritte-Mitigationen

**Keine fehlenden Risiken gefunden.** Alle 5 Hoch-Risiken sind im Action Plan mit jeweils 3-Schritte-Mitigationen abgedeckt:

| Risk # | Mitigation im Action Plan |
|--------|--------------------------|
| 1 | sed-Ersatz fuer ((PASSED++)), set -eo pipefail, Skript-Test |
| 2 | Cleanup-Skripte auf CUDA pruefen, Exclude-Liste, Marker-Datei |
| 3 | Ollama-Nutzung pruefen, tar-Backup, Team-Konsens dokumentieren |
| 4 | DISPLAY-Check in Skripten, CLI-First dokumentieren, optional Xvfb |
| 21 | free -m + ps pruefen, llama-server Konfig pruefen, Restart-Prozedur dokumentieren |

---

## 5. Empfehlung

Da alle Hoch-Risiken vollstaendig abgedeckt sind, wird empfohlen:
1. Die im Action Plan beschriebenen 3-Schritte-Mitigationen fuer alle 5 Risiken nacheinander auszufuehren.
2. Nach Abschluss jeder Mitigation den Status im consolidated_risk_register.md von `🔴 Offen` auf `✅ Behoben` zu aktualisieren.
3. Einen erneuten Coverage-Check durchzufuehren, sobald neue Risiken hinzugefuegt werden.

---

*Coverage-Check abgeschlossen: 5/5 Hoch-Risiken abgedeckt, 0 fehlend.*
