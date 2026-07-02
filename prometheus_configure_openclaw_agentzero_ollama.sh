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
OPENCLAW_LOCAL_KEY="${OPENCLAW_LOCAL_KEY:-sk-openclaw-local}"

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

ensure_ollama_key() {
  if [[ -n "${OLLAMA_API_KEY:-}" ]]; then
    return 0
  fi
  if [[ -t 0 ]]; then
    echo "OLLAMA_API_KEY is not set."
    read -rsp "Paste Ollama API key (hidden): " OLLAMA_API_KEY
    export OLLAMA_API_KEY
    echo
    return 0
  fi
  log "WARN: OLLAMA_API_KEY is not set. Ollama Cloud calls will fail until the key is exported."
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

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
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
seen = {"OLLAMA_BASE_URL": False, "OLLAMA_API_KEY": False, "LITELLM_API_KEY": False, "LITELLM_MASTER_KEY": False}
for line in lines:
    if line.startswith("OLLAMA_BASE_URL="):
        out.append(f"OLLAMA_BASE_URL={base}")
        seen["OLLAMA_BASE_URL"] = True
    elif line.startswith("OLLAMA_API_KEY="):
        key = os.environ.get("OLLAMA_API_KEY", line.split("=", 1)[1])
        out.append(f"OLLAMA_API_KEY={key}")
        seen["OLLAMA_API_KEY"] = True
    elif line.startswith("LITELLM_API_KEY="):
        out.append("LITELLM_API_KEY=sk-openclaw-local")
        seen["LITELLM_API_KEY"] = True
    elif line.startswith("LITELLM_MASTER_KEY="):
        out.append("LITELLM_MASTER_KEY=sk-openclaw-local")
        seen["LITELLM_MASTER_KEY"] = True
    else:
        out.append(line)
if not seen["OLLAMA_BASE_URL"]:
    out.append(f"OLLAMA_BASE_URL={base}")
if os.environ.get("OLLAMA_API_KEY") and not seen["OLLAMA_API_KEY"]:
    out.append("OLLAMA_API_KEY=" + os.environ["OLLAMA_API_KEY"])
if not seen["LITELLM_API_KEY"]:
    out.append("LITELLM_API_KEY=sk-openclaw-local")
if not seen["LITELLM_MASTER_KEY"]:
    out.append("LITELLM_MASTER_KEY=sk-openclaw-local")
path.write_text("\n".join([x for x in out if x.strip()]) + "\n", encoding="utf-8")
PY
  log "LiteLLM env updated without printing secrets: $LITELLM_ENV"
}

install_litellm_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  cat >/etc/systemd/system/litellm-openclaw.service <<EOF
[Unit]
Description=LiteLLM proxy for OpenClaw Ollama routing
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${LITELLM_ENV}
ExecStart=/usr/bin/env bash -lc 'if command -v litellm >/dev/null 2>&1; then exec litellm --config "${LITELLM_CONFIG}" --host 127.0.0.1 --port 4000; elif [ -x /opt/venv-a0/bin/litellm ]; then exec /opt/venv-a0/bin/litellm --config "${LITELLM_CONFIG}" --host 127.0.0.1 --port 4000; else exec python3 -m litellm --config "${LITELLM_CONFIG}" --host 127.0.0.1 --port 4000; fi'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || true
  systemctl enable --now litellm-openclaw.service 2>/dev/null || true
  log "LiteLLM fallback service installed/enabled: litellm-openclaw.service"
}

write_openclaw_env_dropins() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  for svc in openclaw-gateway openclaw clawdbot; do
    install -d "/etc/systemd/system/${svc}.service.d"
    umask 077
    cat >"/etc/systemd/system/${svc}.service.d/10-prometheus-ollama-cloud.conf" <<EOF
