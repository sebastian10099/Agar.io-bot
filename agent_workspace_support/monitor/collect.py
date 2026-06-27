#!/usr/bin/env python
import psutil

def collect_data(mode):
    data = {
        'cpu_percent': psutil.cpu_percent(interval=1),
        'memory_info': psutil.virtual_memory().total,
        'disk_usage': psutil.disk_usage('/').used,
        'load_average': psutil.getloadavg()[0],
        'services': [service.name() for service in psutil.process_iter()],
    }

if mode == 'standard':
    return data
elif mode == 'json':
    import json
    return json.dumps(data, indent=2)