
#!/bin/bash
# Start Flask Dashboards on ports 8085 and 8086 with increased timeout
nohup python -m flask run --host=0.0.0.0 --port=8085 --timeout 30 > /dev/null &
nohup python -m flask run --host=0.0.0.0 --port=8086 --timeout 30 > /dev/null &