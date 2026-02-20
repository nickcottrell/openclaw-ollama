#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCLAW_DIR="$SCRIPT_DIR/openclaw"
CONFIG_DIR="$HOME/.openclaw"
MODEL="${1:-qwen2.5:7b}"

echo "=== OpenClaw + Ollama Setup ==="
echo ""

# Check prerequisites
echo "[1/6] Checking prerequisites..."

if ! command -v node &>/dev/null; then
  echo "ERROR: Node.js not found. Install Node >= 22."
  exit 1
fi

NODE_MAJOR=$(node -v | sed 's/v//' | cut -d. -f1)
if [ "$NODE_MAJOR" -lt 22 ]; then
  echo "ERROR: Node >= 22 required. Found: $(node -v)"
  exit 1
fi

if ! command -v pnpm &>/dev/null; then
  echo "Installing pnpm..."
  npm install -g pnpm
fi

if ! command -v ollama &>/dev/null; then
  echo "ERROR: Ollama not found. Install from https://ollama.com"
  exit 1
fi

echo "  Node $(node -v), pnpm $(pnpm -v), Ollama $(ollama -v)"

# Pull Ollama model
echo ""
echo "[2/6] Pulling Ollama model: $MODEL..."
ollama pull "$MODEL"

# Clone OpenClaw
echo ""
echo "[3/6] Cloning OpenClaw..."
if [ -d "$OPENCLAW_DIR" ]; then
  echo "  Already cloned. Pulling latest..."
  git -C "$OPENCLAW_DIR" pull --ff-only 2>/dev/null || echo "  (pull skipped -- may have local changes)"
else
  git clone https://github.com/openclaw/openclaw.git "$OPENCLAW_DIR"
fi

# Install and build
echo ""
echo "[4/6] Installing dependencies..."
cd "$OPENCLAW_DIR"
pnpm install

echo ""
echo "[5/6] Building..."
pnpm ui:build
pnpm build

# Deploy config
echo ""
echo "[6/6] Deploying config..."
mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_DIR/openclaw.json" ]; then
  cp "$CONFIG_DIR/openclaw.json" "$CONFIG_DIR/openclaw.json.bak"
  echo "  Backed up existing config to openclaw.json.bak"
fi

# Update model in config template if not default
CONFIG_CONTENT=$(cat "$SCRIPT_DIR/config/openclaw.json")
if [ "$MODEL" != "qwen2.5:7b" ]; then
  CONFIG_CONTENT=$(echo "$CONFIG_CONTENT" | sed "s/qwen2.5:7b/$MODEL/g")
fi
echo "$CONFIG_CONTENT" > "$CONFIG_DIR/openclaw.json"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Start the gateway:"
echo "  cd $OPENCLAW_DIR && pnpm openclaw gateway --port 18789 --verbose"
echo ""
echo "Control UI:"
echo "  http://127.0.0.1:18789"
echo ""
echo "Test from CLI:"
echo "  cd $OPENCLAW_DIR && pnpm openclaw agent --agent main --message 'hello'"
echo ""
echo "Model: $MODEL"
echo "Config: $CONFIG_DIR/openclaw.json"
