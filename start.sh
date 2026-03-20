#!/usr/bin/env bash
set -euo pipefail

# Resolve HOME if not set (e.g. when launched by PM2 at boot)
export HOME="${HOME:-$(eval echo ~"$(whoami)")}"
export TERM="${TERM:-xterm-256color}"

# Build PATH dynamically — add common tool locations if they exist
for dir in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.nvm/versions/node/"*/bin /opt/homebrew/bin /usr/local/bin; do
  [ -d "$dir" ] && PATH="$dir:$PATH"
done
export PATH

cd "$HOME"

# expect allocates its own PTY — Claude Code requires a TTY
exec expect -c '
set timeout -1
spawn claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions
expect eof
'
