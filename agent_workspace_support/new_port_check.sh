#!/bin/bash
# Port check script to verify if a port is open on the server.
if [ -p $1 ]; then
echo "Port \\$1 is a named pipe (FIFO)." >&2
exit 0
fi
if ! lsof -i :$1 | grep -qE "^ *[a-z]+:.*LISTEN" ;
then
echo "Port $1 is not open." >&2
exit 1
else
echo "Port $1 is open.
PID of listening process: $(lsof -i :$1 | awk '{print $2}')"
fi