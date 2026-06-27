#!/bin/bash
echo '{"status": "ok", "timestamp": "'$(date -Iseconds)'"}' > /root/local_agent/agent_workspace_support/test_communication_result.json
