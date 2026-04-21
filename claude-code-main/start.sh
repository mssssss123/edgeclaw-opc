#!/bin/bash
# Start Claude Code from leaked source (with OpenAI-format proxy)
# Usage:
#   ./start.sh                    # interactive TUI mode (requires real terminal)
#   ./start.sh -p "your prompt"   # non-interactive (print & exit)
#   ./start.sh --help             # show help
#   ./start.sh --version          # show version
#
# Configuration: set EDGECLAW_* in the repository root .env or export them.

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
ROOT_ENV="$REPO_ROOT/.env"

if [ -f "$ROOT_ENV" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_ENV"
  set +a
fi

require_env() {
  local key="$1"
  if [ -z "${!key:-}" ]; then
    echo "Error: $key is not set. Configure it in $ROOT_ENV or export it before starting Claude Code." >&2
    exit 1
  fi
}

require_env EDGECLAW_API_BASE_URL
require_env EDGECLAW_API_KEY
require_env EDGECLAW_MODEL

PROXY_PORT="${EDGECLAW_PROXY_PORT:-18080}"

# Ensure bun is on PATH
if ! command -v bun &>/dev/null; then
  if [ -f "$HOME/.bun/bin/bun" ]; then
    export PATH="$HOME/.bun/bin:$PATH"
  else
    echo "Error: bun is not installed. Install it with: curl -fsSL https://bun.sh/install | bash" >&2
    exit 1
  fi
fi

# ── Check if interactive mode is possible ──
HAS_PRINT=false
for arg in "$@"; do
  case "$arg" in -p|--print|--help|--version|-v|-V) HAS_PRINT=true ;; esac
done
if [ "$HAS_PRINT" = false ] && [ ! -t 1 ]; then
  cat >&2 <<'EOF'
Error: stdout is not a TTY — interactive UI needs a real terminal.

  Examples: Terminal.app, iTerm2, Warp, Alacritty.

  Non-interactive:
    echo "your prompt" | ./start.sh -p --bare
    ./start.sh -p "your prompt" --bare
EOF
  exit 1
fi

export OPENAI_API_KEY="$EDGECLAW_API_KEY"
export OPENAI_BASE_URL="$EDGECLAW_API_BASE_URL"
export OPENAI_MODEL="$EDGECLAW_MODEL"
export PROXY_PORT="$PROXY_PORT"

# ── Start local Anthropic→OpenAI proxy (if not already running) ──
if ! curl -s "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1; then
  bun run "$DIR/proxy.ts" > "$DIR/.proxy.log" 2>&1 &
  PROXY_PID=$!
  for _ in $(seq 1 20); do
    if curl -s "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  trap "kill $PROXY_PID 2>/dev/null" EXIT
fi

# ── Claude Code: point at local proxy ──
unset ANTHROPIC_AUTH_TOKEN
export ANTHROPIC_API_KEY="$EDGECLAW_API_KEY"
export ANTHROPIC_BASE_URL="http://127.0.0.1:$PROXY_PORT"
export DISABLE_TELEMETRY="${DISABLE_TELEMETRY:-1}"
export ANTHROPIC_MODEL="$EDGECLAW_MODEL"

exec bun run --preload="$DIR/preload.ts" "$DIR/src/entrypoints/cli.tsx" "$@"
