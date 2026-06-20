# analyzer.py

import logging
import os
import subprocess
import re
from datetime import datetime


def analyze_code(code_path):
    """
    Analysiert den aktuellen Code des Agenten.
    Identifiziert potenzielle Schwächen oder Verbesserungsmöglichkeiten.
    """
    print(f"Analysiere Code in {code_path}...")
    issues = []
    
    # Durchsuche alle Python-Dateien nach Platzhaltern
    for root, dirs, files in os.walk(code_path):
        for file in files:
            if file.endswith('.py'):
                file_path = os.path.join(root, file)
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                    if 'Platzhalter' in content or '# TODO' in content or 'pass\n' in content:
                        issues.append(f"Platzhalter/TODO gefunden in {file_path}")
    
    # Prüfe auf ungenutzte Module
    try:
        result = subprocess.run(['python3', '-m', 'pyflakes', code_path], 
                              capture_output=True, text=True, timeout=30)
        if result.stdout:
            issues.extend(result.stdout.split('\n'))
    except subprocess.TimeoutExpired:
        issues.append("Code-Check timed out")
    except FileNotFoundError:
        issues.append("pyflakes nicht gefunden - Installationsvoraussetzung fehlt")
    
    return issues


def analyze_performance(log_path):
    """
    Analysiert die Performance des Agenten basierend auf Logs.
    """
    print(f"Analysiere Performance anhand von Logs in {log_path}...")
    metrics = {}
    
    # Prüfe Log-Dateien auf Fehler und Laufzeiten
    if os.path.exists(log_path):
        for log_file in os.listdir(log_path):
            if log_file.endswith('.log'):
                with open(os.path.join(log_path, log_file), 'r') as f:
                    content = f.read()
                    error_count = content.count('ERROR')
                    warning_count = content.count('WARNING')
                    metrics[log_file] = {
                        'errors': error_count,
                        'warnings': warning_count,
                        'size_bytes': len(content)
                    }
    
    return metrics


def analyze_file_sizes(path, threshold_mb=0.1):
    """
    Analysiert Dateigrößen im Workspace.
    """
    print(f"Analysiere Dateigrößen in {path}...")
    large_files = []
    
    for root, dirs, files in os.walk(path):
        # Überspringe Backup- und Log-Verzeichnisse
        dirs[:] = [d for d in dirs if d not in ['backups', 'logs', '__pycache__']]
        
        for file in files:
            file_path = os.path.join(root, file)
            try:
                size = os.path.getsize(file_path)
                if size > threshold_mb * 1024 * 1024:  # Konvertiere MB zu Bytes
                    large_files.append((file_path, size))
            except OSError:
                pass  # Datei nicht zugänglich
    
    return large_files


if __name__ == "__main__":
    # Beispielaufrufe
    code_issues = analyze_code("./")
    print("Code-Analyse-Ergebnisse:", code_issues)
    
    perf_metrics = analyze_performance("./logs")
    print("Performance-Metriken:", perf_metrics)
    
    large_files = analyze_file_sizes("./")
    print("Große Dateien gefunden:", large_files)