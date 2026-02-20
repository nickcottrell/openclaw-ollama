# OpenClaw + Ollama

Local AI assistant running entirely on your machine. No API keys, no cloud, no telemetry.

## What This Is

A dev environment that wires together [OpenClaw](https://github.com/nickcottrell/openclaw) (agent framework + web UI) and [Ollama](https://ollama.com) (local model inference). Everything runs on localhost. Your conversations, prompts, and data never leave your machine.

## Prerequisites

- **Node.js** >= 22
- **Ollama** installed via Homebrew (`brew install ollama`)
- **pnpm** (`npm install -g pnpm`)

## Setup

```bash
# 1. Clone this repo
git clone git@github.com:nickcottrell/openclaw-ollama.git
cd openclaw-ollama

# 2. Clone OpenClaw inside it
git clone https://github.com/nickcottrell/openclaw.git

# 3. Install OpenClaw dependencies
cd openclaw && pnpm install && cd ..

# 4. Pull a model
ollama pull qwen2.5:7b

# 5. Deploy config
mkdir -p ~/.openclaw
cp config/openclaw.json ~/.openclaw/openclaw.json
```

## Usage

### TUI (recommended)

```bash
./tui.sh
```

Arrow-key navigable menu with submenus for Ollama management, debugging, workspace, and security.

### CLI

```bash
./hooks.sh start          # Start gateway + sync workspace
./hooks.sh stop           # Stop gateway
./hooks.sh chat           # Open browser to chat UI
./hooks.sh status         # Check service status
```

Run `./hooks.sh help` for the full command list.

## Project Structure

```
openclaw-ollama/
  hooks.sh              # Service management (start, stop, security, workspace)
  tui.sh                # Arrow-key TUI (sources hooks.sh + lib/tui.sh)
  lib/tui.sh            # Reusable arrow-key menu library
  config/openclaw.json  # Config template (deployed to ~/.openclaw/)
  workspace/            # Template files synced to ~/.openclaw/workspace/
  openclaw/             # OpenClaw source (gitignored, cloned separately)
  logs/                 # Gateway logs (gitignored)
```

## How It Works

```
Browser  -->  OpenClaw Gateway (:18789)  -->  Ollama (:11434)  -->  Model in RAM
                     |
              ~/.openclaw/workspace/    (files injected into every prompt)
              ~/.openclaw/openclaw.json (config + auth token)
```

- **Ollama** runs as a brew service. Models load into RAM on first request and unload after idle timeout.
- **OpenClaw Gateway** is a Node.js server that bridges the browser UI to Ollama. It serves the chat interface and manages sessions.
- **Workspace files** in `~/.openclaw/workspace/` are injected into every prompt sent to the model. This is how you give the agent identity, tools awareness, and behavioral directives.

## Workspace

Template files in `workspace/` define the agent's persona:

| File | Purpose |
|------|---------|
| IDENTITY.md | Agent name and vibe |
| SOUL.md | Behavioral directive |
| AGENTS.md | Role definition |
| TOOLS.md | Available tool awareness |
| USER.md | User context |
| HEARTBEAT.md | Heartbeat config |

Sync them to the live workspace with `./hooks.sh sync` or through the TUI (Debug > Workspace > Sync).

## Security

Everything binds to localhost by default. The TUI includes a security audit (Debug > Security audit) that checks:

- Ollama and gateway network binding
- Auth token configuration
- File permissions on config, logs, and workspace (all should be owner-only)
- Workspace contents (files here become prompt injections)

Run `./hooks.sh security` from the CLI.

## Ollama Management

The TUI Ollama submenu provides:

- **Info** -- version, installed models, VRAM usage
- **Warm up** -- pre-load model with 1-hour idle timeout
- **Benchmark** -- token speed test across installed models
- **Switch model** -- change which model the gateway uses
- **Quick chat** -- direct terminal chat with Ollama (bypasses gateway)
- **Unload** -- free VRAM by unloading all models

## Configuration

The default model is `qwen2.5:7b`. To use a different model:

```bash
ollama pull llama3.2:3b
./hooks.sh switch          # Interactive model picker
```

Gateway port defaults to `18789`. Override with:

```bash
OPENCLAW_PORT=9999 ./tui.sh
```

## Stopping Services

```bash
./hooks.sh stop            # Stop gateway only (Ollama stays running)
./hooks.sh stop-all        # Stop gateway + Ollama (full shutdown)
```

`stop-all` fully unloads the Ollama brew service so it won't auto-restart.
