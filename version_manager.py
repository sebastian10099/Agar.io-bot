import logging
import os
import shutil
import json
import datetime
from typing import Dict, Any

class VersionManager:
    def __init__(self, base_dir: str = "agent_versions"):
        self.base_dir = base_dir
        self.current_version_file = os.path.join(base_dir, "current_version.txt")
        self.version_history_file = os.path.join(base_dir, "version_history.json")
        self._ensure_directories()
        
    def _ensure_directories(self):
        """Stellt sicher, dass die benötigten Verzeichnisse existieren"""
        if not os.path.exists(self.base_dir):
            os.makedirs(self.base_dir)
            
        versions_dir = os.path.join(self.base_dir, "versions")
        if not os.path.exists(versions_dir):
            os.makedirs(versions_dir)
            
    def create_version(self, version_name: str, source_dir: str, metrics: Dict[str, Any] = None):
        """Erstellt eine neue Version des Agenten-Codes"""
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        version_id = f"{version_name}_{timestamp}"
        version_dir = os.path.join(self.base_dir, "versions", version_id)
        
        # Kopiert den aktuellen Code in das Versionsverzeichnis
        if os.path.exists(version_dir):
            shutil.rmtree(version_dir)
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
            
        print(f"Version {version_id} erfolgreich erstellt.")
        return version_id
        
    def _update_version_history(self, metadata: Dict[str, Any]):
        """Aktualisiert die Versionshistorie"""
        history = []
        
        # Liest bestehende Historie
        if os.path.exists(self.version_history_file):
            with open(self.version_history_file, 'r') as f:
                history = json.load(f)
                
        # Fügt neue Version hinzu
        history.append(metadata)
        
        # Speichert aktualisierte Historie
        with open(self.version_history_file, 'w') as f:
            json.dump(history, f, indent=2)
            
    def get_current_version(self):
        """Gibt die aktuelle Version zurück"""
        if not os.path.exists(self.current_version_file):
            return None
            
        with open(self.current_version_file, 'r') as f:
            return f.read().strip()
            
    def list_versions(self):
        """Listet alle verfügbaren Versionen auf"""
        if not os.path.exists(self.version_history_file):
            return []
            
        with open(self.version_history_file, 'r') as f:
            return json.load(f)
            
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
    vm = VersionManager()
    
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