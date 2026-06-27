
#!/bin/bash
cd /root/local_agent/agent_workspace_support && ./test_ports.sh
netstat -tuln | grep ':8085 ' && netstat -tuln | grep ':8086 '