# Backup Cleanup Recommendation

**Erstellt von:** Support-Agent GLM  
**Datum:** 2026-06-18  
**Basis:** disk_usage_investigation.md (6.4G Backup-Verzeichnis als groesster Verbraucher)

---

## 1. Zusammenfassung

Das Backup-Verzeichnis `/root/local_agent/agent_workspace/backups/` belegt **6.4 GB** und ist der groesste einzelne Speicherverbraucher. Die Analyse zeigt massive Redundanz durch duplizierte Backups und unnecessarily grosse venv-Kopien.

| Kategorie | Groesse | Anzahl | Status |
|----------|--------|-------|--------|
| stable_version/ | 2.3 GB | 1 | Enthaelt 2.2 GB agent_versions mit eigener venv-Kopie |
| backup_20260618_* | 156 MB x 6 = 936 MB | 6 | Alle enthalten identischen Miniconda3-Installer (gleiche MD5) |
| backup_2026-06-17_* | 956 KB x 3 = 2.8 MB | 3 | Nahezu identische kleine Backups |
| backup_2026-06-10_12-00-00 | 4.0 KB | 1 | Leeres Verzeichnis (0 Dateien) |
| backup_2023-* | 0 KB | mehrere | Leere Verzeichnisse (0 Dateien) |
| **Total** | **6.4 GB** | | |

---

## 2. Detaillierte Backup-Datei-Liste

### 2.1 stable_version/ (2.3 GB)

| Pfad | Groesse | Datum | Bemerkung |
|------|---------|-------|----------|
| stable_version/venv/ | 56 MB | Jun 16 | Python Virtual Environment (pip, psutil etc.) |
| stable_version/agent_versions/versions/benchmark_optimized_20260616_195151/ | 2.2 GB | Jun 16 | Enthaelt EIGENE venv-Kopie (56 MB) + Python-Dateien |
| stable_version/*.py (agent_main.py, analyzer.py, etc.) | ~30 KB | Jun 16 | Quellcode-Dateien |
| stable_version/*.sh | ~10 KB | Jun 16 | Shell-Skripte |
| stable_version/tests/ | <1 KB | Jun 16 | Test-Dateien |

**Problem:** Die `agent_versions/` enthaelt eine vollstaendige verschachtelte Kopie des Workspaces inklusive einer eigenen `venv/` (56 MB). Die `stable_version/venv/` ist ebenfalls redundant, da der Live-Workspace bereits eine venv hat.

### 2.2 backup_20260618_* (6 Verzeichnisse, je 156 MB)

| Verzeichnis | Groesse | Dateien | Datum | Bemerkung |
|-------------|---------|---------|-------|----------|
| backup_20260618_150341 | 156 MB | 36 | Jun 18 15:03 | Aeltestes, weniger Dateien |
| backup_20260618_150933 | 156 MB | 38 | Jun 18 15:09 | |
| backup_20260618_151349 | 156 MB | 38 | Jun 18 15:13 | |
| backup_20260618_151721 | 156 MB | 39 | Jun 18 15:17 | |
| backup_20260618_151725 | 156 MB | 39 | Jun 18 15:17 | 4 Sekunden nach vorigem! |
| backup_20260618_151835 | 156 MB | 39 | Jun 18 15:18 | Neuestes |

**Kritischer Befund:** Alle 6 Verzeichnisse enthalten die Datei `Miniconda3-latest-Linux-x86_64.sh` mit **identischer MD5-Summe** (5eb314581f476f57526204386ea87af8). Das bedeutet: 6x 156 MB = 936 MB, davon sind ca. 936 MB - 156 MB = **780 MB reine Redundanz**.

### 2.3 backup_2026-06-17_* (3 Verzeichnisse, je 956 KB)

| Verzeichnis | Groesse | Datum | Bemerkung |
|-------------|---------|-------|----------|
| backup_2026-06-17_17-35-09 | 956 KB | Jun 17 17:35 | Aeltestes |
| backup_2026-06-17_17-38-28 | 956 KB | Jun 17 17:38 | 3 Min nach vorigem |
| backup_2026-06-17_17-38-33 | 956 KB | Jun 17 17:38 | 5 Sek nach vorigem! |

Inhalt: Kleine Backups mit .md-Dateien, __pycache__, agent_versions, leere logs/ollama/results/tests/venv-Ordner. Nahezu identisch.

### 2.4 Leere/Veraltete Verzeichnisse

| Verzeichnis | Groesse | Dateien | Bemerkung |
|-------------|---------|---------|----------|
| backup_2026-06-10_12-00-00 | 4.0 KB | 0 | Vollstaendig leer |
| backup_2023-* (mehrere) | 0 KB | 0 | Vollstaendig leer |

---

## 3. Identifizierte Cleanup-Ziele

### Prioritaet 1: Redundante backup_20260618_* Verzeichnisse (Einsparung: ~780 MB)

6 Backups innerhalb von 15 Minuten erstellt, alle mit identischem Miniconda3-Installer. Nur das neueste (`backup_20260618_151835`) sollte behalten werden.

**Zu loeschen (5 von 6):**
- backup_20260618_150341
- backup_20260618_150933
- backup_20260618_151349
- backup_20260618_151721
- backup_20260618_151725

### Prioritaet 2: stable_version/agent_versions/ venv-Kopie (Einsparung: ~2.2 GB)

Die `agent_versions/versions/benchmark_optimized_20260616_195151/` enthaelt eine vollstaendige verschachtelte Workspace-Kopie mit eigener venv (56 MB). Die Python-Quellcode-Dateien sind klein, aber die venv-Kopie ist redundant.

**Zu loeschen:**
- `stable_version/agent_versions/versions/benchmark_optimized_20260616_195151/venv/` (56 MB)
- `stable_version/agent_versions/versions/benchmark_optimized_20260616_195151/agent_versions/` (verschachtelte Rekursion)

**Alternative:** Gesamtes `stable_version/agent_versions/` loeschen, wenn keine Versionierung benoetigt wird (2.2 GB).

### Prioritaet 3: stable_version/venv/ (Einsparung: 56 MB)

Die venv im stable_version-Backup ist eine Kopie der Live-venv und kann bei Bedarf neu erstellt werden.

### Prioritaet 4: Redundante backup_2026-06-17_* Verzeichnisse (Einsparung: ~1.9 MB)

3 Backups innerhalb von 3 Minuten. Nur das neueste (`backup_2026-06-17_17-38-33`) behalten.

**Zu loeschen (2 von 3):**
- backup_2026-06-17_17-35-09
- backup_2026-06-17_17-38-28

### Prioritaet 5: Leere Verzeichnisse (Einsparung: minimal, aber aufraeumend)

- backup_2026-06-10_12-00-00 (leer)
- backup_2023-* (leer)
