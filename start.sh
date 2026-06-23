#!/usr/bin/env bash
set -euo pipefail

# Resolve HOME if not set (e.g. when launched by PM2 at boot)
export HOME="${HOME:-$(eval echo ~"$(whoami)")}"
export TERM="${TERM:-xterm-256color}"

# Strip inherited Claude Code session env. If start.sh is launched from INSIDE a
# Claude session (interactive `pm2 start/restart`, or a `pm2 resurrect` whose
# dump.pm2 was saved from such a session), these vars make the spawned `claude`
# think it is a CHILD session and authenticate via CLAUDE_CODE_SESSION_ACCESS_TOKEN
# — which is short-lived and goes stale — instead of the long-lived OAuth creds in
# ~/.claude. Result: "Please run /login · API Error: 401". The bot must always run
# as an independent top-level session. (Root cause of the 2026-06-20 outage.)
unset CLAUDE_CODE_SESSION_ACCESS_TOKEN CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID \
      CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH AI_AGENT CLAUDE_EFFORT \
      CLAUDE_CODE_SSE_PORT ANTHROPIC_API_KEY 2>/dev/null || true

# Long-lived OAuth token (from `claude setup-token`, valid ~1 year) so the bot
# authenticates WITHOUT the macOS Keychain. The Keychain is unreadable when pm2 is
# boot-resurrected by the LaunchAgent (non-GUI session) — that caused the 2026-06-20
# 401 outage. CLAUDE_CODE_OAUTH_TOKEN has higher precedence than Keychain creds and
# bills against the subscription. Stored 0600 outside the repo (never committed).
# Regenerate before expiry: `claude setup-token` > ~/.claude/.klavdiy-oauth-token
if [ -r "$HOME/.claude/.klavdiy-oauth-token" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' < "$HOME/.claude/.klavdiy-oauth-token")"
fi

# Isolated config dir — THE fix for the recurring ~8h 401 (root cause found 2026-06-23).
# The default ~/.claude/.credentials.json holds a refreshable /login subscription cred
# (8h access token + refresh token). Claude Code 2.1.x has a regression (gh #68241/#70124)
# where that on-disk file OVERRIDES CLAUDE_CODE_OAUTH_TOKEN from env — so despite exporting
# our static 1-yr setup-token above, the bot actually ran on the 8h cred and 401'd every
# ~8h when its refresh failed in the daemon context (locked Keychain + concurrent claude
# processes racing the single-use refresh token + transient 5xx). ~/.claude-klavdiy is a
# symlink mirror of ~/.claude with EVERYTHING except .credentials.json, so the bot sees the
# telegram plugin + channel config but NO refreshable cred → uses the static token (no
# expiry, no refresh, no Keychain). Rebuild the mirror: ./scripts/build-config-dir.sh
export CLAUDE_CONFIG_DIR="$HOME/.claude-klavdiy"

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
# NOTE: not `exec` — we need to run code AFTER the session exits (the backoff below).
SESSION_START=$(date +%s)
expect -c '
set timeout 82800
spawn claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions "Execute the Startup procedure defined in CLAUDE.md. Follow all 6 steps in order."
expect {
    timeout { puts "Session timed out after 23h — exiting for PM2 restart"; exit 1 }
    eof
}
'
EXIT_CODE=$?
SESSION_DUR=$(( $(date +%s) - SESSION_START ))

# Crash/auth-loop throttle (root cause of the 2026-06-22 3h outage): when claude
# exits almost immediately (e.g. a transient "401 / Please run /login" on startup),
# PM2 relaunches instantly and the rapid repeated session creation SUSTAINS the 401.
# Sleeping before exit guarantees a floor on the relaunch interval so a transient can
# clear instead of spinning. Pairs with PM2 exp_backoff_restart_delay + the watchdog's
# auth-loop detector. A healthy long-lived session skips this entirely.
if [ "$SESSION_DUR" -lt 60 ]; then
  echo "[start.sh] session exited after ${SESSION_DUR}s (code ${EXIT_CODE}) — backing off 60s to throttle restart loop"
  sleep 60
fi
exit "$EXIT_CODE"
