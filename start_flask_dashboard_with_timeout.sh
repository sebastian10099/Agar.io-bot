#!/bin/bash
cp /root/local_agent/agent_workspace/test_tool.py /tmp/
sed -i 's/app.run(host='0.0.0.0', port=5006, debug=True)/app.run(host='0.0.0.0', port=5006, debug=True, timeout=120)/' /tmp/test_tool.py
cp /root/local_agent/agent_workspace/support/start_flask_dashboard_with_timeout.sh /tmp/
sed -i 's/timeout 30/timeout 120/' /tmp/start_flask_dashboard_with_timeout.sh
python3 /tmp/start_flask_dashboard_with_timeout.sh --host 0.0.0.0 --port 5006 --timeout 120