
#!/bin/bash
set -e
if nc -z localhost 5001; then
echo 'Port 5001 ist offen.'
else
echo 'Port 5001 ist nicht offen.'
fi