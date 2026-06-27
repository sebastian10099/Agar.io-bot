# QA Advisory: Monitoring Suite Review

**Reviewer:** Support-Agent GLM  
**Datum:** 2025-01-24  
**Pruefgegenstand:** `run_all_tests.sh` + `disk_space_monitor.sh` + `memory_monitor.sh` + `cpu_monitor.sh` (in `/root/workspace/`)  
**Methode:** Vollstaendiges Lesen aller 4 Skripte, manuelle Code-Analyse auf Edge Cases

---

## Identifizierte Risiken (5)

### Risiko 1: `set -e` + `((PASSED++))` Bash-Arithmetic-Gotcha (Kritisch)

**Datei:** `run_all_tests.sh`, Zeile mit `((PASSED++))`  
**Beschreibung:** In Bash gibt `((expr))` den Exit-Code 1 zurueck, wenn das Ergebnis 0 ist. Beim ersten erfolgreichen Test ist `PASSED=0`, und `((PASSED++))` wertet den *alten* Wert (0) aus → Exit-Code 1. Da `set -e` aktiv ist, bricht das Skript hier ab — **bevor** `[PASS]` ausgegeben wird.  
**Auswirkung:** Das Skript kann beim ersten bestandenen Test vorzeitig terminieren, je nach Bash-Version und Subshell-Kontext.  
**Empfehlung:** Verwende `((PASSED++)) || true` oder `PASSED=$((PASSED + 1))` (Assignment hat immer Exit-Code 0).

### Risiko 2: Fehlende Abhaengigkeit `bc` in cpu_monitor.sh (Hoch)

**Datei:** `cpu_monitor.sh`, Zeile: `CPU_USAGE=$(echo "100 - $CPU_IDLE" | bc)`  
**Beschreibung:** Das Skript verlaesst sich auf `bc` (Basic Calculator), das auf Minimal-Installationen (z.B. Alpine, Container-Images) oft nicht vorhanden ist. Fehlt `bc`, schlaegt die Substitution fehl — `CPU_USAGE` wird leer, und alle nachfolgenden Berechnungen/Vergleiche brechen mit Fehler ab.  
**Auswirkung:** CPU-Monitor komplett nicht funktionsfaehig auf Systemen ohne `bc`.  
**Empfehlung:** Pruefe zu Beginn: `command -v bc >/dev/null 2>&1 || { echo 'FEHLER: bc nicht installiert'; exit 1; }`. Alternativ: Verwende reine Bash-Arithmetic `$((100 - CPU_IDLE))` (erfordert Integer-Parsing von CPU_IDLE).

### Risiko 3: Division-by-Zero / Leere Variable in memory_monitor.sh (Hoch)

**Datei:** `memory_monitor.sh`, Zeile: `RAM_USAGE_PERCENT=$((RAM_USED * 100 / RAM_TOTAL))`  
**Beschreibung:** Wenn `free` nicht installiert ist oder der awk-Pattern `^Mem:` nicht trifft (z.B. andere Locale, andere `free`-Version), wird `RAM_TOTAL` leer. Die Division durch eine leere Variable fuehrt zu einem Bash-Arithmetic-Fehler (`division by 0` oder `attempted assignment to non-integer`).  
**Auswirkung:** Skript stuerzt mit unklarem Fehler ab, keine Ueberwachung.  
**Empfehlung:** Validiere vor der Berechnung: `[ -z "$RAM_TOTAL" ] || [ "$RAM_TOTAL" -eq 0 ] && { echo 'FEHLER: RAM_TOTAL konnte nicht ermittelt werden'; exit 1; }`

### Risiko 4: Hardcoded `BASE_DIR="/root/workspace"` — keine Portabilitaet (Mittel)

**Datei:** `run_all_tests.sh`, Zeile: `BASE_DIR="/root/workspace"`  
**Beschreibung:** Der Pfad ist absolut und fest auf `/root/workspace` codiert. Wird das Skript auf einem anderen System, in einem Container oder von einem Non-Root-User ausgefuehrt, schlagen alle Skript-Aufrufe fehl (`No such file or directory`).  
**Auswirkung:** Suite funktioniert nur in genau dieser einen Verzeichnisstruktur.  
**Empfehlung:** Verwende `BASE_DIR="$(dirname "$(readlink -f "$0")")"` fuer dynamische Pfad-Ermittlung.

### Risiko 5: Locale-abhaengiges `top`-Parsing in cpu_monitor.sh (Mittel)

**Datei:** `cpu_monitor.sh`, Zeile: `CPU_IDLE=$(top -bn2 | grep "%Cpu(s)" | tail -1 | awk '{print $8}')`  
**Beschreibung:** Das Parsing verlaesst sich auf das feste Feld `$8` in der `top`-Ausgabe. Bei anderen Locales (z.B. `de_DE.UTF-8`) kann die Spaltenreihenfolge abweichen oder `%Cpu(s)` heisst anders. Ausserdem ist `top -bn2` langsam (zwei Iterationen mit Sleep dazwischen).  
**Auswirkung:** `CPU_IDLE` wird leer oder enthaelt einen falschen Wert → CPU-Usage-Berechnung ungueltig.  
**Empfehlung:** Verwende `mpstat` (sysstat-Paket) oder `/proc/stat`-basierte Berechnung als robustere Alternative. Mindestens: Pruefe `[ -z "$CPU_IDLE" ]` und gib einen klaren Fehler aus.

---

## Zusammenfassung

| # | Risiko | Severity | Skript | Empfehlung |
|---|-------|----------|--------|-----------|
| 1 | `set -e` + `((PASSED++))` Gotcha | Kritisch | run_all_tests.sh | `PASSED=$((PASSED+1))` verwenden |
| 2 | Fehlendes `bc` | Hoch | cpu_monitor.sh | Dependency-Check oder Bash-Arithmetic |
| 3 | Division-by-Zero bei leerem RAM_TOTAL | Hoch | memory_monitor.sh | Input-Validierung vor Berechnung |
| 4 | Hardcoded BASE_DIR | Mittel | run_all_tests.sh | `$(dirname $(readlink -f $0))` |
| 5 | Locale-abhaengiges top-Parsing | Mittel | cpu_monitor.sh | `/proc/stat` oder `mpstat` verwenden |

**Gesamteinschaetzung:** Die Suite funktioniert im aktuellen Setup (Root, Standard-Locale, alle Tools installiert), ist aber nicht robust gegen fehlende Abhaengigkeiten, andere Locales oder Non-Root-Ausfuehrung. Risiko 1 ist potenziell kritisch und sollte priorisiert behoben werden.
