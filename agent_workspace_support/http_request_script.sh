
#!/bin/bash
cd /path/to/flask_app
chmod +x flask_app.py
curl -s http://localhost:5000/cpu_ram_disk_load | python -m json.tool