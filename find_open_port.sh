#!/bin/bash
cp /root/local_agent/agent_workspace/port_array_var.sh /root/local_agent/agent_workspace/temp
PORTS=(
$(cat /root/local_agent/agent_workspace/temp)
)
unset temp
ports=()
for i in ${PORTS[@]}; do
  if [[ ! "${PORTS[@]}" =~ $i ]]; then
    ports+=($i
  fi
done
if [ -z "$ports" ]; then
  echo "No free port found." > /root/local_agent/agent_workspace/free_ports.txt
fi
