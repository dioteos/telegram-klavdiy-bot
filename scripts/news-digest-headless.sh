#!/usr/bin/env bash
# Headless news-digest runner — invoked by launchd at 18:57 (prenotify) / 19:15 (publish) EEST.
# Each invocation is a short-lived `claude -p` process that:
#   1. Reads ./tasks/news-digest-{stage}.md as the task spec
#   2. For prenotify: reads collect file, runs WebSearch catchup if any cat <3, sends admin DM via curl
#   3. For publish: reads collect file, applies freshness filter, posts 5 categories MarkdownV2 to channel via curl, footer, writes news/{date}.json with message_ids, sends admin DM
#   4. Updates ./state.json.last_fire and ./heartbeat
#   5. NO Telegram MCP plugin — uses raw HTTPS calls to api.telegram.org
#
# Usage:
#   news-digest-headless.sh {prenotify|publish}
#   TEST_MODE=1 news-digest-headless.sh {stage}   # smoke-test, no WebSearch, no real send
# Logs:  ./logs/headless-digest-{stage}-{YYYY-MM-DD}.log
set -euo pipefail

STAGE="${1:?usage: $0 prenotify|publish}"
case "$STAGE" in
  prenotify|publish) ;;
  *) echo "ERROR: invalid stage '$STAGE'" >&2; exit 2 ;;
esac

BOT_DIR="/Users/dioteos/www/telegram-bot"
DATE="$(date +%Y-%m-%d)"
LOG_FILE="$BOT_DIR/logs/headless-digest-$STAGE-$DATE.log"
TASK_FILE="$BOT_DIR/tasks/news-digest-$STAGE.md"
PROMPT_TEMPLATE="$BOT_DIR/scripts/headless-prompts/news-digest-$STAGE.txt"
case "$STAGE" in
  prenotify) TIMEOUT_SEC=900  ;;  # 15 min — prenotify is lightweight
  publish)   TIMEOUT_SEC=1800 ;;  # 30 min — publish does formatting + dedup + catchup WebSearch
esac

mkdir -p "$BOT_DIR/logs"

# launchd gives a minimal env. Reproduce the PATH from start.sh.
export HOME="${HOME:-/Users/dioteos}"
export TERM="${TERM:-xterm-256color}"
for dir in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.nvm/versions/node/"*/bin /opt/homebrew/bin /usr/local/bin; do
  [ -d "$dir" ] && PATH="$dir:$PATH"
done
export PATH

# Strip inherited Claude Code session env. If any CLAUDE_CODE_SESSION_* vars leak
# in (e.g. launchd agent bootstrapped from inside a Claude session, or a polluted
# gui-domain env), the spawned `claude -p` thinks it is a CHILD session and
# authenticates via the short-lived CLAUDE_CODE_SESSION_ACCESS_TOKEN — which goes
# stale within hours — instead of the long-lived OAuth in ~/.claude/.credentials.json.
# Result: "API Error: 401 Invalid authentication credentials". This is the same
# fix start.sh applies for the REPL. (Root cause of the 2026-06-20 headless outage.)
# Note: does NOT touch TELEGRAM_BOT_TOKEN — that is sourced from channels/telegram/.env below.
unset CLAUDE_CODE_SESSION_ACCESS_TOKEN CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID \
      CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH AI_AGENT CLAUDE_EFFORT \
      CLAUDE_CODE_SSE_PORT ANTHROPIC_API_KEY 2>/dev/null || true

if ! command -v claude >/dev/null 2>&1; then
  echo "$(date -Iseconds) ERROR: claude not in PATH ($PATH)" | tee -a "$LOG_FILE" >&2
  exit 3
fi

# Load Telegram bot token from channel .env (the same file the watchdog and curl-fallback read).
if [ -f "$HOME/.claude/channels/telegram/.env" ]; then
  # shellcheck disable=SC1091
  set -a; source "$HOME/.claude/channels/telegram/.env"; set +a
fi
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "$(date -Iseconds) ERROR: TELEGRAM_BOT_TOKEN not set (~/.claude/channels/telegram/.env missing or empty)" | tee -a "$LOG_FILE" >&2
  exit 5
