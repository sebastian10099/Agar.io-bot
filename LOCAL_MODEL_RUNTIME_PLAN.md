# Local Model Runtime Plan

Updated: 2026-06-27T19:36:14Z

## Decision

Use `llama.cpp` / `llama_cpp.server` as the non-Ollama local model runtime.
Keep cloud models for hard planning/coding, but route fast local checks through
the OpenAI-compatible llama.cpp API at `http://127.0.0.1:8081/v1`.

## Recommended Runtime

- Engine: llama.cpp / llama-cpp-python server
- Primary local model: `Qwen2.5-7B-Instruct-Q4_K_M.gguf`
- Stronger candidate if RAM allows: `Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf`
- Avoid vLLM/ExLlamaV2 on this VPS until a real NVIDIA GPU exists.

## CPU Target

Keep total load around 80-90 percent of the 8 CPU cores. Ollama must not keep a
separate 700-800 percent CPU model process alive while llama.cpp is serving.

## Safe Bring-up

1. Stop or unload local Ollama model processes before local llama.cpp tests.
2. Start llama.cpp on `127.0.0.1:8081`.
3. Smoke test `/v1/chat/completions`.
4. Set `local_ai_provider=llamacpp`.
5. Run the dashboard Test-Gate.
6. Re-enable Autopilot only when the gate is green.
