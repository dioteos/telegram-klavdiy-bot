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
REPL_HB_FILE="$BOT_DIR/repl-heartbeat"
REPL_HB_MAX_AGE=600     # seconds (10 min) — REPL heartbeat older than this = REPL hung
COOLDOWN=600             # seconds — minimum time between watchdog-triggered restarts
EXTENDED_COOLDOWN=1800   # seconds — used after escalation to silence spam (30 min)
ESCALATION_THRESHOLD=3   # consecutive restarts without heartbeat recovery → admin escalation
LAST_RESTART_FILE="$BOT_DIR/.watchdog_last_restart"
COUNTER_FILE="$BOT_DIR/.watchdog_consecutive_restarts"
ESCALATED_FILE="$BOT_DIR/.watchdog_escalated"

# Auth-failure loop handling (added after the 2026-06-22 outage).
# A transient 401 / "Please run /login" turns into a multi-hour outage when the bot
# is restarted blindly: rapid repeated session creation on a shared inference-only
# OAuth token never clears the condition — it SUSTAINS it. So when we see auth
# errors in the bot log we space restarts far apart and stop hammering quickly,
# letting a transient clear on its own (pm2 + start.sh keep spaced-retrying) and
# alerting the admin loudly for a persistent one.
BOT_OUT_LOG="$HOME/.pm2/logs/telegram-klavdiy-out.log"
AUTH_FAIL_COOLDOWN=900   # seconds (15 min) — wide spacing between auth-loop restarts
AUTH_FAIL_THRESHOLD=2    # auth-loop restarts before we STOP restarting and just alert

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

# Detect a FRESH auth-failure loop in the bot log. These are not fixed by restarts
# (the restart-storm itself sustains the 401). Returns 0 if 401/"Please run /login"
# was logged recently (log written within the last ~4 min so we don't act on stale
# errors that already recovered).
auth_failure_recent() {
  [ -f "$BOT_OUT_LOG" ] || return 1
  local lmtime now
  lmtime=$(stat -f %m "$BOT_OUT_LOG" 2>/dev/null || echo 0)
  now=$(date +%s)
  (( now - lmtime > 240 )) && return 1
  tail -c 20000 "$BOT_OUT_LOG" 2>/dev/null \
    | grep -qE '401 Invalid authentication|Please run /login'
}

read_counter() {
  if [ -f "$COUNTER_FILE" ]; then
    cat "$COUNTER_FILE"
  else
    echo 0
  fi
}

write_counter() {
  echo "$1" > "$COUNTER_FILE"
}

current_cooldown() {
  # If we've already escalated and haven't reset, use the extended cooldown
  # to avoid spam while admin investigates.
  if [ -f "$ESCALATED_FILE" ]; then
    echo "$EXTENDED_COOLDOWN"
  else
    echo "$COOLDOWN"
  fi
}

is_in_cooldown() {
  if [ -f "$LAST_RESTART_FILE" ]; then
    local last_restart
    last_restart=$(cat "$LAST_RESTART_FILE")
    local now
    now=$(date +%s)
    local cd
    cd=$(current_cooldown)
    if (( now - last_restart < cd )); then
      return 0  # in cooldown
    fi
  fi
  return 1  # not in cooldown
}

# A bare `pm2 restart` does NOT reliably clear a 401 / hung --channels session: the
# old claude/expect/bun tree and the server-side auth state overlap with the new
# session and the 401 persists (2026-06-22 evening: 3 bare pm2-restarts all 401'd;
# a full stop → kill orphans → settle → start recovered immediately, identical to the
# morning manual recovery). So every watchdog restart goes through this clean path.
clean_restart() {
  pm2 stop "$PROCESS_NAME" >/dev/null 2>&1 || true
  pkill -f 'expect -c' 2>/dev/null || true
  pkill -f 'claude --channels plugin:telegram' 2>/dev/null || true
  pkill -f 'bun run --cwd.*telegram.*start' 2>/dev/null || true
  sleep 10
  pm2 start "$PROCESS_NAME" >/dev/null 2>&1 || pm2 restart "$PROCESS_NAME" >/dev/null 2>&1 || true
  log "  clean restart done (stop + kill orphans + 10s settle + start)"
}

