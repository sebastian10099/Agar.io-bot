# PROMETHEUS Apply Now

Run this once on the server when SSH or provider console is available:

```bash
cd /root/local_agent/agent_workspace
export OPENAI_COMPATIBLE_BASE_URL="https://DEIN-GLM-KIMI-ROUTER/v1"
export OPENAI_API_KEY="DEIN_API_KEY"
git fetch origin prometheus
git pull --ff-only origin prometheus
bash prometheus_apply_now.sh
```

What it does:

- updates `/root/local_agent/github_auto_sync.sh` from the repository copy
- switches the agent to the OpenAI-compatible Codex-style runtime
- routes planner/reviewer/main work to GLM-5.2 and coding work to Kimi/QiMi Code
- unloads the CPU-burning Ollama model best-effort
- repairs known broken test-gate files
- runs the GitHub adoption worker and writes adoption reports
- compiles the important Python files
- restarts `local-agent.service`
- installs `prometheus-dashboard-watchdog.timer`, which checks `/state` every minute and restarts the service if the dashboard stops responding
- runs one GitHub auto-sync pass so the dashboard shows the result

Expected evidence afterward:

- `/root/local_agent/root_runtime_patch_report.json`
- `/root/local_agent/runtime_maintenance_status.json`
- `/root/local_agent/agent_workspace/github_adoption_report.md`
- `/root/local_agent/prometheus_dashboard_watchdog.log`
- Dashboard hybrid status no longer points local work at `127.0.0.1:11434`

Emergency recovery when the site is unavailable:

```bash
systemctl restart local-agent.service
systemctl status local-agent.service --no-pager
bash /root/local_agent/prometheus_dashboard_watchdog.sh
```

Switch to the Ollama no-OpenAI-credits profile:

```bash
export OLLAMA_API_KEY="DEIN_OLLAMA_KEY"
bash /root/local_agent/prometheus_configure_ollama_profile.sh
systemctl restart local-agent.service
```

Configure OpenClaw and Agent Zero to use Ollama GLM 5.2:

```bash
export OLLAMA_API_KEY="DEIN_OLLAMA_KEY"  # optional for Ollama Cloud; omit for purely local Ollama
export PROMETHEUS_OLLAMA_MODEL="glm-5.2:cloud"
bash /root/local_agent/prometheus_configure_openclaw_agentzero_ollama.sh
```

If Agent Zero runs in Docker, open its model settings and use:

- Provider: `Ollama`
- Base URL: `https://ollama.com`
- Model: `glm-5.2:cloud`

Fix Agent Zero `host.docker.internal:11434`, `host.docker.internal:8080`, `Hosted_vllm`, or OpenRouter 401 connection errors:

```bash
export OLLAMA_API_KEY="DEIN_OLLAMA_KEY"
export PROMETHEUS_OLLAMA_MODEL="glm-5.2:cloud"
export OLLAMA_BASE_URL="https://ollama.com"
bash /root/local_agent/prometheus_fix_agentzero_ollama_connection.sh
```
