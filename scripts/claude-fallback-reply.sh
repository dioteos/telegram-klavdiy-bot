#!/usr/bin/env bash
# Fallback wrapper — invoked by the sidecar when REPL has been unresponsive
# to a Telegram inbound for >60s AND repl-heartbeat is >90s stale.
# Spawns a one-shot `claude -p` to read the inbox/<msg_id>.json, formulate a
# brief reply, and send it via curl to the Telegram Bot API.
#
# Usage: claude-fallback-reply.sh <message_id>
# Logs:  ./logs/fallback-<message_id>-<YYYY-MM-DD>.log
set -euo pipefail

MSGID="${1:?usage: $0 <message_id>}"
BOT_DIR="/Users/dioteos/www/telegram-bot"
DATE="$(date +%Y-%m-%d)"
LOG_FILE="$BOT_DIR/logs/fallback-$MSGID-$DATE.log"
INBOX_FILE="$BOT_DIR/inbox/$MSGID.json"
PROMPT_TEMPLATE="$BOT_DIR/scripts/headless-prompts/fallback-reply.txt"
LOCK_DIR="/tmp/klavdiy-claude-headless.lock.d"
LOCK_WAIT_MAX=300
TIMEOUT_SEC=180

mkdir -p "$BOT_DIR/logs"

export HOME="${HOME:-/Users/dioteos}"
export TERM="${TERM:-xterm-256color}"
for dir in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.nvm/versions/node/"*/bin /opt/homebrew/bin /usr/local/bin; do
  [ -d "$dir" ] && PATH="$dir:$PATH"
done
export PATH

# Strip inherited Claude Code session env. If any CLAUDE_CODE_SESSION_* vars leak
# in (launchd sidecar bootstrapped from inside a Claude session, or a polluted
# gui-domain env), the spawned `claude -p` thinks it is a CHILD session and
# authenticates via the short-lived CLAUDE_CODE_SESSION_ACCESS_TOKEN — which goes
# stale within hours. Mirrors news-collect-headless.sh / news-digest-headless.sh.
# Note: does NOT touch TELEGRAM_BOT_TOKEN — that is sourced from channels/telegram/.env below.
unset CLAUDE_CODE_SESSION_ACCESS_TOKEN CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID \
      CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH AI_AGENT CLAUDE_EFFORT \
      CLAUDE_CODE_SSE_PORT ANTHROPIC_API_KEY 2>/dev/null || true

# Load long-lived OAuth token. Stripping the session env above is NOT enough: under
# launchd (non-GUI) the macOS Keychain is unreadable, so credentials.json OAuth refresh
# 401s. CLAUDE_CODE_OAUTH_TOKEN has higher precedence and needs no GUI session.
# Without this every fallback 401s — root cause of the 2026-07-27 00:28 double miss
# (msgs 3549/3551 unanswered: "OAuth access token has expired"). See
# memory/project_headless_oauth_token.md — EVERY wrapper that spawns `claude -p`
# needs this block; this one was missed when the news wrappers were fixed 2026-06-20.
if [ -r "$HOME/.claude/.klavdiy-oauth-token" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' < "$HOME/.claude/.klavdiy-oauth-token")"
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "$(date -Iseconds) ERROR: claude not in PATH ($PATH)" | tee -a "$LOG_FILE" >&2
  exit 3
fi

if [ -f "$HOME/.claude/channels/telegram/.env" ]; then
  # shellcheck disable=SC1091
  set -a; source "$HOME/.claude/channels/telegram/.env"; set +a
fi
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "$(date -Iseconds) ERROR: TELEGRAM_BOT_TOKEN not set" | tee -a "$LOG_FILE" >&2
  exit 5
fi
export TELEGRAM_BOT_TOKEN

if [ ! -f "$INBOX_FILE" ]; then
  echo "$(date -Iseconds) ERROR: inbox file missing: $INBOX_FILE" | tee -a "$LOG_FILE" >&2
  exit 4
fi

CHAT_ID="$(jq -r '.chat_id' "$INBOX_FILE")"
TEXT="$(jq -r '.text' "$INBOX_FILE")"

TEMPLATE_FILLED="$(sed -e "s|__BOT_DIR__|$BOT_DIR|g" \
              -e "s|__CHAT_ID__|$CHAT_ID|g" \
              -e "s|__MESSAGE_ID__|$MSGID|g" \
              "$PROMPT_TEMPLATE")"
PROMPT="$(printf '%s\n%s\n' "$TEMPLATE_FILLED" "$TEXT")"

{
  echo "=== fallback-reply msg_id=$MSGID chat_id=$CHAT_ID date=$DATE ts=$(date -Iseconds) ==="
  echo "claude=$(command -v claude) version=$(claude --version 2>&1)"
  echo "inbox_file=$INBOX_FILE"
  echo "text_preview=${TEXT:0:120}"
  echo
} >> "$LOG_FILE"

GRACE_SEC=15
CMD_PID=""
WD_PID=""

cleanup() {
  [ -n "$CMD_PID" ] && kill -9 "$CMD_PID" 2>/dev/null || true
  [ -n "$WD_PID" ] && kill "$WD_PID" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

waited=0
until mkdir "$LOCK_DIR" 2>/dev/null; do
  sleep 1
  waited=$((waited + 1))
  if [ "$waited" -gt "$LOCK_WAIT_MAX" ]; then
    echo "$(date -Iseconds) ERROR: lock wait exceeded ${LOCK_WAIT_MAX}s ($LOCK_DIR held by other wrapper)" | tee -a "$LOG_FILE" >&2
    exit 9
  fi
done

EXIT_CODE=0
cd /tmp
claude -p "$PROMPT" \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --add-dir "$BOT_DIR" \
  --dangerously-skip-permissions \
  --output-format text \
  >> "$LOG_FILE" 2>&1 &
CMD_PID=$!

( sleep "$TIMEOUT_SEC"; kill -TERM $CMD_PID 2>/dev/null; sleep $GRACE_SEC; kill -9 $CMD_PID 2>/dev/null ) &
WD_PID=$!

EXIT_CODE=0
wait $CMD_PID 2>/dev/null || EXIT_CODE=$?

kill $WD_PID 2>/dev/null || true
wait $WD_PID 2>/dev/null || true
CMD_PID=""
WD_PID=""

{
  echo
  echo "=== exit_code=$EXIT_CODE ts=$(date -Iseconds) ==="
} >> "$LOG_FILE"

if [ "$EXIT_CODE" -ne 0 ]; then
  curl -s -o /dev/null -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=🛟 Я fallback, але мій процес впав (exit=$EXIT_CODE). Перевір логи: $LOG_FILE. Спробую відповісти, коли основна сесія оживе." \
    --data-urlencode "reply_to_message_id=$MSGID" || true
fi

touch "$BOT_DIR/heartbeat"

exit "$EXIT_CODE"