do_restart() {
  local reason="$1"
  local is_auth="${2:-0}"   # 1 = auth-failure loop (wide spacing, stop hammering early)

  # Per-severity cooldown: auth loops get a much wider window since rapid restarts
  # don't fix a 401 and only sustain it.
  local cd
  if [ "$is_auth" = "1" ]; then cd="$AUTH_FAIL_COOLDOWN"; else cd="$(current_cooldown)"; fi
  if [ -f "$LAST_RESTART_FILE" ]; then
    local last now
    last=$(cat "$LAST_RESTART_FILE"); now=$(date +%s)
    if (( now - last < cd )); then
      log "SKIP restart (cooldown ${cd}s active) — reason: $reason"
      [ "$is_auth" = "1" ] || notify_admin "🐕 Watchdog: рестарт пропущено (cooldown). Причина: $reason"
      return
    fi
  fi

  local counter
  counter=$(read_counter)

  # Auth loop past threshold: STOP restarting (futile) — alert once, then sit quiet.
  # pm2 + start.sh keep spaced-retrying in the background; a transient clears on its
  # own and reset_counter_on_recovery() lifts this state when the heartbeat returns.
  if [ "$is_auth" = "1" ] && [ "$counter" -ge "$AUTH_FAIL_THRESHOLD" ]; then
    if [ ! -f "$ESCALATED_FILE" ]; then
      touch "$ESCALATED_FILE"
      notify_admin "🚨 Watchdog: бот у циклі 401 / «Please run /login» ($counter спроб). Рестарти не лікують 401 — припиняю штурм. Перевір токен ~/.claude/.klavdiy-oauth-token (онови через 'claude setup-token') та 'pm2 logs telegram-klavdiy'. Якщо транзієнт — мине саме; ручний фікс: stop watchdog+бот, kill orphans, один чистий рестарт."
    else
      log "auth-loop persists ($counter) — staying in backoff, NOT restarting. $reason"
    fi
    return
  fi

  counter=$((counter + 1))
  write_counter "$counter"
  log "RESTARTING (consecutive=$counter, auth=$is_auth) — reason: $reason"
  notify_admin "🐕 Watchdog: перезапускаю бот (#$counter поспіль). Причина: $reason"
  date +%s > "$LAST_RESTART_FILE"
  clean_restart

  # Escalation for ordinary hangs: louder alert + switch to extended cooldown.
  if [ "$is_auth" != "1" ] && [ "$counter" -ge "$ESCALATION_THRESHOLD" ] && [ ! -f "$ESCALATED_FILE" ]; then
    touch "$ESCALATED_FILE"
    notify_admin "🚨 Watchdog ескалація: $counter рестартів поспіль не повертають здоровʼя. Можливо потрібне ручне втручання. Cooldown → ${EXTENDED_COOLDOWN}s. Перевір 'pm2 logs telegram-klavdiy' і Telegram MCP plugin."
  fi
}

reset_counter_on_recovery() {
  # Called when heartbeat is fresh AND we are past the grace period.
  # Means the most recent restart "took" — reset escalation state.
  local counter
  counter=$(read_counter)
  if [ "$counter" -gt 0 ] || [ -f "$ESCALATED_FILE" ]; then
    log "heartbeat fresh — resetting consecutive counter (was $counter), clearing escalation"
    write_counter 0
    rm -f "$ESCALATED_FILE"
    if [ "$counter" -ge "$ESCALATION_THRESHOLD" ]; then
      notify_admin "✅ Watchdog: бот відновився після $counter рестартів. Cooldown повертається до ${COOLDOWN}s."
    fi
  fi
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

  # 2.5 Auth-failure loop short-circuit (2026-06-22 outage class).
  # If the bot log shows fresh 401 / "Please run /login", the REPL can't authenticate.
  # Blind rapid restarts SUSTAIN this rather than fix it, so handle it here — wide
  # spacing + early stop + loud alert — before the MCP/heartbeat branches (which would
  # otherwise fire ordinary rapid restarts and feed the storm).
  if auth_failure_recent; then
    do_restart "auth-failure loop — fresh 401 / «Please run /login» in bot log (restarts don't fix this)" 1
    continue
  fi

  # 3. Liveness check for MCP plugin subprocess (the actual cause of "bot is deaf").
  # Bot's claude must have a bun MCP child running the telegram plugin server.
  # If missing, REPL can SEND via curl fallback but cannot RECEIVE getUpdates → deaf.
  # Heartbeat alone misses this because the keepalive cron inside the REPL keeps touching it.
  expect_pid=""
  for pid in $(pgrep -f 'expect -c' 2>/dev/null || true); do
    if ps -p "$pid" -o args= 2>/dev/null | grep -q 'claude --channels plugin:telegram'; then
      expect_pid="$pid"
      break
    fi
  done
  if [ -n "$expect_pid" ]; then
    claude_pid=$(pgrep -P "$expect_pid" 2>/dev/null | head -1 || true)
    if [ -n "$claude_pid" ] && ! pgrep -P "$claude_pid" -f 'bun.*telegram' >/dev/null 2>&1; then
      do_restart "MCP subprocess missing under bot claude pid $claude_pid (deaf to incoming)"
      continue
    fi
  fi

  # 4. Check REPL liveness via repl-heartbeat
  # Catches "REPL hung but MCP subprocess alive" — the gap heartbeat+MCP checks miss.
  # Keepalive cron touches repl-heartbeat every 8 min; 10 min threshold = no false positives.
  if [ -f "$REPL_HB_FILE" ]; then
    repl_mtime=$(stat -f %m "$REPL_HB_FILE" 2>/dev/null || echo 0)
    now_repl=$(date +%s)
    repl_age=$(( now_repl - repl_mtime ))
    if [ "$repl_age" -gt "$REPL_HB_MAX_AGE" ]; then
      do_restart "REPL heartbeat stale (${repl_age}s, max ${REPL_HB_MAX_AGE}s) — REPL hung, MCP alive"
      continue
    fi
  fi

  # 5. Check machine heartbeat file
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
  else
    # Both heartbeats fresh AND we're past grace period → bot looks healthy
    reset_counter_on_recovery
  fi
done
