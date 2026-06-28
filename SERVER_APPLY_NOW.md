# PROMETHEUS Apply Now

Run this once on the server when SSH or provider console is available:

```bash
cd /root/local_agent/agent_workspace
git fetch origin prometheus
git pull --ff-only origin prometheus
bash prometheus_apply_now.sh
```

What it does:

- updates `/root/local_agent/github_auto_sync.sh` from the repository copy
- switches local fallback to the llama.cpp/OpenAI-compatible runtime
- unloads the CPU-burning Ollama model best-effort
- repairs known broken test-gate files
- runs the GitHub adoption worker and writes adoption reports
- compiles the important Python files
- restarts `local-agent.service`
- runs one GitHub auto-sync pass so the dashboard shows the result

Expected evidence afterward:

- `/root/local_agent/root_runtime_patch_report.json`
- `/root/local_agent/runtime_maintenance_status.json`
- `/root/local_agent/agent_workspace/github_adoption_report.md`
- Dashboard hybrid status no longer points local work at `127.0.0.1:11434`
