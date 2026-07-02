#!/usr/bin/env bash
set -Eeuo pipefail

MODEL="${PROMETHEUS_OLLAMA_MODEL:-glm-5.2:cloud}"
ROOT="${PROMETHEUS_ROOT:-/root/local_agent}"
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-https://ollama.com}"
OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-/root/.openclaw/openclaw.json}"
LITELLM_CONFIG="${LITELLM_CONFIG:-/etc/litellm/openclaw-router.yaml}"
LITELLM_ENV="${LITELLM_ENV:-/etc/litellm/openclaw-router.env}"
AGENT_ZERO_ROOT="${AGENT_ZERO_ROOT:-}"
LOG="$ROOT/prometheus_openclaw_agentzero_ollama.log"

ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "[$(ts)] $*" | tee -a "$LOG"
}

require_root_hint() {
  if [[ "${EUID:-$(id -u)}" != "0" ]]; then
    log "WARN: not running as root; system config/service restart may fail."
  fi
}

find_agent_zero_root() {
  if [[ -n "$AGENT_ZERO_ROOT" && -d "$AGENT_ZERO_ROOT" ]]; then
    echo "$AGENT_ZERO_ROOT"
    return 0
  fi
  for p in \
    /opt/agent-zero \
    /opt/agentzero \
    /root/agent-zero \
    /root/agentzero \
    /srv/agent-zero \
    /srv/agentzero \
    /var/www/agent-zero \
    /var/www/agentzero; do
    if [[ -d "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  find /opt /root /srv /var/www -maxdepth 3 -type d \( -iname "agent-zero" -o -iname "agentzero" \) 2>/dev/null | head -n 1
}

write_litellm_router() {
  install -d "$(dirname "$LITELLM_CONFIG")"
  cat >"$LITELLM_CONFIG" <<EOF
model_list:
  - model_name: glm-5-2
    litellm_params:
      model: ollama/${MODEL}
      api_base: ${OLLAMA_BASE_URL}
      api_key: os.environ/OLLAMA_API_KEY

  - model_name: glm-5-2-fast
    litellm_params:
      model: ollama/${MODEL}
      api_base: ${OLLAMA_BASE_URL}
      api_key: os.environ/OLLAMA_API_KEY

litellm_settings:
  set_verbose: false
  drop_params: true
EOF
  log "LiteLLM router written: $LITELLM_CONFIG -> ollama/${MODEL}"
}

write_litellm_env() {
  install -d "$(dirname "$LITELLM_ENV")"
  touch "$LITELLM_ENV"
  chmod 600 "$LITELLM_ENV" || true
  python3 - "$LITELLM_ENV" "$OLLAMA_BASE_URL" <<'PY'
from pathlib import Path
import os, sys
path = Path(sys.argv[1])
base = sys.argv[2]
lines = []
if path.exists():
    lines = path.read_text(encoding="utf-8").splitlines()
out = []
seen = {"OLLAMA_BASE_URL": False, "OLLAMA_API_KEY": False, "LITELLM_API_KEY": False}
for line in lines:
    if line.startswith("OLLAMA_BASE_URL="):
        out.append(f"OLLAMA_BASE_URL={base}")
        seen["OLLAMA_BASE_URL"] = True
    elif line.startswith("OLLAMA_API_KEY="):
        key = os.environ.get("OLLAMA_API_KEY", line.split("=", 1)[1])
        out.append(f"OLLAMA_API_KEY={key}")
        seen["OLLAMA_API_KEY"] = True
    elif line.startswith("LITELLM_API_KEY="):
        out.append(line)
        seen["LITELLM_API_KEY"] = True
    else:
        out.append(line)
if not seen["OLLAMA_BASE_URL"]:
    out.append(f"OLLAMA_BASE_URL={base}")
if os.environ.get("OLLAMA_API_KEY") and not seen["OLLAMA_API_KEY"]:
    out.append("OLLAMA_API_KEY=" + os.environ["OLLAMA_API_KEY"])
if not seen["LITELLM_API_KEY"]:
    out.append("LITELLM_API_KEY=sk-openclaw-local")
path.write_text("\n".join([x for x in out if x.strip()]) + "\n", encoding="utf-8")
PY
  log "LiteLLM env updated without printing secrets: $LITELLM_ENV"
}

patch_openclaw_config() {
  if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
    log "OpenClaw config not found, skipped: $OPENCLAW_CONFIG"
    return 0
  fi
  python3 - "$OPENCLAW_CONFIG" "$MODEL" <<'PY'
import copy, json, sys, time
path, model = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
backup = f"{path}.bak.ollama-glm52.{int(time.time())}"
with open(backup, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")

models = cfg.setdefault("models", {})
providers = models.setdefault("providers", {})
providers.clear()
litellm = providers.setdefault("litellm", {})
litellm["baseUrl"] = "http://127.0.0.1:4000"
litellm["apiKey"] = "${LITELLM_API_KEY}"
litellm["api"] = "openai-completions"
litellm["models"] = [{
    "id": "glm-5-2",
    "name": "Ollama GLM 5.2",
    "reasoning": True,
    "input": ["text"],
    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
    "contextWindow": 131072,
    "maxTokens": 8192,
}]
models["mode"] = "merge"

agents = cfg.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
defaults.pop("summaryModel", None)
defaults["model"] = {"primary": "litellm/glm-5-2", "fallbacks": ["litellm/glm-5-2"]}
defaults["imageModel"] = {"primary": "litellm/glm-5-2", "fallbacks": ["litellm/glm-5-2"]}
defaults["timeoutSeconds"] = 120
defaults["models"] = {"litellm/glm-5-2": {"alias": "GLM 5.2"}}
cfg.setdefault("metadata", {})["prometheus_ollama_profile"] = {
    "provider": "ollama",
    "model": model,
    "updated_at": int(time.time()),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"OpenClaw patched, backup: {backup}")
PY
}

patch_agent_zero_files() {
  local root
  root="$(find_agent_zero_root || true)"
  if [[ -z "$root" || ! -d "$root" ]]; then
    log "Agent Zero root not found; set AGENT_ZERO_ROOT=/path/to/agent-zero and rerun."
    return 0
  fi
  log "Agent Zero root: $root"

  cat >"$root/prometheus_ollama_glm52.env" <<EOF
OLLAMA_BASE_URL=${OLLAMA_BASE_URL}
OLLAMA_MODEL=${MODEL}
AGENT_ZERO_PROVIDER=ollama
AGENT_ZERO_CHAT_MODEL=${MODEL}
AGENT_ZERO_UTILITY_MODEL=${MODEL}
AGENT_ZERO_BROWSER_MODEL=${MODEL}
EOF
  chmod 600 "$root/prometheus_ollama_glm52.env" || true

  python3 - "$root" "$MODEL" "$OLLAMA_BASE_URL" <<'PY'
from pathlib import Path
import json, sys, time
root = Path(sys.argv[1])
model = sys.argv[2]
base = sys.argv[3]
payload = {
    "provider": "ollama",
    "base_url": base,
    "chat_model": model,
    "utility_model": model,
    "browser_model": model,
    "embedding_provider": "local",
    "updated_by": "prometheus_configure_openclaw_agentzero_ollama",
    "updated_at": int(time.time()),
}
targets = [
    root / "prometheus_agent_zero_ollama_glm52.json",
    root / "data" / "prometheus_agent_zero_ollama_glm52.json",
]
for target in targets:
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("Agent Zero profile files written:")
for target in targets:
    print(" -", target)
PY

  if [[ -f "$root/docker-compose.yml" || -f "$root/compose.yml" ]]; then
    log "Agent Zero appears Docker-based. In its UI set provider=Ollama, base URL=${OLLAMA_BASE_URL}, model=${MODEL}."
  else
    log "Agent Zero profile file written. If Agent Zero stores settings in UI DB, apply the same values in Settings."
  fi
}

maybe_pull_model() {
  if [[ "${PROMETHEUS_PULL_GLM52:-0}" != "1" ]]; then
    log "Skipping automatic 'ollama pull ${MODEL}'. Set PROMETHEUS_PULL_GLM52=1 to pull intentionally."
    return 0
  fi
  if command -v ollama >/dev/null 2>&1; then
    log "Pulling Ollama model: ${MODEL}"
    ollama pull "$MODEL"
  else
    log "ollama CLI not found; cannot pull ${MODEL}"
  fi
}

restart_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemctl unavailable; restart skipped."
    return 0
  fi
  systemctl restart litellm-openclaw 2>/dev/null || true
  systemctl restart ollama 2>/dev/null || true
  systemctl restart local-agent.service 2>/dev/null || true
  systemctl --user restart openclaw-gateway 2>/dev/null || true
  log "Restart attempted for litellm-openclaw, ollama, local-agent, openclaw-gateway."
}

require_root_hint
install -d "$ROOT"
log "Configuring OpenClaw + Agent Zero for Ollama model ${MODEL}"
write_litellm_router
write_litellm_env
patch_openclaw_config
patch_agent_zero_files
maybe_pull_model
restart_services
log "Done. Verify: curl http://127.0.0.1:4000/v1/models and open Agent Zero/OpenClaw model settings."
