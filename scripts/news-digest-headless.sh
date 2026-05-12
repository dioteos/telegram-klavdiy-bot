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
TIMEOUT_SEC=900

mkdir -p "$BOT_DIR/logs"

# launchd gives a minimal env. Reproduce the PATH from start.sh.
export HOME="${HOME:-/Users/dioteos}"
export TERM="${TERM:-xterm-256color}"
for dir in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.nvm/versions/node/"*/bin /opt/homebrew/bin /usr/local/bin; do
  [ -d "$dir" ] && PATH="$dir:$PATH"
done
export PATH

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

EXIT_CODE=0
# Serialize against fallback + collect — shared mkdir lock (macOS has no flock).
LOCK_DIR="/tmp/klavdiy-claude-headless.lock.d"
waited=0
until mkdir "$LOCK_DIR" 2>/dev/null; do
  sleep 1
  waited=$((waited + 1))
  if [ "$waited" -gt 300 ]; then
    echo "$(date -Iseconds) ERROR: lock wait >300s, aborting" | tee -a "$LOG_FILE" >&2
    exit 9
  fi
done
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
cd /tmp
perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_SEC" \
  claude -p "$PROMPT" \
    --add-dir "$BOT_DIR" \
    --dangerously-skip-permissions \
    --output-format text \
  >> "$LOG_FILE" 2>&1 || EXIT_CODE=$?

{
  echo
  echo "=== exit_code=$EXIT_CODE ts=$(date -Iseconds) ==="
} >> "$LOG_FILE"

# Touch heartbeat regardless — even a failed headless run shouldn't make watchdog fire
touch "$BOT_DIR/heartbeat"

# On failure, send admin a blocker DM (defensive — the prompt should also try, but if it crashed before sending we still notify).
if [ "$EXIT_CODE" -ne 0 ] && [ "${TEST_MODE:-0}" != "1" ]; then
  curl -s -o /dev/null -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$ADMIN_CHAT_ID" \
    --data-urlencode "text=⚠️ headless-digest $STAGE FAILED (exit=$EXIT_CODE) — log: $LOG_FILE" || true
fi

exit "$EXIT_CODE"
