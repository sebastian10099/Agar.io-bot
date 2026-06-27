
import psutil
import time
from json import dumps

def collect_metrics():
    metrics = {
        'cpu_percent': psutil.cpu_percent(interval=1),
        'memory_info': list(psutil.virtual_memory()),
        'disk_usage': psutil.disk_usage('/').total,
        'load_average': psutil.getloadavg()[0],
        'services_running': [service.name() for service in psutil.process_iter(['name']) if service.status() == psutil.STATUS_RUNNING]
    }
    return dumps(metrics, indent=4)

if __name__ == '__main__':
    while True:
        print(collect_metrics())
        time.sleep(5)