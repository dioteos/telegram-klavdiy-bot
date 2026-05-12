#!/usr/bin/env bash
# Headless news-collect runner — invoked by launchd at 08:03 / 13:07 / 17:47 EEST.
# Each invocation is a short-lived `claude -p` process that:
#   1. Reads ./tasks/news-collect-{slot}.md as the task spec
#   2. Runs WebSearch + dedup + appends to ./news/collect-{date}.json
#   3. Updates ./state.json.last_fire and ./heartbeat
#   4. Skips Telegram admin notify (no MCP plugin in headless mode)
#
# Usage:
#   news-collect-headless.sh {morning|midday|afternoon}
#   TEST_MODE=1 news-collect-headless.sh {slot}   # smoke-test, no WebSearch
# Logs:  ./logs/headless-{slot}-{YYYY-MM-DD}.log
set -euo pipefail

SLOT="${1:?usage: $0 morning|midday|afternoon}"
case "$SLOT" in
  morning|midday|afternoon) ;;
  *) echo "ERROR: invalid slot '$SLOT'" >&2; exit 2 ;;
esac

BOT_DIR="/Users/dioteos/www/telegram-bot"
DATE="$(date +%Y-%m-%d)"
LOG_FILE="$BOT_DIR/logs/headless-$SLOT-$DATE.log"
TASK_FILE="$BOT_DIR/tasks/news-collect-$SLOT.md"
PROMPT_TEMPLATE="$BOT_DIR/scripts/headless-prompts/news-collect.txt"
TIMEOUT_SEC=600

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

if [ "${TEST_MODE:-0}" = "1" ]; then
  PROMPT="Reply on a single line: TEST_OK slot=$SLOT date=$DATE host=HOSTNAME. Use the Bash tool ONCE to run hostname. No other tools. Do not load any CLAUDE.md."
else
  if [ ! -f "$PROMPT_TEMPLATE" ]; then
    echo "ERROR: prompt template missing: $PROMPT_TEMPLATE" >&2
    exit 4
  fi
  PROMPT="$(sed -e "s|__BOT_DIR__|$BOT_DIR|g" \
                -e "s|__TASK_FILE__|$TASK_FILE|g" \
                -e "s|__SLOT__|$SLOT|g" \
                -e "s|__DATE__|$DATE|g" \
                "$PROMPT_TEMPLATE")"
fi

{
  echo "=== headless news-collect — slot=$SLOT date=$DATE ts=$(date -Iseconds) ==="
  echo "PATH=$PATH"
  echo "claude=$(command -v claude) version=$(claude --version 2>&1)"
  echo "task_file=$TASK_FILE"
  echo "test_mode=${TEST_MODE:-0}"
  echo
} >> "$LOG_FILE"

EXIT_CODE=0
# Serialize against fallback + digest — shared mkdir lock (macOS has no flock).
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

exit "$EXIT_CODE"
