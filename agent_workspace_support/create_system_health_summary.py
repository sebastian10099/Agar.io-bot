import os

try:
    document_count = len(os.listdir('/root/local_agent/agent_workspace_support/results'))
except FileNotFoundError:
    document_count = 0

with open('/root/local_agent/agent_workspace_support/results/system_health_summary.md', 'a') as file:
    file.write(f'Number of existing support documents: {document_count}\n')
