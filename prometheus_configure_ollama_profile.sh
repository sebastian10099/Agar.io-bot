#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PROMETHEUS_ROOT:-/root/local_agent}"
CONFIG="$ROOT/config.json"
SERVICE_DROPIN="/etc/systemd/system/local-agent.service.d/10-ollama-cloud.conf"

if [[ ! -f "$CONFIG" ]]; then
  echo "Config not found: $CONFIG" >&2
  exit 1
fi

if [[ -z "${OLLAMA_API_KEY:-}" ]]; then
  echo "OLLAMA_API_KEY is not set."
  read -rsp "Paste Ollama API key (hidden): " OLLAMA_API_KEY
  echo
fi

python3 - "$CONFIG" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

# Ollama profile: no OpenAI credits. Cloud is optional through OLLAMA_API_KEY;
# local fallback remains possible when local models are available.
cfg["provider"] = "ollama"
cfg["ollama_url"] = cfg.get("ollama_cloud_url", "https://ollama.com")
cfg["ollama_model"] = "glm-5.1"
cfg["ollama_strategist_model"] = "glm-5.1"
cfg["ollama_reviewer_model"] = "glm-5.1"
cfg["ollama_coder_model"] = "qwen3-coder-next:cloud"
cfg["ollama_cloud_coder_model"] = "qwen3-coder-next:cloud"
cfg["ollama_fast_coder_model"] = "devstral-small-2"
cfg["ollama_strong_coder_model"] = "qwen3-coder-next:cloud"
cfg["cloud_json_fallback_model"] = "glm-5.1"
cfg["local_ai_provider"] = "ollama"
cfg["preferred_local_engine"] = "ollama"
cfg["local_fast_model"] = "devstral-small-2"
cfg["local_fallback_to_cloud"] = True
cfg["use_local_fast"] = True
cfg["ollama_budget_mode"] = True
cfg["ollama_budget_profile"] = "sparsam"
cfg["ollama_num_ctx"] = 4096
cfg["ollama_num_predict"] = 384
cfg["ollama_json_num_predict"] = 260
cfg["ollama_cloud_num_predict"] = 512
cfg["ollama_local_num_predict"] = 192
cfg["ollama_keep_alive"] = "2m"
cfg["model_routing"] = {
    "main_agent": "glm-5.1",
    "strategist": "glm-5.1",
    "fast_coder": "devstral-small-2",
    "cloud_coder": "qwen3-coder-next:cloud",
    "reviewer": "glm-5.1",
    "hermes_meta": "glm-5.1",
}
cfg["ollama_coder_models"] = [
    "qwen3-coder-next:cloud",
    "qwen3-coder:30b",
    "devstral-small-2",
    "deepseek-coder-v2:16b",
]
cfg["ollama_reviewer_models"] = [
    "glm-5.1",
    "qwen3.6",
    "devstral-small-2",
]
cfg["_kommentar"] = (
    "Ollama-Profil ohne OpenAI/Hostinger-Credits: GLM-5.1 fuer Planung/Review, "
    "Qwen3-Coder-Next Cloud fuer starke Code-Aenderungen, Devstral lokal als schneller Coder. "
    "OLLAMA_API_KEY liegt in systemd Environment, nicht in Git."
)

with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

if command -v systemctl >/dev/null 2>&1; then
  install -d /etc/systemd/system/local-agent.service.d
  umask 077
  cat >"$SERVICE_DROPIN" <<EOF
[Service]
Environment=OLLAMA_API_KEY=$OLLAMA_API_KEY
EOF
  systemctl daemon-reload
fi

echo "Ollama profile configured:"
echo "  Planner/Reviewer: glm-5.1"
echo "  Strong coder    : qwen3-coder-next:cloud"
echo "  Fast local coder: devstral-small-2"
echo
echo "Next:"
echo "  systemctl restart local-agent.service"
