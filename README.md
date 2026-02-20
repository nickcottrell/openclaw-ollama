# OpenClaw + Ollama Dev Stack

Local AI assistant running entirely on your machine. No API keys, no cloud dependencies.

## What This Covers

- OpenClaw AI assistant framework
- Ollama local model inference
- Web-based control UI
- CLI agent interaction
- Tool-calling with local models

## Quick Start

```bash
# Clone this repo
git clone git@github.com:nickcottrell/openclaw-ollama.git
cd openclaw-ollama

# Run setup (clones OpenClaw, installs deps, pulls model)
./setup.sh

# Start the gateway
cd openclaw && pnpm openclaw gateway --port 18789 --verbose

# Control UI: http://127.0.0.1:18789
```

## Stack Details

- **Agent Framework:** OpenClaw (latest)
- **Model Runtime:** Ollama
- **Default Model:** Qwen 2.5 7B (~4.5GB)
- **Gateway Port:** 18789
- **Config:** ~/.openclaw/openclaw.json

## Prerequisites

- Node.js >= 22
- pnpm (auto-installed by setup script)
- Ollama (https://ollama.com)

## Using a Different Model

```bash
# Setup with a specific model
./setup.sh llama3.3:8b

# Or pull and switch manually
ollama pull mistral:7b
# Edit ~/.openclaw/openclaw.json to update model ID
```

## Configuration

The config template lives in `config/openclaw.json`. Key settings:

- **Model provider:** Ollama at localhost:11434
- **Tool policy:** TTS, messaging, cron, and gateway tools are denied for Ollama (local models struggle with complex tool-calling)
- **Gateway mode:** Local only (127.0.0.1)

## Project Structure

```
openclaw-ollama/
  config/
    openclaw.json    # Config template (deployed to ~/.openclaw/)
  setup.sh           # One-command setup
  openclaw/          # OpenClaw source (cloned by setup)
  README.md
```

## Architecture Notes

OpenClaw provides the agent framework and web UI. Ollama provides local model inference. The config denies tools that local models can't handle reliably (TTS, messaging), keeping responses as plain text.

Response times depend on your hardware and model size:
- 3B models: ~10s (too small for OpenClaw's system prompt)
- 7B models: ~30s (minimum viable for tool-calling)
- 13B+ models: better quality, needs more RAM

## Roadmap

- [ ] Model switcher CLI
- [ ] cue-mem context integration
- [ ] Simplified agent prompt for faster local inference
- [ ] Channel integrations (Telegram, WhatsApp)
