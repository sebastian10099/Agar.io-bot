import logging
import os
import sys

def format_size(size_bytes):
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024**2:
        return f"{size_bytes / 1024:.2f} KB"
    elif size_bytes < 1024**3:
        return f"{size_bytes / 1024**2:.2f} MB"
    else:
        return f"{size_bytes / 1024**3:.2f} GB"

def find_large_files(directory, min_size_mb=1):
    min_size_bytes = min_size_mb * 1024 * 1024
    large_files = []
    
    for root, dirs, files in os.walk(directory):
        for file in files:
            file_path = os.path.join(root, file)
            try:
                file_size = os.path.getsize(file_path)
                if file_size > min_size_bytes:
                    large_files.append((file_path, file_size))
            except (OSError, FileNotFoundError):
                # Datei konnte nicht gelesen werden
                pass
    
    # Sortiere nach Dateigröße, größte zuerst
    large_files.sort(key=lambda x: x[1], reverse=True)
    
    return large_files

def main():
    workspace_dir = "/root/local_agent/agent_workspace"
    min_size_mb = 1  # Standardwert
    
    if len(sys.argv) > 1:
        workspace_dir = sys.argv[1]
    if len(sys.argv) > 2:
        min_size_mb = float(sys.argv[2])
    
    print(f"Suche große Dateien in: {workspace_dir}")
    print(f"Schwellwert: {min_size_mb} MB")
    large_files = find_large_files(workspace_dir, min_size_mb)
    
    if not large_files:
        print(f"Keine Dateien über {min_size_mb} MB gefunden.")
        return
    
    print(f"\nGefundene Dateien über {min_size_mb} MB ({len(large_files)} Dateien):\n")
    for file_path, size in large_files:
        formatted_size = format_size(size)
        print(f"{formatted_size:>10} - {file_path}")

if __name__ == "__main__":
    main()
