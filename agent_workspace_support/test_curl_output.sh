#!/bin/bash
curl -I https://www.example.com | tee /root/local_agent/agent_workspace_support/test_curl_output.txt && echo $?