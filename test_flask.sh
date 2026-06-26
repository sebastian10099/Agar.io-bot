#!/bin/bash
source /root/local_agent/agent_workspace_support/virtualenv/bin/virtualenv &&
virtualenv --python=/usr/bin/python3.12 virtualenv_dir &&
source virtualenv_dir/bin/activate &&
pip install flask