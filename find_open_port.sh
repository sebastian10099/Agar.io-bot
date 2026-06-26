
#!/bin/bash
PORT=$(netstat -tuln | grep ':80 ' | cut -d: -f4 | awk '{print $1}' | sort -u)
echo "OPEN_PORT=$PORT"