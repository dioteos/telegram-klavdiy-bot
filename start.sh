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

cd "$(dirname "$0")"

# expect allocates its own PTY — Claude Code requires a TTY
# Timeout = 23 hours — safety net for hung sessions.
# PM2 cron_restart at 4 AM gives a fresh session daily;
# this catches sessions that hang and never exit on their own.
exec expect -c '
set timeout 82800
spawn claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions "Execute the Startup procedure defined in CLAUDE.md. Follow all 6 steps in order."
expect {
    timeout { puts "Session timed out after 23h — exiting for PM2 restart"; exit 1 }
    eof
}
'
