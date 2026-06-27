

# Start Flask App and Check Port 8086
nohup python /root/local_agent/agent_workspace/flask_app_start.sh &
if ! ping -c 1 localhost > /dev/null; then
    echo "Port 8086 nicht auf freiem Port."
else
    echo "Port 8086 ist auf freiem Port."
fi
