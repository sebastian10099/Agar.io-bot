# agent_main.py

import logging
import track_task_result
import os

def execute_task(task_id, task_function):
    """Führt eine Aufgabe aus und protokolliert das Ergebnis."""
    try:
        task_function()
        track_task_result.log_task_result(task_id, 'success')
        print(f"Aufgabe {task_id} erfolgreich abgeschlossen.")
    except Exception as e:
        track_task_result.log_task_result(task_id, 'failure')
        print(f"Aufgabe {task_id} fehlgeschlagen: {e}")

def sample_task_1():
    """Eine Beispiel-Aufgabe, die immer erfolgreich ist."""
    pass

def sample_task_2():
    """Eine Beispiel-Aufgabe, die immer fehlschlägt."""
    raise Exception("Absichtliches Fehlschlagen für Testzwecke")

def main():
    """Hauptfunktion des Agenten."""
    print("KI-Agent gestartet. Aufgaben werden ausgeführt und Ergebnisse getrackt.")
    
    # Beispiel für das Ausführen von Aufgaben
    execute_task('task_001', sample_task_1)
    execute_task('task_002', sample_task_2)
    
    # Erfolgsrate berechnen und anzeigen
    success_rate = track_task_result.calculate_success_rate()
    print(f"Aktuelle Aufgaben-Erfolgsrate: {success_rate:.2f}%")

if __name__ == '__main__':
    main()
