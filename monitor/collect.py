import json, psutil, os
def collect():
    data = {
        "cpu": psutil.cpu_percent(interval=1, percpu=True),
        "ram": {"total": psutil.virtual_memory().total, "used": psutil.virtual_memory().used, "percent": psutil.virtual_memory().percent},
        "disk": {"total": psutil.disk_usage("/").total, "used": psutil.disk_usage("/").used, "percent": psutil.disk_usage("/").percent},
        "load": os.getloadavg() if hasattr(os, "getloadavg") else None,
        "services": [p.name() for p in psutil.process_iter(["name"])]
    }
    return json.dumps(data, indent=2)
if __name__ == "__main__":
    print(collect())
