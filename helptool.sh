#!/bin/bash
echo 'Hello, World!' > /root/local_agent/agent_workspace/output.txt
exec "$@"