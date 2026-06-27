#!/bin/bash
curl -I https://www.example.com | tee /root/local_agent/agent_workspace_support/test_http_request_output.txt && echo $?