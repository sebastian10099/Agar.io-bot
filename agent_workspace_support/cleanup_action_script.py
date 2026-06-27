#!/usr/bin/env python3
"""
cleanup_action_script.py
=========================
Consolidated Backup Cleanup Script
Erstellt von: Support-Agent GLM
Datum: 2026-06-18

Quellen:
  - backup_cleanup_recommendation.md
  - backup_rotation_policy.md

Sicherheitsfeatures:
  1. Verschachtelte venv-Kopien in backups/ per shutil.rmtree loeschen
  2. Alte Backups behalten max 3, Rest loeschen
  3. Miniconda3-Installer-Dateien aus Backups entfernen
  4. Vor jedem Loeschen pruefen: Pfad existiert UND liegt im backups-Verzeichnis
  5. Am Ende freigegebenen Speicherplatz ausgeben

WICHTIG: Dieses Skript fuehrt KEINE automatische Ausfuehrung durch.
         Es ist nur eine Datei - muss manuell gestartet werden mit:
         python3 /root/local_agent/agent_workspace_support/cleanup_action_script.py
"""

import os
import shutil
import sys
from pathlib import Path
from datetime import datetime

# === KONSTANTEN ===
BACKUPS_DIR = Path("/root/local_agent/agent_workspace/backups")
MAX_BACKUPS_TO_KEEP = 3
MINICONDA_PATTERN = "Miniconda3-latest-Linux-x86_64.sh"
VENV_DIR_NAMES = {"venv", "__pycache__"}

# === SICHERHEITS-PRUEFUNKTION (Feature 4) ===
def is_safe_to_delete(path: Path) -> bool:
    """
    Prueft ob ein Pfad sicher geloescht werden kann:
    - Pfad muss existieren
    - Pfad muss innerhalb des backups-Verzeichnisses liegen
    - Pfad darf nicht das backups-Verzeichnis selbst sein
    """
    if not path.exists():
        print(f"  [SKIP] Pfad existiert nicht: {path}")
        return False
    
    try:
        resolved_path = path.resolve()
        resolved_backups = BACKUPS_DIR.resolve()
    except Exception as e:
        print(f"  [ERROR] Pfad-Aufloesung fehlgeschlagen: {path} - {e}")
        return False
    
    if resolved_path == resolved_backups:
        print(f"  [SKIP] Versuch, das backups-Verzeichnis selbst zu loeschen: {path}")
        return False
    
    if resolved_backups not in resolved_path.parents:
        print(f"  [SKIP] Pfad liegt NICHT im backups-Verzeichnis: {path}")
        return False
    
    return True

# === SPEICHERMESSUNG ===
def get_dir_size(path: Path) -> int:
    """Gibt die Groesse eines Verzeichnisses in Bytes zurueck."""
    total = 0
    try:
        for dirpath, dirnames, filenames in os.walk(path):
            for f in filenames:
                fp = os.path.join(dirpath, f)
                if not os.path.islink(fp):
                    try:
                        total += os.path.getsize(fp)
                    except OSError:
                        pass
    except Exception:
        pass
    return total

def format_size(size_bytes: int) -> str:
    """Formatiert Bytes in lesbare Groesse."""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.1f} MB"
    else:
        return f"{size_bytes / (1024 * 1024 * 1024):.2f} GB"

# === CLEANUP-AKTIONEN ===

def cleanup_nested_venv_copies() -> int:
    """
    Feature 1: Verschachtelte venv-Kopien in backups/ per shutil.rmtree loeschen.
    Sucht nach venv/ und __pycache__/ Verzeichnissen innerhalb von backup-Unterverzeichnissen.
    """
    print("\n=== Feature 1: Verschachtelte venv-Kopien loeschen ===")
    freed = 0
    
    if not BACKUPS_DIR.exists():
        print(f"  Backups-Verzeichnis nicht gefunden: {BACKUPS_DIR}")
        return 0
    
    for backup_subdir in BACKUPS_DIR.iterdir():
        if not backup_subdir.is_dir():
            continue
        
        # Suche nach venv/ und agent_versions/venv/ in jedem Backup
        for root, dirnames, _ in os.walk(backup_subdir):
            for dirname in dirnames:
                if dirname in VENV_DIR_NAMES:
                    venv_path = Path(root) / dirname
                    size = get_dir_size(venv_path)
                    if is_safe_to_delete(venv_path):
                        print(f"  [DELETE] {venv_path} ({format_size(size)})")
                        try:
                            shutil.rmtree(venv_path)
                            freed += size
                        except Exception as e:
                            print(f"  [ERROR] Loeschen fehlgeschlagen: {venv_path} - {e}")
                    
                    # Nach venv-Loeschung nicht weiter in dieses Verzeichnis absteigen
                    if dirname == "venv":
                        dirnames.clear()
            
            # Verschachtelte agent_versions/ suchen
            for dirname in list(dirnames):
                if dirname == "agent_versions":
                    agent_versions_path = Path(root) / dirname
                    # Pruefe ob dies eine verschachtelte Kopie ist (innerhalb eines backups)
                    if agent_versions_path != BACKUPS_DIR / "stable_version" / "agent_versions":
                        # Nur venv darin loeschen, nicht das ganze agent_versions
                        pass
    
    print(f"  --> Freigegeben: {format_size(freed)}")
    return freed


