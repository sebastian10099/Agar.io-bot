import logging
import os
import hashlib

def get_file_hash(file_path):
    """Berechnet den MD5-Hash einer Datei."""
    hash_md5 = hashlib.md5()
    try:
        with open(file_path, "rb") as f:
            for chunk in iter(lambda: f.read(4096), b""):
                hash_md5.update(chunk)
        return hash_md5.hexdigest()
    except Exception as e:
        print(f"Fehler beim Lesen der Datei {file_path}: {e}")
        return None

def find_duplicates(root_folder):
    """Findet Duplikate basierend auf Größe und MD5-Hash."""
    size_hash_map = {}
    duplicates = []

    for dirpath, _, filenames in os.walk(root_folder):
        for filename in filenames:
            file_path = os.path.join(dirpath, filename)
            try:
                file_size = os.path.getsize(file_path)
                file_hash = get_file_hash(file_path)
                if file_hash is None:
                    continue

                if (file_size, file_hash) in size_hash_map:
                    duplicates.append((file_path, size_hash_map[(file_size, file_hash)]))
                else:
                    size_hash_map[(file_size, file_hash)] = file_path
            except OSError as e:
                print(f"Fehler beim Zugriff auf {file_path}: {e}")

    return duplicates

def main():
    workspace = "/root/local_agent/agent_workspace"
    print(f"Suche nach Duplikaten im Verzeichnis: {workspace}")
    duplicates = find_duplicates(workspace)
    if duplicates:
        print("\nGefundene Duplikate:")
        for dup in duplicates:
            print(f"{dup[0]} ist ein Duplikat von {dup[1]}")
    else:
        print("Keine Duplikate gefunden.")

if __name__ == "__main__":
    main()
