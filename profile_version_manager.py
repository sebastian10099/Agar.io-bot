import cProfile
import pstats
import os
import shutil
import tempfile
from version_manager import VersionManager
from optimized_version_manager import OptimizedVersionManager

def create_test_structure(base_dir, num_files=100, file_size=1024):
    """Erstellt eine Teststruktur mit vielen Dateien"""
    os.makedirs(base_dir, exist_ok=True)
    
    # Erstellt Testdateien
    for i in range(num_files):
        file_path = os.path.join(base_dir, f"test_file_{i}.txt")
        with open(file_path, 'w') as f:
            f.write('A' * file_size)  # Schreibt file_size Zeichen

def profile_original():
    """Profilieren des Original-VersionManagers"""
    print("Profilieren des Original-VersionManagers...")
    
    # Erstellt Testdaten
    with tempfile.TemporaryDirectory() as tmpdir:
        source_dir = os.path.join(tmpdir, "source")
        create_test_structure(source_dir)
        
        # Erstellt VersionManager
        vm = VersionManager(base_dir=os.path.join(tmpdir, "agent_versions"))
        
        # Profilieren
        pr = cProfile.Profile()
        pr.enable()
        
        # Erstellt mehrere Versionen
        for i in range(5):
            vm.create_version(f"test_version_{i}", source_dir)
        
        pr.disable()
        
        # Speichert Statistiken
        stats_file = "original_stats.prof"
        pr.dump_stats(stats_file)
        
        # Zeigt Top-Funktionen
        ps = pstats.Stats(pr)
        ps.sort_stats('cumulative')
        ps.print_stats(10)
        
        return stats_file

def profile_optimized():
    """Profilieren des optimierten VersionManagers"""
    print("\nProfilieren des optimierten VersionManagers...")
    
    # Erstellt Testdaten
    with tempfile.TemporaryDirectory() as tmpdir:
        source_dir = os.path.join(tmpdir, "source")
        create_test_structure(source_dir)
        
        # Erstellt OptimizedVersionManager
        vm = OptimizedVersionManager(base_dir=os.path.join(tmpdir, "agent_versions"))
        
        # Profilieren
        pr = cProfile.Profile()
        pr.enable()
        
        # Erstellt mehrere Versionen
        for i in range(5):
            vm.create_version(f"test_version_{i}", source_dir)
        
        pr.disable()
        
        # Speichert Statistiken
        stats_file = "optimized_stats.prof"
        pr.dump_stats(stats_file)
        
        # Zeigt Top-Funktionen
        ps = pstats.Stats(pr)
        ps.sort_stats('cumulative')
        ps.print_stats(10)
        
        return stats_file

def main():
    """Hauptfunktion zum Profilieren beider Versionen"""
    print("Starte Profiling...")
    
    # Profilieren
    original_stats = profile_original()
    optimized_stats = profile_optimized()
    
    print(f"\nOriginal Statistiken gespeichert in: {original_stats}")
    print(f"Optimierte Statistiken gespeichert in: {optimized_stats}")
    
    print("\nProfiling abgeschlossen.")

if __name__ == "__main__":
    main()