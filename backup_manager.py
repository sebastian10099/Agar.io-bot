# backup_manager.py

import logging
import os
import shutil

def create_backup(source_path, backup_path):
    """
    Erstellt ein Backup der aktuellen stabilen Version.
    """
    print(f"Erstelle Backup von {source_path} nach {backup_path}...")
    
    # Sicherstellen, dass das Backup-Verzeichnis existiert
    os.makedirs(backup_path, exist_ok=True)
    
    # Kopiere alle Dateien außer Backup-, Log- und Ergebnis-Verzeichnisse
    for item in os.listdir(source_path):
        if item not in ['backups', 'logs', 'results', '__pycache__']:
            source_item = os.path.join(source_path, item)
            backup_item = os.path.join(backup_path, item)
            
            # Entferne alte Backup-Dateien
            if os.path.exists(backup_item):
                if os.path.isdir(backup_item):
                    shutil.rmtree(backup_item)
                else:
                    os.remove(backup_item)
            
            # Kopiere neue Dateien
            if os.path.isdir(source_item):
                shutil.copytree(source_item, backup_item)
            else:
                shutil.copy2(source_item, backup_item)
    
    print("Backup erstellt.")

def restore_backup(backup_path, restore_path):
    """
    Stellt die letzte stabile Version wieder her.
    """
    print(f"Stelle Backup von {backup_path} nach {restore_path} wieder her...")
    
    # Kopiere alle Dateien aus dem Backup zurück
    for item in os.listdir(backup_path):
        backup_item = os.path.join(backup_path, item)
        restore_item = os.path.join(restore_path, item)
        
        # Entferne alte Dateien
        if os.path.exists(restore_item):
            if os.path.isdir(restore_item):
                shutil.rmtree(restore_item)
            else:
                os.remove(restore_item)
        
        # Kopiere Backup-Dateien zurück
        if os.path.isdir(backup_item):
            shutil.copytree(backup_item, restore_item)
        else:
            shutil.copy2(backup_item, restore_item)
    
    print("Backup wiederhergestellt.")

if __name__ == "__main__":
    # Beispielaufrufe
    create_backup("./", "./backups/stable_version")
    restore_backup("./backups/stable_version", "./")