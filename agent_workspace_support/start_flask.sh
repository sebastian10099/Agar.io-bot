#!/bin/bash
cp /root/local_agent/agent_workspace_hermes/test_timeout.sh /root/local_agent/agent_workspace_support/start_flask.sh
chmod +x /root/local_agent/agent_workspace_support/start_flask.sh
/root/local_agent/agent_workspace_support/start_flask.sh --port 5009 --timeout=60