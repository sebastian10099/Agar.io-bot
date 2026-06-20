import logging
import os
import datetime
from pathlib import Path

def get_recent_files(directory='.', hours=24):
    """Listet Dateien auf, die innerhalb der letzten Stunden geändert wurden."""
    now = datetime.datetime.now()
    cutoff = now - datetime.timedelta(hours=hours)
    
    recent_files = []
    
    for root, dirs, files in os.walk(directory):
        for file in files:
            filepath = os.path.join(root, file)
            mtime = os.path.getmtime(filepath)
            modified_time = datetime.datetime.fromtimestamp(mtime)
            
            if modified_time > cutoff:
                recent_files.append((filepath, modified_time))
    
    return recent_files

if __name__ == "__main__":
    files = get_recent_files()
    print(f"Dateien, die innerhalb der letzten 24 Stunden geändert wurden:")
    for file, mod_time in files:
        print(f"{mod_time.strftime('%Y-%m-%d %H:%M:%S')} - {file}")