def cleanup_old_backups() -> int:
    """
    Feature 2: Alte Backups behalten max 3, Rest loeschen.
    Behaelt die 3 neuesten Backup-Verzeichnisse, loescht den Rest.
    """
    print("\n=== Feature 2: Alte Backups auf max 3 reduzieren ===")
    freed = 0
    
    if not BACKUPS_DIR.exists():
        print(f"  Backups-Verzeichnis nicht gefunden: {BACKUPS_DIR}")
        return 0
    
    # Alle Backup-Unterverzeichnisse sammeln (ausser stable_version)
    backup_dirs = []
    for item in BACKUPS_DIR.iterdir():
        if item.is_dir() and item.name.startswith("backup_"):
            backup_dirs.append(item)
    
    if len(backup_dirs) <= MAX_BACKUPS_TO_KEEP:
        print(f"  Nur {len(backup_dirs)} Backups vorhanden, max {MAX_BACKUPS_TO_KEEP} - nichts zu tun.")
        return 0
    
    # Nach Aenderungszeit sortieren (neueste zuerst)
    backup_dirs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    
    # Behalte die neuesten MAX_BACKUPS_TO_KEEP, loesche den Rest
    to_keep = backup_dirs[:MAX_BACKUPS_TO_KEEP]
    to_delete = backup_dirs[MAX_BACKUPS_TO_KEEP:]
    
    print(f"  Behalte {len(to_keep)} neueste Backups:")
    for d in to_keep:
        print(f"    [KEEP] {d.name}")
    
    print(f"  Loesche {len(to_delete)} alte Backups:")
    for d in to_delete:
        size = get_dir_size(d)
        if is_safe_to_delete(d):
            print(f"    [DELETE] {d.name} ({format_size(size)})")
            try:
                shutil.rmtree(d)
                freed += size
            except Exception as e:
                print(f"    [ERROR] Loeschen fehlgeschlagen: {d.name} - {e}")
    
    print(f"  --> Freigegeben: {format_size(freed)}")
    return freed


def cleanup_miniconda_installers() -> int:
    """
    Feature 3: Miniconda3-Installer-Dateien aus Backups entfernen.
    Sucht und loescht alle Miniconda3-latest-Linux-x86_64.sh Dateien in backups/.
    """
    print("\n=== Feature 3: Miniconda3-Installer aus Backups entfernen ===")
    freed = 0
    
    if not BACKUPS_DIR.exists():
        print(f"  Backups-Verzeichnis nicht gefunden: {BACKUPS_DIR}")
        return 0
    
    for root, _, filenames in os.walk(BACKUPS_DIR):
        for filename in filenames:
            if MINICONDA_PATTERN in filename or filename.startswith("Miniconda3"):
                filepath = Path(root) / filename
                if is_safe_to_delete(filepath):
                    try:
                        size = filepath.stat().st_size
                        print(f"  [DELETE] {filepath} ({format_size(size)})")
                        filepath.unlink()
                        freed += size
                    except Exception as e:
                        print(f"  [ERROR] Loeschen fehlgeschlagen: {filepath} - {e}")
    
    print(f"  --> Freigegeben: {format_size(freed)}")
    return freed


def cleanup_empty_dirs() -> int:
    """
    Bonus: Leere Verzeichnisse im backups-Ordner entfernen.
    """
    print("\n=== Bonus: Leere Verzeichnisse entfernen ===")
    freed = 0
    
    if not BACKUPS_DIR.exists():
        return 0
    
    # Von tiefster Ebene nach oben gehen
    for root, dirnames, filenames in os.walk(BACKUPS_DIR, topdown=False):
        for dirname in dirnames:
            dirpath = Path(root) / dirname
            try:
                if dirpath.is_dir() and not any(dirpath.iterdir()):
                    if is_safe_to_delete(dirpath):
                        dirpath.rmdir()
                        print(f"  [DELETE-EMPTY] {dirpath}")
            except Exception as e:
                pass  # Ignoriere Fehler bei leeren Verzeichnissen
    
    return freed


# === HAUPTFUNKTION ===
def main():
    print("=" * 60)
    print("  BACKUP CLEANUP ACTION SCRIPT")
    print("  Erstellt von: Support-Agent GLM")
    print("  Datum: 2026-06-18")
    print("=" * 60)
    print(f"\nBackups-Verzeichnis: {BACKUPS_DIR}")
    print(f"Max Backups to keep: {MAX_BACKUPS_TO_KEEP}")
    
    if not BACKUPS_DIR.exists():
        print(f"\n[FEHLER] Backups-Verzeichnis existiert nicht: {BACKUPS_DIR}")
        sys.exit(1)
    
    # Speicher vor Cleanup messen
    size_before = get_dir_size(BACKUPS_DIR)
    print(f"\nAktuelle Groesse des backups-Verzeichnisses: {format_size(size_before)}")
    
    total_freed = 0
    
    # Feature 1: Verschachtelte venv-Kopien loeschen
    total_freed += cleanup_nested_venv_copies()
    
    # Feature 3: Miniconda3-Installer entfernen (vor Feature 2, damit weniger zu loeschen ist)
    total_freed += cleanup_miniconda_installers()
    
    # Feature 2: Alte Backups auf max 3 reduzieren
    total_freed += cleanup_old_backups()
    
    # Bonus: Leere Verzeichnisse entfernen
    cleanup_empty_dirs()
    
    # Feature 5: Freigegebenen Speicherplatz ausgeben
    print("\n" + "=" * 60)
    print("  ZUSAMMENFASSUNG")
    print("=" * 60)
    print(f"  Speicher vor Cleanup:  {format_size(size_before)}")
    print(f"  Freigegeben:           {format_size(total_freed)}")
    
    size_after = get_dir_size(BACKUPS_DIR)
    print(f"  Speicher nach Cleanup: {format_size(size_after)}")
    print(f"  Reduktion:             {format_size(size_before - size_after)}")
    print("=" * 60)
    print("\nCleanup abgeschlossen.")


if __name__ == "__main__":
    main()
