#!/bin/bash
cd /root/local_agent/agent_workspace
apt-get update && apt-get -y install python3-pip flask
curl -s https://bootstrap.pypa.io/get-pip.py | sudo python3 get-pip.py
echo 'export FLASK_APP=app.py' >> ~/.bashrc
source ~/.bashrc
echo 'export FLASK_RUN_PORT=$FLASK_RUN_PORT' >> ~/.bashrc
source ~/.bashrc
flask run --host=0.0.0.0 --port=$FLASK_RUN_PORT