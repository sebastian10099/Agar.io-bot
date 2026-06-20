# track_task_result.py
import logging
import csv
import os
from datetime import datetime

def log_task_result(task_id, status):
    """Loggt das Ergebnis einer Aufgabe in einer CSV-Datei."""
    file_path = 'task_results.csv'
    file_exists = os.path.isfile(file_path)
    
    with open(file_path, mode='a', newline='') as file:
        writer = csv.writer(file)
        if not file_exists:
            writer.writerow(['task_id', 'status', 'timestamp'])
        writer.writerow([task_id, status, datetime.now()])

def calculate_success_rate():
    """Berechnet die Aufgaben-Erfolgsrate."""
    file_path = 'task_results.csv'
    if not os.path.isfile(file_path):
        return 0.0
    
    success_count = 0
    total_count = 0
    
    with open(file_path, mode='r') as file:
        reader = csv.DictReader(file)
        for row in reader:
            total_count += 1
            if row['status'] == 'success':
                success_count += 1
    
    if total_count == 0:
        return 0.0
    
    return (success_count / total_count) * 100

def main():
    # Beispiel für die Verwendung
    log_task_result('task_001', 'success')
    log_task_result('task_002', 'failure')
    log_task_result('task_003', 'success')
    
    success_rate = calculate_success_rate()
    print(f'Aufgaben-Erfolgsrate: {success_rate:.2f}%')

if __name__ == '__main__':
    main()
