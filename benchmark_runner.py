import logging
import time
import random
from metrics_collector import MetricsCollector

def sample_task_v1(token_target=1000):
    """Simuliert eine einfache Aufgabe (Version 1)"""
    tokens = 0
    while tokens < token_target:
        tokens += random.randint(1, 10)
        time.sleep(0.001)  # Simuliere minimale Verarbeitungszeit
    return tokens

def sample_task_v2(token_target=1000):
    """Simuliert eine optimierte Aufgabe (Version 2)"""
    tokens = 0
    batch_size = 50
    while tokens < token_target:
        tokens += batch_size
        time.sleep(0.0005)  # Schnellere Verarbeitung
    return tokens

def run_benchmark(task_func, iterations=5):
    """Führt einen Benchmark für eine bestimmte Aufgabenfunktion aus"""
    collector = MetricsCollector()
    total_speed = 0
    total_efficiency = 0
    successes = 0
    
    for i in range(iterations):
        collector.start_task(initial_tokens=0)
        try:
            final_tokens = task_func()
            metrics = collector.end_task(final_tokens=final_tokens, success=True)
            total_speed += metrics['response_speed']
            total_efficiency += metrics['token_efficiency']
            successes += 1
        except Exception as e:
            collector.end_task(final_tokens=0, success=False)
            print(f"Fehler in Iteration {i+1}: {e}")
    
    avg_speed = total_speed / successes if successes > 0 else 0
    avg_efficiency = total_efficiency / successes if successes > 0 else 0
    success_rate = (successes / iterations) * 100
    
    return {
        'avg_response_speed': avg_speed,
        'avg_token_efficiency': avg_efficiency,
        'success_rate': success_rate,
        'iterations': iterations,
        'successful_runs': successes
    }

if __name__ == "__main__":
    print("=== Benchmark: Task Version 1 ===")
    results_v1 = run_benchmark(sample_task_v1, iterations=5)
    print(f"Durchschnittliche Antwortgeschwindigkeit: {results_v1['avg_response_speed']:.4f} Sekunden")
    print(f"Durchschnittliche Token-Effizienz: {results_v1['avg_token_efficiency']:.2f} Tokens/Sekunde")
    print(f"Erfolgsrate: {results_v1['success_rate']:.2f}%")
    
    print("\n=== Benchmark: Task Version 2 ===")
    results_v2 = run_benchmark(sample_task_v2, iterations=5)
    print(f"Durchschnittliche Antwortgeschwindigkeit: {results_v2['avg_response_speed']:.4f} Sekunden")
    print(f"Durchschnittliche Token-Effizienz: {results_v2['avg_token_efficiency']:.2f} Tokens/Sekunde")
    print(f"Erfolgsrate: {results_v2['success_rate']:.2f}%")
    
    # Vergleich
    print("\n=== Vergleich ===")
    speed_improvement = ((results_v1['avg_response_speed'] - results_v2['avg_response_speed']) / 
                        results_v1['avg_response_speed']) * 100 if results_v1['avg_response_speed'] > 0 else 0
    efficiency_improvement = ((results_v2['avg_token_efficiency'] - results_v1['avg_token_efficiency']) / 
                             results_v1['avg_token_efficiency']) * 100 if results_v1['avg_token_efficiency'] > 0 else 0
    
    print(f"Geschwindigkeitsverbesserung: {speed_improvement:.2f}%")
    print(f"Effizienzsteigerung: {efficiency_improvement:.2f}%")