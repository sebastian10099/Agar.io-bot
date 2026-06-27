#!/bin/bash

# Erstelle die Flask-Dashboards-Datei
python3 -c "from flask import Flask, request; app = Flask(__name__); @app.route('/test', methods=['GET']); def hello(): return 'Hello, World!'; if __name__ == '__main__': app.run(host='0.0.0.0', port=5002, debug=True)" > /root/local_agent/agent_workspace_support/flask_dashboard.py

echo 'Flask-Dashboards-Datei erstellt.'

# Starte den Flask-Server mit einem erhöhten Timeout-Wert
nohup python3 -m flask run --host=0.0.0.0 --port 5002 --timeout 60 &