import logging
import os
import shutil
import json
import datetime
from typing import Dict, Any

class OptimizedVersionManager:
    def __init__(self, base_dir: str = "agent_versions"):
        self.base_dir = base_dir
        self.current_version_file = os.path.join(base_dir, "current_version.txt")
        self.version_history_file = os.path.join(base_dir, "version_history.json")
        self._ensure_directories()
        
    def _ensure_directories(self):
        """Stellt sicher, dass die benötigten Verzeichnisse existieren"""
        os.makedirs(self.base_dir, exist_ok=True)
        os.makedirs(os.path.join(self.base_dir, "versions"), exist_ok=True)
        
    def create_version(self, version_name: str, source_dir: str, metrics: Dict[str, Any] = None):
        """Erstellt eine neue Version des Agenten-Codes (optimiert)"""
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        version_id = f"{version_name}_{timestamp}"
        version_dir = os.path.join(self.base_dir, "versions", version_id)
        
        # Verwendet hardlinks für Dateien, die sich nicht geändert haben (schneller)
        if os.path.exists(version_dir):
            shutil.rmtree(version_dir)
            
        try:
            # Versucht zuerst Hardlinks zu verwenden (schneller, spart Speicher)
            self._copy_with_hardlinks(source_dir, version_dir)
        except (OSError, PermissionError):
            # Fallback auf normales Kopieren
            shutil.copytree(source_dir, version_dir)
        
        # Erstellt Metadaten für die Version
        metadata = {
            "version_id": version_id,
            "version_name": version_name,
            "timestamp": timestamp,
            "metrics": metrics or {},
            "path": version_dir
        }
        
        # Speichert Metadaten
        metadata_file = os.path.join(version_dir, "metadata.json")
        with open(metadata_file, 'w') as f:
            json.dump(metadata, f, indent=2)
            
        # Aktualisiert die Versionshistorie
        self._update_version_history(metadata)
        
        # Aktualisiert die aktuelle Version
        with open(self.current_version_file, 'w') as f:
            f.write(version_id)
            
        print(f"Version {version_id} erfolgreich erstellt (optimiert).")
        return version_id
        
    def _copy_with_hardlinks(self, src: str, dst: str):
        """Kopiert Dateien mit Hardlinks wo möglich, Dateien sonst"""
        os.makedirs(dst, exist_ok=True)
        
        for root, dirs, files in os.walk(src):
            rel_path = os.path.relpath(root, src)
            dst_dir = os.path.join(dst, rel_path) if rel_path != "." else dst
            os.makedirs(dst_dir, exist_ok=True)
            
            for file in files:
                src_file = os.path.join(root, file)
                dst_file = os.path.join(dst_dir, file)
                
                try:
                    # Versucht Hardlink zu erstellen (sehr schnell)
                    os.link(src_file, dst_file)
                except (OSError, PermissionError):
                    # Fallback auf normales Kopieren
                    shutil.copy2(src_file, dst_file)
        
    def _update_version_history(self, metadata: Dict[str, Any]):
        """Aktualisiert die Versionshistorie"""
        history = []
        
        # Liest bestehende Historie
        if os.path.exists(self.version_history_file):
            try:
                with open(self.version_history_file, 'r') as f:
                    history = json.load(f)
            except json.JSONDecodeError:
                # Falls Datei korrupt ist, beginnt neu
                pass
                
        # Fügt neue Version hinzu
        history.append(metadata)
        
        # Begrenzt auf 50 Einträge um Speicher zu sparen
        if len(history) > 50:
            history = history[-50:]
        
        # Speichert aktualisierte Historie
        with open(self.version_history_file, 'w') as f:
            json.dump(history, f, indent=2)
            
    def get_current_version(self):
        """Gibt die aktuelle Version zurück"""
        try:
            with open(self.current_version_file, 'r') as f:
                return f.read().strip()
        except FileNotFoundError:
            return None
            
    def list_versions(self):
        """Listet alle verfügbaren Versionen auf"""
        try:
            with open(self.version_history_file, 'r') as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return []
            
    def rollback_to_version(self, version_id: str):
        """Rollt zu einer bestimmten Version zurück"""
        version_dir = os.path.join(self.base_dir, "versions", version_id)
        
        if not os.path.exists(version_dir):
            raise ValueError(f"Version {version_id} nicht gefunden.")
            
        # Aktualisiert die aktuelle Version
        with open(self.current_version_file, 'w') as f:
            f.write(version_id)
            
        print(f"Zu Version {version_id} zurückgerollt.")
        return version_id

# Beispiel für die Verwendung des Moduls
if __name__ == "__main__":
    vm = OptimizedVersionManager()
    
    # Simuliert das Erstellen einer neuen Version
    sample_metrics = {
        "avg_response_speed": 0.0116,
        "avg_token_efficiency": 86302.86,
        "success_rate": 100.0
    }
    
    # Erstellt eine neue Version
    version_id = vm.create_version(
        version_name="benchmark_optimized",
        source_dir=".",  # Aktuelles Verzeichnis
        metrics=sample_metrics
    )
    
    # Zeigt die aktuelle Version an
    print(f"Aktuelle Version: {vm.get_current_version()}")
    
    # Listet alle Versionen auf
    print("\nVersionshistorie:")
    for version in vm.list_versions():
        print(f"- {version['version_id']}: {version['version_name']} ({version['timestamp']})")