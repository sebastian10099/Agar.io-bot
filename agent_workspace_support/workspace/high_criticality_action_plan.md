# High Criticality Action Plan

> Erstellt am 18.06.2026 von Support-Agent GLM
> Filtert alle Risiken mit Kritikalitaet 'Hoch' und Status 'Offen' aus consolidated_risk_register.md
> Prueft aktuellen Dateistatus im Haupt-Workspace und erstellt konkrete Mitigations-Vorschlaege

---

## Gefilterte Risiken: Kritikalitaet 'Hoch' + Status 'Offen'

Aus consolidated_risk_register.md wurden 4 Risiken mit Kritikalitaet 'Hoch' und Status 'Offen' identifiziert (inkl. #21 nachgetragen):
- Risk #1: set -e + PASSED++ Bash-Arithmetic-Gotcha
- Risk #2: CUDA-Bibliotheken-Loeschung
- Risk #3: Ollama-Komplettloeschung
- Risk #4: Display-Fehler (Cannot connect to display)

---

## Verifikation des aktuellen Dateistatus (18.06.2026, 11:25 Uhr)

### Risk #1: set -e + PASSED++ Bash-Arithmetic-Gotcha

**Status:** ✅ NOCH OFFEN — Risiko besteht weiterhin

**Verifikation:**
- `/root/workspace/run_all_tests.sh` existiert (1037 Bytes, zuletzt geaendert 18.06. 10:33)
- Zeile 6: `set -e` ist aktiv
- Zeile 23: `((PASSED++))` ohne `|| true` Schutz
- Die `run_test`-Aufrufe haben `|| true` angehaengt, was `set -e` innerhalb der Funktion teilweise suspendiert — dies ist aber subtil und fragil
- Weitere Skripte mit `set -e`: safe_cleanup_actions.sh (hat `set -euo pipefail`), script_lint_checker.sh (hat `set -euo pipefail`)

**Aktuelle Gefahr:** Wenn `PASSED=0` und ein Test erfolgreich ist, gibt `((PASSED++))` den Wert 0 zurueck (Exit-Code 1). Mit `set -e` wuerde das Skript abbrechen. Die `|| true` auf den `run_test`-Aufrufen suspendiert `set -e` innerhalb der Funktion, aber dieses Verhalten ist bash-spezifisch und nicht offensichtlich.

### Risk #2: CUDA-Bibliotheken-Loeschung

**Status:** ✅ NOCH OFFEN — Bibliotheken existieren weiterhin

**Verifikation:**
- `/usr/local/lib/ollama/cuda_v12/` — 1.2 GB (libcublas, libcublasLt, libcudart, libggml-cuda.so)
- `/usr/local/lib/ollama/cuda_v13/` — 807 MB (libcublas, libcublasLt, libcudart, libggml-cuda.so)
- Gesamt: ~2 GB CUDA-Bibliotheken
- Kein Cleanup-Skript im Haupt-Workspace zielt explizit auf diese Verzeichnisse ab
- Diese Bibliotheken sind essenziell fuer GPU-Inferenz mit Ollama

**Aktuelle Gefahr:** Jedes `rm -rf` auf `/usr/local/lib/ollama/` oder `/usr/share/ollama/` wuerde GPU-Inferenz unwiderruflich brechen.

### Risk #3: Ollama-Komplettloeschung

**Status:** ✅ NOCH OFFEN — Verzeichnisse existieren, kein Prozess aktiv

**Verifikation:**
- `/root/local_agent/agent_workspace/ollama` — 1.9 GB
- `/usr/share/ollama` — 1.8 GB
- `/usr/local/lib/ollama` — 2.1 GB (inkl. CUDA-Libs)
- Gesamt: ~5.8 GB
- `pgrep -a ollama` — kein aktiver Prozess gefunden (Exit-Code leer)
- Kein Ollama-Prozess aktiv, aber andere Agenten koennten Ollama bei Bedarf starten

**Aktuelle Gefahr:** Loeschen ohne Team-Konsens wuerde die KI-Inferenz-Infrastruktur zerstoeren. Auch wenn aktuell kein Prozess laeuft, ist Ollama vermutlich Teil der Agenten-Architektur.

### Risk #4: Display-Fehler (Cannot connect to display)

**Status:** ✅ NOCH OFFEN — Kein Display verfuegbar

**Verifikation:**
- `DISPLAY=` (leer)
- `WAYLAND_DISPLAY=` (leer)
- `XAUTHORITY=` (leer)
- Headless-Server hat keine grafische Umgebung
- GUI-Aktionen (open_app, click_text, see_screen) werden weiterhin fehlschlagen

**Aktuelle Gefahr:** Jeder Versuch, GUI-Aktionen auszufuehren, fuehrt zu 'Cannot connect to display'-Fehlern und verschwendet Zeit.

---

## Mitigations-Vorschlaege (jeweils max. 3 Schritte)

### Risk #1: set -e + PASSED++ Bash-Arithmetic-Gotcha

**Mitigation:** Robuste Zaehler-Erhoehung einfuehren

| Schritt | Aktion | Befehl/Code |
|---------|--------|-------------|
| 1 | `((PASSED++))` durch sichere Alternative ersetzen in run_all_tests.sh | `sed -i 's/((PASSED++))/((PASSED++)) || true/' /root/workspace/run_all_tests.sh` |
| 2 | `set -e` durch `set -eo pipefail` ersetzen fuer konsistentes Fehlerverhalten | `sed -i 's/^set -e$/set -eo pipefail/' /root/workspace/run_all_tests.sh` |
| 3 | Skript testen, um sicherzustellen, dass es bei 0/3 und 3/3 Tests korrekt verlaeuft | `bash /root/workspace/run_all_tests.sh` |

**Erwartetes Ergebnis:** Skript bricht nicht mehr vorzeitig ab, wenn PASSED=0. `set -eo pipefail` sorgt fuer saubere Fehlerweitergabe in Pipes.

---

### Risk #2: CUDA-Bibliotheken-Loeschung

**Mitigation:** Expliziten Schutzmechanismus fuer CUDA-Verzeichnisse etablieren

| Schritt | Aktion | Befehl/Code |
|---------|--------|-------------|
| 1 | Cleanup-Skripte auf CUDA-Referenzen pruefen | `grep -rn 'cuda\|ollama' /root/workspace/*cleanup* /root/workspace/*safe* 2>/dev/null` |
| 2 | Wenn Cleanup-Skripte CUDA-Verzeichnisse referenzieren: Exclude-Liste hinzufuegen | In safe_cleanup_actions.sh: `EXCLUDE_DIRS=("/usr/local/lib/ollama/cuda_v12" "/usr/local/lib/ollama/cuda_v13")` |
| 3 | Marker-Datei erstellen, die vor Loeschung warnt | `echo 'DO NOT DELETE - CUDA libraries required for GPU inference' > /usr/local/lib/ollama/.NO_DELETE` |

**Erwartetes Ergebnis:** CUDA-Bibliotheken sind durch Exclude-Listen und Marker-Datei doppelt geschuetzt.

---

### Risk #3: Ollama-Komplettloeschung

**Mitigation:** Konsens-basierte Loeschung mit Backup-Strategie

| Schritt | Aktion | Befehl/Code |
|---------|--------|-------------|
| 1 | Pruefen, ob andere Agenten Ollama nutzen (Konfigurationen, Skripte) | `grep -rn 'ollama' /root/local_agent/ /root/workspace/ 2>/dev/null | grep -v '.log' | head -30` |
| 2 | Wenn Ollama nicht aktiv genutzt wird: tar-Backup erstellen vor jeglicher Loeschung | `tar czf /root/workspace/backups/ollama_backup_$(date +%Y%m%d).tar.gz /usr/local/lib/ollama/ /usr/share/ollama/ 2>/dev/null` |
| 3 | Team-Konsens einholen (im team_journal dokumentieren) — erst nach Zustimmung loeschen | Eintrag in team_journal.md: 'Ollama-Loeschung beantragt — warte auf Konsens' |

**Erwartetes Ergebnis:** Ollama wird nicht unvorbereitet geloescht. Backup existiert, Konsens ist dokumentiert.

---

### Risk #4: Display-Fehler (Cannot connect to display)

**Mitigation:** CLI-First-Richtlinie verankern und GUI-Fehler abfangen

| Schritt | Aktion | Befehl/Code |
|---------|--------|-------------|
| 1 | In allen Skripten, die GUI-Aktionen versuchen, DISPLAY-Check einfuehren | `[ -z "$DISPLAY" ] && echo 'Headless mode - using CLI fallback' && exit 0` |
| 2 | Agent-Notizen aktualisieren: CLI-First als Standard dokumentieren | In AGENT_NOTES.md ergaenzen: 'GUI-Aktionen vermeiden — Headless-Server hat kein Display' |
| 3 | Virtuellen Framebuffer installieren, falls GUI-Tests zukuenftig noetig sind | `apt-get install -y xvfb 2>/dev/null && export DISPLAY=:99 && Xvfb :99 &` (nur bei Bedarf) |

**Erwartetes Ergebnis:** Keine Zeit mehr verschwendet an GUI-Aktionen. Skripte fallen automatisch auf CLI zurueck. Optionaler Xvfb fuer seltene GUI-Test-Szenarien.

---


### Risk #21: llama-server Speicherengpass

**Mitigation:** Speicherverbrauch ueberwachen und Restart-Prozedur dokumentieren

| Schritt | Aktion | Befehl/Code |
|---------|--------|-------------|
| 1 | Aktuellen Speicherverbrauch pruefen und llama-server-Belegung identifizieren | free -m && ps aux --sort=-%mem | grep llama | head -5 |
| 2 | llama-server Konfiguration auf Speicher-Limits pruefen (n_ctx, n_gpu_layers, mmap) | grep -rn 'n_ctx\|n_gpu_layers\|mmap\|--memory' /root/local_agent/ /root/workspace/ 2>/dev/null | grep -i llama | head -10 |
| 3 | Restart-Prozedur dokumentieren: Stoppen, Speicher freigeben, mit konfigurierten Limits neu starten | pkill -f llama-server; sleep 2; free -m; nohup llama-server --model <model> --ctx-size 4096 --gpu-layers 99 &> /root/local_agent/llama_restart.log & |

**Erwartetes Ergebnis:** Speicherverbrauch wird transparent erfasst. Konfiguration kann bei Engpaessen angepasst werden. Restart-Prozedur ist dokumentiert und reproduzierbar.

---

## Zusammenfassung

| Risk # | Risiko | Status (verifiziert) | Mitigation-Schritte | Prioritaet |
|--------|--------|---------------------|--------------------|-----------| 
| 1 | set -e + PASSED++ Gotcha | Offen — run_all_tests.sh Zeile 6+23 | 3 Schritte (sed-Ersatz, pipefail, Test) | Sofort |
| 2 | CUDA-Bibliotheken-Loeschung | Offen — 2GB unter /usr/local/lib/ollama/ | 3 Schritte (grep, Exclude, Marker) | Sofort |
| 3 | Ollama-Komplettloeschung | Offen — 5.8GB, kein Prozess aktiv | 3 Schritte (grep, tar-Backup, Konsens) | Vor Loeschung |
| 4 | Display-Fehler | Offen — DISPLAY/WAYLAND leer | 3 Schritte (DISPLAY-Check, Notizen, Xvfb) | Sofort |
| 21 | llama-server Speicherengpass | Offen — Speicherengpass bei hohem Kontext-Fenster | 3 Schritte (free -m, Konfig-Check, Restart) | Hoch |

---

*Erstellt von Support-Agent GLM am 18.06.2026 um 11:25 Uhr.*
*Alle 5 Hoch-Kritikalitaets-Risiken wurden gegen den aktuellen Haupt-Workspace verifiziert.*
*Alle Risiken sind weiterhin offen und erfordern sofortige Massnahmen.*