import logging
import time
import psutil
import os

class MetricsCollector:
    def __init__(self):
        self.start_time = None
        self.start_tokens = 0
        self.task_count = 0
        self.successful_tasks = 0

    def start_task(self, initial_tokens=0):
        """Startet die Erfassung für eine neue Aufgabe"""
        self.start_time = time.time()
        self.start_tokens = initial_tokens
        self.task_count += 1

    def end_task(self, final_tokens=0, success=True):
        """Beendet die Erfassung für die aktuelle Aufgabe und berechnet Metriken"""
        if self.start_time is None:
            raise ValueError("No task is currently running. Call start_task() first.")
        
        elapsed_time = time.time() - self.start_time
        token_count = final_tokens - self.start_tokens
        
        if success:
            self.successful_tasks += 1
        
        # Metriken berechnen
        response_speed = elapsed_time  # Sekunden
        token_efficiency = token_count / elapsed_time if elapsed_time > 0 else 0  # Tokens pro Sekunde
        success_rate = (self.successful_tasks / self.task_count) * 100  # Prozent
        
        return {
            'response_speed': response_speed,
            'token_efficiency': token_efficiency,
            'success_rate': success_rate,
            'task_count': self.task_count,
            'successful_tasks': self.successful_tasks
        }

    def get_system_metrics(self):
        """Erfasst zusätzliche Systemmetriken"""
        cpu_percent = psutil.cpu_percent(interval=1)
        memory_info = psutil.virtual_memory()
        disk_usage = psutil.disk_usage('/')
        
        return {
            'cpu_percent': cpu_percent,
            'memory_percent': memory_info.percent,
            'disk_usage_percent': (disk_usage.used / disk_usage.total) * 100
        }

# Beispiel für die Verwendung des Moduls
if __name__ == "__main__":
    collector = MetricsCollector()
    
    # Simuliere eine Aufgabe
    collector.start_task(initial_tokens=100)
    time.sleep(2)  # Simuliere Verarbeitungszeit
    metrics = collector.end_task(final_tokens=500, success=True)
    
    print("Metriken für die Aufgabe:")
    print(f"Antwortgeschwindigkeit: {metrics['response_speed']:.2f} Sekunden")
    print(f"Token-Effizienz: {metrics['token_efficiency']:.2f} Tokens/Sekunde")
    print(f"Erfolgsrate: {metrics['success_rate']:.2f}%")
    
    # Systemmetriken
    system_metrics = collector.get_system_metrics()
    print("\nSystemmetriken:")
    print(f"CPU-Auslastung: {system_metrics['cpu_percent']:.2f}%")
    print(f"Speicherauslastung: {system_metrics['memory_percent']:.2f}%")
    print(f"Festplattenauslastung: {system_metrics['disk_usage_percent']:.2f}%")
