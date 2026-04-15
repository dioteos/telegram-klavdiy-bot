#!/usr/bin/env bash
# Watchdog for telegram-klavdiy
# Runs as a separate PM2 process, checks bot health every 2 minutes.
# Restarts the bot if it appears stuck (no recent heartbeat).
set -euo pipefail

BOT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEARTBEAT_FILE="$BOT_DIR/heartbeat"
PROCESS_NAME="telegram-klavdiy"
CHECK_INTERVAL=120       # seconds between checks
GRACE_PERIOD=300         # seconds after restart before checking heartbeat
HEARTBEAT_MAX_AGE=900    # seconds (15 min) — heartbeat older than this = stale
COOLDOWN=600             # seconds — minimum time between watchdog-triggered restarts
LAST_RESTART_FILE="$BOT_DIR/.watchdog_last_restart"

# Telegram notification config
TELEGRAM_ENV_FILE="$HOME/.claude/channels/telegram/.env"
ADMIN_CHAT_ID="$(python3 -c "import json; print(json.load(open('$BOT_DIR/config.json'))['admin_chat_id'])" 2>/dev/null || echo "")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] watchdog: $*"; }

# Quiet hours: 00:00–07:59 local — still log and still restart, but no Telegram push.
# Rationale: bot's reliability problem should not become a sleep-deprivation problem for the admin.
is_quiet_hour() {
  local h
  h=$(date +%H)
  h=$((10#$h))
  if [ "$h" -ge 0 ] && [ "$h" -lt 8 ]; then
    return 0
  fi
  return 1
}

notify_admin() {
  local message="$1"
  if is_quiet_hour; then
    log "QUIET HOURS — would notify: $message"
    return
  fi
  if [ -z "$ADMIN_CHAT_ID" ]; then
    log "WARN: no admin_chat_id, skipping notification"
    return
  fi
  local token=""
  if [ -f "$TELEGRAM_ENV_FILE" ]; then
    token=$(grep '^TELEGRAM_BOT_TOKEN=' "$TELEGRAM_ENV_FILE" | cut -d= -f2-)
  fi
  if [ -z "$token" ]; then
    log "WARN: no bot token found, skipping notification"
    return
  fi
  curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d chat_id="$ADMIN_CHAT_ID" \
    -d text="$message" > /dev/null 2>&1 || log "WARN: failed to send Telegram notification"
}

get_uptime_seconds() {
  local pm_uptime
  pm_uptime=$(pm2 jlist 2>/dev/null \
    | python3 -c "
import sys, json
procs = [p for p in json.loads(sys.stdin.read()) if p['name'] == '$PROCESS_NAME']
print(procs[0]['pm2_env']['pm_uptime'] if procs else 0)
" 2>/dev/null || echo 0)
  if [ "$pm_uptime" -gt 0 ] 2>/dev/null; then
    local now_ms
    now_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    echo $(( (now_ms - pm_uptime) / 1000 ))
  else
    echo 0
  fi
}

is_in_cooldown() {
  if [ -f "$LAST_RESTART_FILE" ]; then
    local last_restart
    last_restart=$(cat "$LAST_RESTART_FILE")
    local now
    now=$(date +%s)
    if (( now - last_restart < COOLDOWN )); then
      return 0  # in cooldown
    fi
  fi
  return 1  # not in cooldown
}

do_restart() {
  local reason="$1"
  if is_in_cooldown; then
    log "SKIP restart (cooldown active) — reason: $reason"
    notify_admin "🐕 Watchdog: рестарт пропущено (cooldown). Причина: $reason"
    return
  fi
  log "RESTARTING — reason: $reason"
  notify_admin "🐕 Watchdog: перезапускаю бот. Причина: $reason"
  date +%s > "$LAST_RESTART_FILE"
  pm2 restart "$PROCESS_NAME" 2>&1 | while read -r line; do log "  $line"; done
}

log "started — checking every ${CHECK_INTERVAL}s, grace ${GRACE_PERIOD}s, max heartbeat age ${HEARTBEAT_MAX_AGE}s"

while true; do
  sleep "$CHECK_INTERVAL"

  # 1. Check if process is running at all
  status=$(pm2 jlist 2>/dev/null \
    | python3 -c "
import sys, json
procs = [p for p in json.loads(sys.stdin.read()) if p['name'] == '$PROCESS_NAME']
print(procs[0]['pm2_env']['status'] if procs else 'missing')
" 2>/dev/null || echo "unknown")

  if [ "$status" != "online" ]; then
    log "process not online (status=$status), skipping check"
    continue
  fi

  # 2. Get uptime — skip check during grace period
  uptime_sec=$(get_uptime_seconds)
  if [ "$uptime_sec" -lt "$GRACE_PERIOD" ]; then
    continue
  fi

  # 3. Check heartbeat file
  if [ ! -f "$HEARTBEAT_FILE" ]; then
    do_restart "no heartbeat file after ${uptime_sec}s uptime"
    continue
  fi

  # macOS stat: -f %m = modification time in epoch seconds
  file_mtime=$(stat -f %m "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  heartbeat_age=$(( now - file_mtime ))

  if [ "$heartbeat_age" -gt "$HEARTBEAT_MAX_AGE" ]; then
    do_restart "heartbeat stale (${heartbeat_age}s old, max ${HEARTBEAT_MAX_AGE}s)"
  fi
done