fi

# Read config
ADMIN_CHAT_ID="$(jq -r '.admin_chat_id' "$BOT_DIR/config.json")"
TARGET_CHAT_ID="$(jq -r '.target_chat_id' "$BOT_DIR/config.json")"
TARGET_MODE="$(jq -r '.target_mode' "$BOT_DIR/config.json")"
CHANNEL_CHAT_ID="$(jq -r '.channel_chat_id' "$BOT_DIR/config.json")"
export TELEGRAM_BOT_TOKEN ADMIN_CHAT_ID TARGET_CHAT_ID TARGET_MODE CHANNEL_CHAT_ID

if [ "${TEST_MODE:-0}" = "1" ]; then
  PROMPT="Reply on a single line: TEST_OK stage=$STAGE date=$DATE admin_chat=$ADMIN_CHAT_ID target_chat=$TARGET_CHAT_ID. Use the Bash tool ONCE to run hostname. No other tools. Do not load any CLAUDE.md."
else
  if [ ! -f "$PROMPT_TEMPLATE" ]; then
    echo "ERROR: prompt template missing: $PROMPT_TEMPLATE" >&2
    exit 4
  fi
  PROMPT="$(sed -e "s|__BOT_DIR__|$BOT_DIR|g" \
                -e "s|__TASK_FILE__|$TASK_FILE|g" \
                -e "s|__STAGE__|$STAGE|g" \
                -e "s|__DATE__|$DATE|g" \
                "$PROMPT_TEMPLATE")"
fi

{
  echo "=== headless news-digest — stage=$STAGE date=$DATE ts=$(date -Iseconds) ==="
  echo "PATH=$PATH"
  echo "claude=$(command -v claude) version=$(claude --version 2>&1)"
  echo "task_file=$TASK_FILE"
  echo "admin_chat=$ADMIN_CHAT_ID target_chat=$TARGET_CHAT_ID target_mode=$TARGET_MODE"
  echo "test_mode=${TEST_MODE:-0}"
  echo
} >> "$LOG_FILE"

GRACE_SEC=15
MAX_ATTEMPTS=2
RETRY_DELAY=60
LOCK_DIR="/tmp/klavdiy-claude-headless.lock.d"
CMD_PID=""
WD_PID=""

cleanup() {
  [ -n "$CMD_PID" ] && kill -9 "$CMD_PID" 2>/dev/null || true
  [ -n "$WD_PID" ] && kill "$WD_PID" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

acquire_lock() {
  local waited=0
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -gt 300 ]; then
      echo "$(date -Iseconds) ERROR: lock wait >300s, aborting" | tee -a "$LOG_FILE" >&2
      return 1
    fi
  done
}

EXIT_CODE=0
ATTEMPT=0
cd /tmp
for attempt in $(seq 1 $MAX_ATTEMPTS); do
  ATTEMPT=$attempt
  if ! acquire_lock; then
    EXIT_CODE=9
    break
  fi

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

  rmdir "$LOCK_DIR" 2>/dev/null || true

  if [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -ge 128 ]; then
    break
  fi

  if [ $attempt -lt $MAX_ATTEMPTS ]; then
    echo "$(date -Iseconds) RETRY: attempt $attempt failed (exit=$EXIT_CODE), retrying in ${RETRY_DELAY}s" >> "$LOG_FILE"
    sleep "$RETRY_DELAY"
  fi
done

{
  echo
  echo "=== exit_code=$EXIT_CODE attempts=$ATTEMPT ts=$(date -Iseconds) ==="
} >> "$LOG_FILE"

# Touch heartbeat regardless
touch "$BOT_DIR/heartbeat"

# On failure, send admin a blocker DM
if [ "$EXIT_CODE" -ne 0 ] && [ "${TEST_MODE:-0}" != "1" ]; then
  curl -s -o /dev/null -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$ADMIN_CHAT_ID" \
    --data-urlencode "text=⚠️ headless-digest $STAGE FAILED (exit=$EXIT_CODE, attempts=$ATTEMPT) — log: $LOG_FILE" || true
fi

exit "$EXIT_CODE"