[Service]
Environment=OLLAMA_BASE_URL=${OLLAMA_BASE_URL}
Environment=OLLAMA_API_KEY=${OLLAMA_API_KEY:-}
Environment=LITELLM_API_KEY=${OPENCLAW_LOCAL_KEY}
EOF
  done
  systemctl daemon-reload || true
  log "OpenClaw systemd env drop-ins written without printing secrets."
}

patch_openclaw_config() {
  if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
    log "OpenClaw config not found, skipped: $OPENCLAW_CONFIG"
    return 0
  fi
  python3 - "$OPENCLAW_CONFIG" "$MODEL" "$OLLAMA_BASE_URL" <<'PY'
import copy, json, sys, time
path, model, base = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
backup = f"{path}.bak.ollama-glm52.{int(time.time())}"
with open(backup, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")

models = cfg.setdefault("models", {})
providers = models.setdefault("providers", {})
providers.clear()
ollama = providers.setdefault("ollama", {})
ollama["baseUrl"] = base
ollama["apiKey"] = "OLLAMA_API_KEY"
ollama["api"] = "ollama"
ollama["timeoutSeconds"] = 300
ollama["models"] = [{
    "id": model,
    "name": model,
    "reasoning": True,
    "input": ["text"],
    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
    "contextWindow": 131072,
    "maxTokens": 8192,
    "params": {"keep_alive": "10m"},
}]
models["mode"] = "merge"

agents = cfg.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
defaults.pop("summaryModel", None)
model_ref = f"ollama/{model}"
defaults["model"] = {"primary": model_ref, "fallbacks": [model_ref]}
defaults["imageModel"] = {"primary": model_ref, "fallbacks": [model_ref]}
defaults["timeoutSeconds"] = 120
defaults["models"] = {model_ref: {"alias": "GLM 5.2"}}
cfg.setdefault("tools", {}).setdefault("web", {}).setdefault("search", {})["provider"] = "ollama"
cfg.setdefault("metadata", {})["prometheus_ollama_profile"] = {
    "provider": "ollama",
    "model": model,
    "base_url": base,
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
OLLAMA_API_BASE=${OLLAMA_BASE_URL}
OLLAMA_MODEL=${MODEL}
LITELLM_MODEL=ollama/${MODEL}
MODEL_PROVIDER=ollama
CHAT_MODEL=ollama/${MODEL}
UTILITY_MODEL=ollama/${MODEL}
BROWSER_MODEL=ollama/${MODEL}
RESPONSE_MODEL=ollama/${MODEL}
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
    "response_model": model,
    "litellm_model": f"ollama/{model}",
    "api_base": base,
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

apply_openclaw_config() {
  if ! command -v openclaw >/dev/null 2>&1; then
    log "openclaw CLI not found; config file patched but gateway config.apply skipped."
    return 0
  fi
  openclaw gateway config.apply --file "$OPENCLAW_CONFIG" 2>&1 | tee -a "$LOG" || {
    log "WARN: openclaw gateway config.apply failed; service restart will still be attempted."
    return 0
  }
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
  systemctl restart openclaw 2>/dev/null || true
  systemctl restart openclaw-gateway 2>/dev/null || true
  systemctl restart clawdbot 2>/dev/null || true
  systemctl restart local-agent.service 2>/dev/null || true
  systemctl --user restart openclaw-gateway 2>/dev/null || true
  log "Restart attempted for litellm-openclaw, ollama, OpenClaw, local-agent, openclaw-gateway."
}

require_root_hint
ensure_ollama_key
install -d "$ROOT"
log "Configuring OpenClaw + Agent Zero for Ollama model ${MODEL}"
write_litellm_router
write_litellm_env
install_litellm_service
write_openclaw_env_dropins
patch_openclaw_config
apply_openclaw_config
patch_agent_zero_files
maybe_pull_model
restart_services
log "Done. Verify: openclaw models list --provider ollama, curl http://127.0.0.1:4000/v1/models, and open Agent Zero/OpenClaw model settings."
