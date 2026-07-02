#!/usr/bin/env bash
set -Eeuo pipefail

MODEL="${PROMETHEUS_OLLAMA_MODEL:-glm-5.2:cloud}"
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-https://ollama.com}"
ROOT="${PROMETHEUS_ROOT:-/root/local_agent}"
LOG="$ROOT/prometheus_agentzero_ollama_fix.log"

ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "[$(ts)] $*" | tee -a "$LOG"
}

find_agent_zero_roots() {
  for p in \
    /a0 \
    /opt/agent-zero \
    /opt/agentzero \
    /root/agent-zero \
    /root/agentzero \
    /srv/agent-zero \
    /srv/agentzero \
    /var/www/agent-zero \
    /var/www/agentzero; do
    [[ -d "$p" ]] && echo "$p"
  done
  find /opt /root /srv /var/www -maxdepth 3 -type d \( -iname "agent-zero" -o -iname "agentzero" \) 2>/dev/null || true
}

write_profile_files() {
  local root="$1"
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
    "model": model,
    "chat_model": model,
    "utility_model": model,
    "browser_model": model,
    "response_model": model,
    "api_base": base,
    "base_url": base,
    "litellm_model": f"ollama/{model}",
    "note": "Use Ollama Cloud, not host.docker.internal local Ollama/vLLM or OpenRouter. Requires OLLAMA_API_KEY in runtime env.",
    "updated_by": "prometheus_fix_agentzero_ollama_connection",
    "updated_at": int(time.time()),
}
for rel in [
    "prometheus_agent_zero_ollama_glm52.json",
    "data/prometheus_agent_zero_ollama_glm52.json",
    "settings/prometheus_agent_zero_ollama_glm52.json",
]:
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(target)
PY
}

patch_text_configs() {
  local root="$1"
  python3 - "$root" "$MODEL" "$OLLAMA_BASE_URL" <<'PY'
from pathlib import Path
import re, sys, time
root = Path(sys.argv[1])
model = sys.argv[2]
base = sys.argv[3]
exts = {".env", ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf"}
needles = [
    "host.docker.internal",
    "127.0.0.1:11434",
    "localhost:11434",
    "127.0.0.1:8080",
    "localhost:8080",
    "hosted_vllm",
    "hosted-vllm",
    "openrouter.ai",
    "openrouter/",
    "OpenRouter",
    "openrouter",
]
patched = []
for path in root.rglob("*"):
    if not path.is_file() or path.suffix.lower() not in exts:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        continue
    if not any(n in text for n in needles) and "glm-5.2" not in text and "ollama/" not in text:
        continue
    new = text
    new = re.sub(r"https?://host\.docker\.internal:\d+", base, new)
    new = re.sub(r"host\.docker\.internal:\d+", base.replace("https://", "").replace("http://", ""), new)
    new = re.sub(r"https?://127\.0\.0\.1:(11434|8080)", base, new)
    new = re.sub(r"https?://localhost:(11434|8080)", base, new)
    new = re.sub(r"127\.0\.0\.1:(11434|8080)", base.replace("https://", "").replace("http://", ""), new)
    new = re.sub(r"localhost:(11434|8080)", base.replace("https://", "").replace("http://", ""), new)
    new = re.sub(r"https?://openrouter\.ai[^\"'\s,\]}]*", base, new, flags=re.IGNORECASE)
    new = new.replace("hosted_vllm/", "ollama/")
    new = new.replace("hosted-vllm/", "ollama/")
    new = new.replace("hosted_vllm", "ollama")
    new = new.replace("hosted-vllm", "ollama")
    new = re.sub(r"openrouter/", "ollama/", new, flags=re.IGNORECASE)
    new = re.sub(
        r"((?:model_)?provider|llm_provider|provider_name)([\"']?\s*[:=]\s*[\"']?)openrouter",
        r"\1\2ollama",
        new,
        flags=re.IGNORECASE,
    )
    new = new.replace("OpenRouter", "Ollama")
    new = new.replace("glm-5.2:latest", model)
    new = new.replace("glm-5.2", model)
    new = new.replace("ollama/glm-5.2:cloud:cloud", f"ollama/{model}")
    new = re.sub(r"ollama/[^\"'\s,\]}]+", f"ollama/{model}", new)
    if new != text:
        backup = path.with_name(path.name + f".bak.agentzero-ollama.{int(time.time())}")
        backup.write_text(text, encoding="utf-8")
        path.write_text(new, encoding="utf-8")
        patched.append((str(path), str(backup)))
print("patched files:")
for p, b in patched:
    print(f" - {p} (backup {b})")
if not patched:
    print(" - none")
PY
}

patch_docker_compose() {
  local root="$1"
  python3 - "$root" "$MODEL" "$OLLAMA_BASE_URL" <<'PY'
from pathlib import Path
import sys, time
root = Path(sys.argv[1])
model = sys.argv[2]
base = sys.argv[3]
for name in ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"]:
    path = root / name
    if not path.exists():
        continue
    text = path.read_text(encoding="utf-8")
    insert = (
        "      OLLAMA_BASE_URL: " + base + "\n"
        "      OLLAMA_API_BASE: " + base + "\n"
        "      OLLAMA_MODEL: " + model + "\n"
        "      LITELLM_MODEL: ollama/" + model + "\n"
    )
    new = text
    import re
    if "host.docker.internal" in new or "127.0.0.1:8080" in new or "localhost:8080" in new:
        new = re.sub(r"https?://host\.docker\.internal:\d+", base, new)
        new = re.sub(r"host\.docker\.internal:\d+", base.replace("https://", "").replace("http://", ""), new)
        new = re.sub(r"https?://127\.0\.0\.1:(11434|8080)", base, new)
        new = re.sub(r"https?://localhost:(11434|8080)", base, new)
    if "OLLAMA_BASE_URL:" not in new and "environment:" in new:
        new = new.replace("environment:\n", "environment:\n" + insert, 1)
    if new != text:
        backup = path.with_name(path.name + f".bak.agentzero-ollama.{int(time.time())}")
        backup.write_text(text, encoding="utf-8")
        path.write_text(new, encoding="utf-8")
        print(f"patched compose: {path} backup {backup}")
PY
}

restart_agent_zero() {
  local root="$1"
  if [[ -f "$root/docker-compose.yml" || -f "$root/docker-compose.yaml" || -f "$root/compose.yml" || -f "$root/compose.yaml" ]]; then
    if command -v docker >/dev/null 2>&1; then
      (cd "$root" && docker compose up -d) || true
    fi
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart agent-zero 2>/dev/null || true
    systemctl restart agentzero 2>/dev/null || true
    systemctl restart a0 2>/dev/null || true
  fi
}

install -d "$ROOT"
log "Fixing Agent Zero Ollama connection: model=${MODEL}, base=${OLLAMA_BASE_URL}"
mapfile -t roots < <(find_agent_zero_roots | awk '!seen[$0]++')
if [[ "${#roots[@]}" -eq 0 ]]; then
  log "Agent Zero root not found. Set AGENT_ZERO_ROOT and rerun."
  exit 0
fi

for root in "${roots[@]}"; do
  log "Processing Agent Zero root: $root"
  write_profile_files "$root"
  patch_text_configs "$root"
  patch_docker_compose "$root"
  restart_agent_zero "$root"
done

log "Done. Agent Zero should no longer use host.docker.internal local Ollama/vLLM endpoints. Verify logs for absence of APIConnectionError/InternalServerError."
