#!/usr/bin/env bash
# launchd wrapper for the Telegram safety-net sidecar.
# launchd KeepAlive=true respawns this if it dies (ThrottleInterval=10s in plist).
set -euo pipefail

BOT_DIR="/Users/dioteos/www/telegram-bot"
LOG_FILE="$BOT_DIR/logs/sidecar.log"

mkdir -p "$BOT_DIR/logs"

export HOME="${HOME:-/Users/dioteos}"
export TERM="${TERM:-xterm-256color}"
for dir in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.nvm/versions/node/"*/bin /opt/homebrew/bin /usr/local/bin; do
  [ -d "$dir" ] && PATH="$dir:$PATH"
done
export PATH

if ! command -v bun >/dev/null 2>&1; then
  echo "$(date -Iseconds) ERROR: bun not in PATH ($PATH)" | tee -a "$LOG_FILE" >&2
  exit 1
fi

echo "$(date -Iseconds) sidecar wrapper starting (bun=$(command -v bun))" >> "$LOG_FILE"
exec bun "$BOT_DIR/scripts/sidecar.ts" >> "$LOG_FILE" 2>&1
