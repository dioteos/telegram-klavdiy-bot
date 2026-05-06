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

# Kill competing Telegram plugin instances so only this bot polls getUpdates.
# Multiple consumers on the same bot token cause 409 Conflict — messages get lost.
# Two patterns: the `bun run` wrapper (cwd contains telegram), and the actual
# `bun server.ts` (no telegram in argv but its parent wrapper is the wrapper).
# Killing the wrapper alone is enough — server.ts dies via stdin EOF + orphan
# watchdog. We kill both to be safe even if reparenting weirdness happens.
pkill -f 'bun run --cwd.*telegram.*start' 2>/dev/null || true
# Kill bun server.ts whose --cwd ancestor was the telegram plugin path.
# After the wrapper kill above, only orphan server.ts processes survive — get
# them via cwd inspection (Linux /proc has cwd; macOS uses lsof which is slow).
# Cheaper heuristic: the plugin's PID lockfile holds the live server.ts PID.
if [ -r "$HOME/.claude/channels/telegram/bot.pid" ]; then
  stale_pid=$(cat "$HOME/.claude/channels/telegram/bot.pid" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$stale_pid" ] && [ "$stale_pid" -gt 1 ] 2>/dev/null; then
    if ps -p "$stale_pid" -o args= 2>/dev/null | grep -q 'server\.ts'; then
      kill "$stale_pid" 2>/dev/null || true
    fi
  fi
fi
sleep 1

# expect allocates its own PTY — Claude Code requires a TTY
# Timeout = 23 hours — safety net for hung sessions.
# PM2 cron_restart at 4 AM / 4 PM gives a fresh session twice daily;
# this catches sessions that hang and never exit on their own.
exec expect -c '
set timeout 82800
spawn claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions "Execute the Startup procedure defined in CLAUDE.md. Follow all 6 steps in order."
expect {
    timeout { puts "Session timed out after 23h — exiting for PM2 restart"; exit 1 }
    eof
}
'
