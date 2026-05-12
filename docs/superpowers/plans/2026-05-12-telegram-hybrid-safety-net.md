# Telegram Hybrid Safety-Net Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a launchd-managed safety-net sidecar that fires a headless `claude -p` fallback reply when the primary Telegram REPL fails to react to an inbound message within 60-90 s, so the bot stays reachable through chronic REPL session-hangs.

**Architecture:** Three layers — (1) plugin-level tee patches add observable inbox/ack file markers and a fallback-fired dedup-skip; (2) a Bun sidecar under launchd polls inbox/ vs ack/ vs repl-heartbeat and fires the fallback; (3) all three `claude -p` invocation paths (news-collect, news-digest, fallback) acquire a shared `flock` to prevent `posix_spawnp` contention.

**Tech Stack:** Bun (sidecar), bash (wrappers), TypeScript (plugin patches to grammy MCP server), launchd (sidecar process management), Telegram Bot API (curl for fallback send).

**Spec:** `docs/superpowers/specs/2026-05-12-telegram-hybrid-safety-net-design.md`

---

## File Map

**New files:**
- `scripts/sidecar.ts` — Bun loop, polls inbox/, fires fallback
- `scripts/sidecar.sh` — launchd wrapper (PATH setup, `exec bun sidecar.ts`)
- `scripts/claude-fallback-reply.sh` — fallback wrapper (flock, claude -p, fail-safe curl)
- `scripts/headless-prompts/fallback-reply.txt` — fallback claude prompt template
- `~/Library/LaunchAgents/com.dioteos.klavdiy.sidecar.plist` — launchd plist
- `memory/project_hybrid_sidecar.md` — architecture memory entry
- Directories: `inbox/`, `acked/`, `fallback-fired/` (gitignored)
- `repl-heartbeat` — empty file, REPL-only liveness signal

**Modified files:**
- `~/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts` — Family C patches (3 sites)
- `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts` — same Family C patches
- `scripts/news-collect-headless.sh` — add `flock` block
- `scripts/news-digest-headless.sh` — add `flock` block
- `tasks/keepalive.md` — touch `repl-heartbeat` too
- `tasks/health-check.md` — add daily prune of inbox/acked/fallback-fired older than 7 d
- `CLAUDE.md` — startup step 0.6 (sidecar verify), Family C grep checklist, repl-heartbeat clause
- `memory/project_telegram_plugin_patch.md` — append Family C diffs
- `.gitignore` — `inbox/`, `acked/`, `fallback-fired/`, `repl-heartbeat`

---

### Task 1: Bootstrap directories and gitignore

**Files:**
- Create: `/Users/dioteos/www/telegram-bot/inbox/.gitkeep`
- Create: `/Users/dioteos/www/telegram-bot/acked/.gitkeep`
- Create: `/Users/dioteos/www/telegram-bot/fallback-fired/.gitkeep`
- Modify: `/Users/dioteos/www/telegram-bot/.gitignore`

- [ ] **Step 1: Create runtime directories with .gitkeep markers**

```bash
cd /Users/dioteos/www/telegram-bot
mkdir -p inbox acked fallback-fired
touch inbox/.gitkeep acked/.gitkeep fallback-fired/.gitkeep
```

- [ ] **Step 2: Append to .gitignore**

Read current `.gitignore` first, then add:
```
# Hybrid safety-net runtime files
inbox/*
!inbox/.gitkeep
acked/*
!acked/.gitkeep
fallback-fired/*
!fallback-fired/.gitkeep
repl-heartbeat
```

- [ ] **Step 3: Touch repl-heartbeat to bootstrap**

```bash
touch /Users/dioteos/www/telegram-bot/repl-heartbeat
```

- [ ] **Step 4: Verify**

Run: `ls -la /Users/dioteos/www/telegram-bot/inbox /Users/dioteos/www/telegram-bot/acked /Users/dioteos/www/telegram-bot/fallback-fired /Users/dioteos/www/telegram-bot/repl-heartbeat`
Expected: all four exist; first three contain `.gitkeep`; repl-heartbeat is a regular file.

---

### Task 2: Family C plugin patches — cache path

**Files:**
- Modify: `/Users/dioteos/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts`

Three patch sites: handleInbound (inbox tee), react tool (ack tee), reply tool (dedup-skip + ack tee).

- [ ] **Step 1: Add `PATCH:hybrid-tee-inbox` in `handleInbound`**

Find the block ending at `mcp.notification({` (around line 962). Insert ABOVE the `mcp.notification` call, AFTER the `imagePath` line:

```ts
// PATCH:hybrid-tee-inbox — write inbox marker for sidecar safety-net.
if (msgId != null) {
  try {
    const dir = '/Users/dioteos/www/telegram-bot/inbox'
    mkdirSync(dir, { recursive: true })
    writeFileSync(`${dir}/${msgId}.json`, JSON.stringify({
      chat_id, message_id: String(msgId),
      user: from.username ?? String(from.id),
      user_id: String(from.id),
      text, ts: new Date().toISOString(),
    }))
  } catch (e) {
    process.stderr.write(`telegram tee inbox failed: ${e}\n`)
  }
}
```

- [ ] **Step 2: Add `PATCH:hybrid-tee-ack` in `react` tool handler**

Find `case 'react': {` (around line 583). After the existing `await bot.api.setMessageReaction(...)` call, before the `return` statement, insert:

```ts
// PATCH:hybrid-tee-ack — write ack marker for sidecar (react path)
try {
  const dir = '/Users/dioteos/www/telegram-bot/acked'
  mkdirSync(dir, { recursive: true })
  writeFileSync(`${dir}/${args.message_id}.json`, JSON.stringify({ ts: new Date().toISOString(), via: 'react' }))
} catch {}
```

- [ ] **Step 3: Add `PATCH:hybrid-tee-dedup` AND `PATCH:hybrid-tee-ack` in `reply` tool handler**

Find `case 'reply': {` (around line 515). At the top of the case, AFTER `const reply_to = args.reply_to != null ? Number(args.reply_to) : undefined`, insert dedup-skip:

```ts
// PATCH:hybrid-tee-dedup — if sidecar already fired fallback for this reply_to, skip.
if (reply_to != null) {
  try {
    statSync(`/Users/dioteos/www/telegram-bot/fallback-fired/${reply_to}.json`)
    process.stderr.write(`telegram reply: skipping ${reply_to} — fallback handled it\n`)
    return { content: [{ type: 'text', text: 'skipped (fallback handled)' }] }
  } catch {}
}
```

Then find the first successful `sendMessage` block (around line 546-551). After `sentIds.push(sent.message_id)` on the first iteration (or use a one-shot flag), insert an ack write at the END of the `for (let i = 0; i < chunks.length; i++)` loop, but only once per call. Simplest placement: AFTER the for-loop, BEFORE the photo/document loop. Insert:

```ts
// PATCH:hybrid-tee-ack — write ack marker for sidecar (reply path)
if (reply_to != null && sentIds.length > 0) {
  try {
    const dir = '/Users/dioteos/www/telegram-bot/acked'
    mkdirSync(dir, { recursive: true })
    writeFileSync(`${dir}/${reply_to}.json`, JSON.stringify({ ts: new Date().toISOString(), via: 'reply' }))
  } catch {}
}
```

- [ ] **Step 4: Verify markers and existing imports**

Run:
```bash
grep -c "PATCH:hybrid-tee-inbox" ~/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts
grep -c "PATCH:hybrid-tee-ack"   ~/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts
grep -c "PATCH:hybrid-tee-dedup" ~/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts
```
Expected: `1`, `2`, `1`.

`mkdirSync`, `writeFileSync`, `statSync` are already imported (line 19 of server.ts) — no new imports needed.

- [ ] **Step 5: TypeScript sanity check (no compile, just shape)**

Run: `bun --bun --no-install -e "import('${HOME}/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts').then(()=>console.log('ok')).catch(e=>{console.error(e); process.exit(1)})" 2>&1 | head -20`

If import errors related to our patches → re-read and fix. Existing plugin runs as a server (long-lived), this is best-effort syntax check.

Actual functional verification comes in Task 4 smoke test.

---

### Task 3: Family C plugin patches — marketplaces path

**Files:**
- Modify: `/Users/dioteos/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts`

Apply the SAME three patches from Task 2 to this second copy. Path is identical in structure (both are the same file from the same plugin source, differing only in install location).

- [ ] **Step 1: Apply C1 (inbox tee) to marketplaces server.ts**

Same exact patch text as Task 2 Step 1.

- [ ] **Step 2: Apply C2 (ack tee in react) to marketplaces server.ts**

Same exact patch text as Task 2 Step 2.

- [ ] **Step 3: Apply C3 (dedup-skip + ack tee in reply) to marketplaces server.ts**

Same exact patch text as Task 2 Step 3 (both pieces).

- [ ] **Step 4: Verify markers in marketplaces path**

Run:
```bash
grep -c "PATCH:hybrid-tee-inbox" ~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts
grep -c "PATCH:hybrid-tee-ack"   ~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts
grep -c "PATCH:hybrid-tee-dedup" ~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts
```
Expected: `1`, `2`, `1`.

---

### Task 4: Reload plugin and smoke-test inbox tee

**Files:** none (operational)

- [ ] **Step 1: Restart the bot to load patched plugin**

The plugin is loaded once at REPL spawn. Write a `restart_note.md` then restart:

```bash
cat > /Users/dioteos/www/telegram-bot/restart_note.md <<'EOF'
Hybrid safety-net Family C patches applied to both cache/0.0.6 and marketplaces.
Restarting to load patched plugin. Verify inbox tee works by checking ./inbox/ for new files.
EOF
pm2 restart telegram-klavdiy
```

- [ ] **Step 2: Wait 20 s for fresh REPL + plugin handshake**

Run: `sleep 20`

- [ ] **Step 3: Inspect that the new plugin is loaded**

Run:
```bash
ps -ef | grep "bun run --cwd" | grep telegram | grep -v grep
```
Expected: one line, the `--cwd` path is `cache/0.0.6` or `marketplaces`. Note the path.

Run on the same path:
```bash
grep -c "PATCH:hybrid-tee-inbox" $(ps -ef | grep "bun run --cwd" | grep telegram | grep -v grep | sed 's/.*--cwd \([^ ]*\).*/\1/')/server.ts
```
Expected: `1`.

- [ ] **Step 4: Smoke-test inbox tee with a real message**

Manually have the admin send a one-word Telegram message to the bot (e.g., "smoke"). After the new REPL session is up and reading the message:

```bash
ls -lat /Users/dioteos/www/telegram-bot/inbox/ | head -3
```
Expected: a fresh `<message_id>.json` file appears within 1-2 s of the message being sent.

```bash
cat /Users/dioteos/www/telegram-bot/inbox/<message_id>.json | jq .
```
Expected JSON shape: `{ chat_id, message_id, user, user_id, text, ts }`.

- [ ] **Step 5: Smoke-test ack tee from react**

REPL should react 👀 to the admin message per its rules. After ≤2 s:

```bash
ls -lat /Users/dioteos/www/telegram-bot/acked/ | head -3
```
Expected: a fresh `<message_id>.json` with `{ ts, via: "react" }`.

- [ ] **Step 6: Smoke-test ack tee from reply**

When REPL replies, after ≤30 s:

```bash
cat /Users/dioteos/www/telegram-bot/acked/<message_id>.json | jq .
```
Expected: `via` value is either `react` (first) and unchanged, or `reply` (if reply tool wrote second). Either is acceptable — both confirm REPL handled it.

- [ ] **Step 7: Commit Family C patches and runtime dirs**

```bash
cd /Users/dioteos/www/telegram-bot
git add .gitignore inbox/.gitkeep acked/.gitkeep fallback-fired/.gitkeep
git commit -m "Add inbox/acked/fallback-fired runtime dirs for safety-net sidecar

Plugin Family C patches (PATCH:hybrid-tee-*) live outside this repo
in ~/.claude/plugins/... — not tracked here. See
memory/project_telegram_plugin_patch.md (updated in a later commit)
for the diffs."
```

---

### Task 5: Sidecar Bun script

**Files:**
- Create: `/Users/dioteos/www/telegram-bot/scripts/sidecar.ts`

- [ ] **Step 1: Write sidecar.ts**

Full file content:

```ts
#!/usr/bin/env bun
// Sidecar safety-net for the Telegram REPL.
// Polls ./inbox/ every 5 s; fires a headless claude -p fallback when an inbound
// message has sat unhandled past 60 s AND the REPL is verifiably hung
// (repl-heartbeat > 90 s old). Writes ./fallback-fired/<id>.json before
// spawning to prevent races; the plugin's reply tool consults the same marker
// to dedup-skip if REPL recovers later.

import { readdir, stat, mkdir, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { spawn } from 'node:child_process'

const BOT_DIR = '/Users/dioteos/www/telegram-bot'
const INBOX = `${BOT_DIR}/inbox`
const ACKED = `${BOT_DIR}/acked`
const FIRED = `${BOT_DIR}/fallback-fired`
const REPL_HEARTBEAT = `${BOT_DIR}/repl-heartbeat`
const FALLBACK_WRAPPER = `${BOT_DIR}/scripts/claude-fallback-reply.sh`

const INBOX_MIN_AGE_SEC = 60
const REPL_HEARTBEAT_STALE_SEC = 90
const POLL_INTERVAL_MS = 5000
const MAX_INBOX_AGE_SEC = 24 * 3600  // skip anything older than 24 h — assume dead

function ts() {
  return new Date().toISOString()
}

async function ensureDirs() {
  for (const d of [INBOX, ACKED, FIRED]) {
    await mkdir(d, { recursive: true })
  }
}

async function fileAgeSec(path: string): Promise<number> {
  try {
    const s = await stat(path)
    return (Date.now() - s.mtimeMs) / 1000
  } catch {
    return Infinity
  }
}

async function fireFallback(msgId: string, inboxAge: number, hbAge: number) {
  const firedPath = `${FIRED}/${msgId}.json`
  // Atomic-ish marker write BEFORE spawning, so a parallel sidecar tick
  // (shouldn't happen — we are single-threaded — but for safety) and the
  // plugin's dedup-skip both see the marker.
  await writeFile(firedPath, JSON.stringify({
    ts: ts(),
    inbox_age_sec: Math.round(inboxAge),
    repl_heartbeat_age_sec: Math.round(hbAge),
  }))
  console.log(`[${ts()}] FALLBACK FIRE msg=${msgId} inbox_age=${Math.round(inboxAge)}s hb_age=${Math.round(hbAge)}s`)
  const child = spawn(FALLBACK_WRAPPER, [msgId], {
    stdio: 'ignore',
    detached: true,
  })
  child.unref()
}

async function checkInbox() {
  let entries: string[]
  try {
    entries = await readdir(INBOX)
  } catch {
    return
  }
  for (const f of entries) {
    if (!f.endsWith('.json') || f === '.gitkeep.json') continue
    const msgId = f.slice(0, -'.json'.length)

    if (existsSync(`${ACKED}/${msgId}.json`)) continue
    if (existsSync(`${FIRED}/${msgId}.json`)) continue

    const inboxAge = await fileAgeSec(`${INBOX}/${f}`)
    if (inboxAge < INBOX_MIN_AGE_SEC) continue
    if (inboxAge > MAX_INBOX_AGE_SEC) continue

    const hbAge = await fileAgeSec(REPL_HEARTBEAT)
    if (hbAge < REPL_HEARTBEAT_STALE_SEC) continue

    try {
      await fireFallback(msgId, inboxAge, hbAge)
    } catch (e) {
      console.error(`[${ts()}] fire failed msg=${msgId}: ${e}`)
    }
  }
}

async function main() {
  await ensureDirs()
  console.log(`[${ts()}] sidecar started — poll=${POLL_INTERVAL_MS}ms inbox_min_age=${INBOX_MIN_AGE_SEC}s hb_stale=${REPL_HEARTBEAT_STALE_SEC}s`)
  while (true) {
    try {
      await checkInbox()
    } catch (e) {
      console.error(`[${ts()}] tick failed: ${e}`)
    }
    await new Promise(r => setTimeout(r, POLL_INTERVAL_MS))
  }
}

main()
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x /Users/dioteos/www/telegram-bot/scripts/sidecar.ts
```

- [ ] **Step 3: Syntax check by running it for 5 s**

```bash
cd /Users/dioteos/www/telegram-bot
timeout 5 bun scripts/sidecar.ts 2>&1 | head -10
```

Expected: first line `sidecar started — poll=5000ms inbox_min_age=60s hb_stale=90s`. Exit with code 124 (timeout terminated) — that's fine, means the loop is running.

If TypeScript errors → fix inline.

---

### Task 6: Sidecar launchd wrapper

**Files:**
- Create: `/Users/dioteos/www/telegram-bot/scripts/sidecar.sh`

- [ ] **Step 1: Write sidecar.sh**

```bash
#!/usr/bin/env bash
# launchd wrapper for the Telegram safety-net sidecar.
# launchd KeepAlive=true respawns this if it dies (ThrottleInterval=10s in plist).
set -euo pipefail

BOT_DIR="/Users/dioteos/www/telegram-bot"
LOG_FILE="$BOT_DIR/logs/sidecar.log"

mkdir -p "$BOT_DIR/logs"

# launchd gives a minimal env. Reproduce the PATH from news-*-headless.sh.
export HOME="${HOME:-/Users/dioteos}"
export TERM="${TERM:-xterm-256color}"
for dir in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.nvm/versions/node/"*/bin /opt/homebrew/bin /usr/local/bin; do
  [ -d "$dir" ] && PATH="$dir:$PATH"
done
export PATH

if ! command -v bun >/dev/null 2>&1; then
  echo "$(date -Iseconds) ERROR: bun not in PATH ($PATH)" | tee -a "$LOG_FILE" >&2
  exit 1
fi

echo "$(date -Iseconds) sidecar wrapper starting (bun=$(command -v bun))" >> "$LOG_FILE"
exec bun "$BOT_DIR/scripts/sidecar.ts" >> "$LOG_FILE" 2>&1
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x /Users/dioteos/www/telegram-bot/scripts/sidecar.sh
```

- [ ] **Step 3: Run it once in the foreground for 5 s**

```bash
timeout 5 /Users/dioteos/www/telegram-bot/scripts/sidecar.sh 2>&1 | head -5
tail -5 /Users/dioteos/www/telegram-bot/logs/sidecar.log
```

Expected: `sidecar wrapper starting (bun=/path/to/bun)` followed by `sidecar started — ...`. Exit 124.

---

### Task 7: Sidecar launchd plist + bootstrap

**Files:**
- Create: `/Users/dioteos/Library/LaunchAgents/com.dioteos.klavdiy.sidecar.plist`

- [ ] **Step 1: Write the plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dioteos.klavdiy.sidecar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/dioteos/www/telegram-bot/scripts/sidecar.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/dioteos/www/telegram-bot</string>
    <key>StandardOutPath</key>
    <string>/Users/dioteos/www/telegram-bot/logs/launchd-sidecar.out</string>
    <key>StandardErrorPath</key>
    <string>/Users/dioteos/www/telegram-bot/logs/launchd-sidecar.err</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/dioteos</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 2: Bootstrap into launchd**

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dioteos.klavdiy.sidecar.plist
```

If it errors `Bootstrap failed: 5: Input/output error` → the label already loaded; bootout first:

```bash
launchctl bootout gui/$(id -u)/com.dioteos.klavdiy.sidecar 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dioteos.klavdiy.sidecar.plist
```

- [ ] **Step 3: Verify it's running**

```bash
launchctl list | grep klavdiy.sidecar
pgrep -af "bun.*sidecar.ts" | head -3
```

Expected: one launchctl entry (PID > 0) and one bun process.

- [ ] **Step 4: Verify log activity**

```bash
sleep 6
tail -3 /Users/dioteos/www/telegram-bot/logs/sidecar.log
```

Expected: at least one `sidecar started` line, possibly followed by an empty-tick loop (no output unless fallback fires).

---

### Task 8: Smoke-test sidecar happy path (no fallback when REPL healthy)

**Files:** none (operational)

- [ ] **Step 1: Confirm REPL alive and repl-heartbeat fresh**

```bash
stat -f "%Sm" /Users/dioteos/www/telegram-bot/repl-heartbeat
```

If repl-heartbeat is older than 90 s → wait until next keepalive fires, or skip ahead and update keepalive task first (Task 11).

For the smoke test specifically, manually:
```bash
touch /Users/dioteos/www/telegram-bot/repl-heartbeat
```

- [ ] **Step 2: Send a Telegram message manually**

Admin sends "happy path smoke" via Telegram.

- [ ] **Step 3: Wait 70 s and verify NO fallback fired**

```bash
sleep 70
ls /Users/dioteos/www/telegram-bot/fallback-fired/ | grep -v .gitkeep | wc -l
```

Expected: `0`.

```bash
grep "FALLBACK FIRE" /Users/dioteos/www/telegram-bot/logs/sidecar.log | tail -5
```

Expected: no new entries since sidecar start.

The REPL should have replied normally within 1-30 s — confirm in chat.

---

### Task 9: Fallback wrapper

**Files:**
- Create: `/Users/dioteos/www/telegram-bot/scripts/claude-fallback-reply.sh`
- Create: `/Users/dioteos/www/telegram-bot/scripts/headless-prompts/fallback-reply.txt`

- [ ] **Step 1: Write the fallback prompt template**

`/Users/dioteos/www/telegram-bot/scripts/headless-prompts/fallback-reply.txt`:

```
You are Klavdiy, an always-on Telegram bot. The primary REPL session is unresponsive right now (chronic session-hang bug — see __BOT_DIR__/memory/project_session_hanging.md). You are the headless safety-net invoked by the sidecar to answer this user's message so they don't go unanswered.

HARD RULES:
- One-shot invocation. No back-and-forth in this process.
- No Telegram MCP plugin available — reply via curl to the Telegram Bot API directly.
- chat_id=__CHAT_ID__   reply_to_message_id=__MESSAGE_ID__
- $TELEGRAM_BOT_TOKEN is exported in env (sourced from ~/.claude/channels/telegram/.env by the wrapper).
- Bot directory: __BOT_DIR__. For context, Read __BOT_DIR__/CLAUDE.md plus 1-3 relevant files from __BOT_DIR__/memory/ (pick by name relevance — DO NOT read all 30).
- Be brief, helpful, Ukrainian. First sentence MUST identify you as the fallback so the user knows: e.g. "🛟 Я fallback бо основна сесія залипла —" then your answer.

Send your reply with this exact pattern:

  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=__CHAT_ID__" \
    --data-urlencode "text=<your reply here>" \
    --data-urlencode "reply_to_message_id=__MESSAGE_ID__"

After sending, write a status file (the marker was already written by the sidecar; you augment it with delivery info):

  jq -n --arg ts "$(date -Iseconds)" --arg status "delivered" \
    '{ts: $ts, status: $status, via: "claude-p"}' \
    > __BOT_DIR__/fallback-fired/__MESSAGE_ID__.json

INBOUND_MESSAGE_TEXT:
__TEXT__
```

- [ ] **Step 2: Write the fallback wrapper**

`/Users/dioteos/www/telegram-bot/scripts/claude-fallback-reply.sh`:

```bash
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
LOCK_FILE="/tmp/klavdiy-claude-headless.lock"
TIMEOUT_SEC=180

mkdir -p "$BOT_DIR/logs"

# Reproduce PATH (launchd-style minimal env)
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

# Load Telegram bot token (same source as news-digest-headless.sh)
if [ -f "$HOME/.claude/channels/telegram/.env" ]; then
  # shellcheck disable=SC1091
  set -a; source "$HOME/.claude/channels/telegram/.env"; set +a
fi
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "$(date -Iseconds) ERROR: TELEGRAM_BOT_TOKEN not set" | tee -a "$LOG_FILE" >&2
  exit 5
fi
export TELEGRAM_BOT_TOKEN

# Read inbox
if [ ! -f "$INBOX_FILE" ]; then
  echo "$(date -Iseconds) ERROR: inbox file missing: $INBOX_FILE" | tee -a "$LOG_FILE" >&2
  exit 4
fi

CHAT_ID="$(jq -r '.chat_id' "$INBOX_FILE")"
TEXT="$(jq -r '.text' "$INBOX_FILE")"

# Build prompt
PROMPT="$(sed -e "s|__BOT_DIR__|$BOT_DIR|g" \
              -e "s|__CHAT_ID__|$CHAT_ID|g" \
              -e "s|__MESSAGE_ID__|$MSGID|g" \
              "$PROMPT_TEMPLATE")
$(printf 'INBOUND_MESSAGE_TEXT:\n%s\n' "$TEXT")"
# Replace the literal __TEXT__ placeholder line with empty (we appended manually
# above for safe quoting since TEXT can contain anything).
PROMPT="$(printf '%s\n' "$PROMPT" | sed '/^__TEXT__$/d')"

{
  echo "=== fallback-reply msg_id=$MSGID chat_id=$CHAT_ID date=$DATE ts=$(date -Iseconds) ==="
  echo "claude=$(command -v claude) version=$(claude --version 2>&1)"
  echo "inbox_file=$INBOX_FILE"
  echo "text_preview=${TEXT:0:120}"
  echo
} >> "$LOG_FILE"

# Serialize against news pipeline — same flock all headless wrappers use.
exec 9>"$LOCK_FILE"
flock 9

EXIT_CODE=0
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

# Fail-safe: if claude -p crashed/timed out, send a degraded notice so the user still
# gets SOMETHING. The fallback-fired marker stays in place — REPL dedup-skip still applies.
if [ "$EXIT_CODE" -ne 0 ]; then
  curl -s -o /dev/null -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=🛟 Я fallback, але мій процес впав (exit=$EXIT_CODE). Перевір логи: $LOG_FILE. Спробую відповісти, коли основна сесія оживе." \
    --data-urlencode "reply_to_message_id=$MSGID" || true
fi

# Heartbeat — keep watchdog calm even if fallback was triggered.
touch "$BOT_DIR/heartbeat"

exit "$EXIT_CODE"
```

- [ ] **Step 3: Make executable**

```bash
chmod +x /Users/dioteos/www/telegram-bot/scripts/claude-fallback-reply.sh
```

- [ ] **Step 4: Dry-run prompt assembly (no claude -p spawn)**

```bash
# Inject a fake inbox file for an obviously-test message_id
mkdir -p /Users/dioteos/www/telegram-bot/inbox
echo '{"chat_id":"120504996","message_id":"999999","user":"dioteos","user_id":"120504996","text":"smoke test","ts":"2026-05-12T02:30:00+03:00"}' > /Users/dioteos/www/telegram-bot/inbox/999999.json

# Source token but don't actually run claude — just sanity-check the prompt template
source ~/.claude/channels/telegram/.env
sed -e "s|__BOT_DIR__|/Users/dioteos/www/telegram-bot|g" \
    -e "s|__CHAT_ID__|120504996|g" \
    -e "s|__MESSAGE_ID__|999999|g" \
    /Users/dioteos/www/telegram-bot/scripts/headless-prompts/fallback-reply.txt | head -20
```

Expected: filled-in template, no `__PLACEHOLDER__` left, no syntax errors visible.

- [ ] **Step 5: Clean up the dry-run fake inbox**

```bash
rm /Users/dioteos/www/telegram-bot/inbox/999999.json
```

---

### Task 10: Smoke-test fallback fires when REPL hung

**Files:** none (operational, destructive — needs admin coordination)

- [ ] **Step 1: Coordinate window with admin**

This test deliberately hangs the bot. Admin must agree.

- [ ] **Step 2: Stop the REPL so it can't process inbound**

```bash
pm2 stop telegram-klavdiy
```

The MCP plugin (bun) is a child of the REPL — stopping pm2 kills both. From this moment Telegram messages queue at Telegram server side until a REPL or fallback picks them up. The inbox tee will NOT fire (plugin is down), so the sidecar won't see the message either.

**Adjust the test approach:** A more faithful repro of a hung REPL (plugin running, REPL stuck) is hard to force. Instead, use this two-phase approach:

  a) Keep REPL running. Manually create a fake inbox file as if the plugin had teed it:

  ```bash
  TS=$(date -Iseconds)
  echo "{\"chat_id\":\"120504996\",\"message_id\":\"888888\",\"user\":\"dioteos\",\"user_id\":\"120504996\",\"text\":\"fallback smoke (synthetic)\",\"ts\":\"$TS\"}" \
    > /Users/dioteos/www/telegram-bot/inbox/888888.json
  ```

  b) Force repl-heartbeat to look stale:

  ```bash
  touch -t $(date -v-3M +%Y%m%d%H%M.%S) /Users/dioteos/www/telegram-bot/repl-heartbeat
  ```

  This makes repl-heartbeat 3 min old, satisfying the `> 90 s` predicate.

- [ ] **Step 3: Wait for sidecar to fire (≤ 70 s after inbox age crosses 60 s)**

```bash
sleep 75
ls /Users/dioteos/www/telegram-bot/fallback-fired/
```

Expected: `888888.json` appears.

```bash
tail -10 /Users/dioteos/www/telegram-bot/logs/sidecar.log
```

Expected: a `FALLBACK FIRE msg=888888 inbox_age=...s hb_age=...s` line.

- [ ] **Step 4: Verify fallback wrapper started a claude -p**

```bash
pgrep -af "claude.*-p" | head -3
ls -lat /Users/dioteos/www/telegram-bot/logs/fallback-888888-*.log
```

Expected: at least one matching process or completed log file.

- [ ] **Step 5: Verify a real Telegram reply was sent to admin**

Admin checks chat. Expected: a message starting with "🛟 Я fallback бо основна сесія залипла —" arrives within ~30-90 s.

(If exit was non-zero, expected message is the degraded "fallback crashed" notice instead.)

- [ ] **Step 6: Restore repl-heartbeat freshness**

```bash
touch /Users/dioteos/www/telegram-bot/repl-heartbeat
```

- [ ] **Step 7: Clean up the synthetic inbox file**

```bash
rm /Users/dioteos/www/telegram-bot/inbox/888888.json
# Keep fallback-fired/888888.json to test dedup in Task 12
```

---

### Task 11: Update keepalive + heartbeat clauses

**Files:**
- Modify: `/Users/dioteos/www/telegram-bot/tasks/keepalive.md`
- Modify: `/Users/dioteos/www/telegram-bot/CLAUDE.md`

- [ ] **Step 1: Update keepalive.md**

Replace `Run \`touch ./heartbeat\` and nothing else.` with `Run \`touch ./heartbeat ./repl-heartbeat\` and nothing else.`

After:
```markdown
---
schedule: "*/8 * * * *"
enabled: true
---

Touch both heartbeat files for the watchdog and the sidecar:
- `./heartbeat` — coarse system-liveness, watchdog reads this (15-min stale → restart)
- `./repl-heartbeat` — REPL-only liveness, sidecar reads this (90 s stale → fire fallback)

Run `touch ./heartbeat ./repl-heartbeat` and nothing else. No message to admin needed.
```

- [ ] **Step 2: Update CLAUDE.md Heartbeat section**

Find the line `Run \`touch ./heartbeat\` immediately after completing Step 5 (startup summary)` and replace with `touch ./heartbeat ./repl-heartbeat`.

Same replacement on the next two bullets (after processing each Telegram message, after executing each cron task).

- [ ] **Step 3: Update CLAUDE.md startup Step 5 quiet-hours line**

The quiet-hours bullet currently says "Log it locally and touch heartbeat." → change to "Log it locally and touch `heartbeat` and `repl-heartbeat`."

- [ ] **Step 4: Add Step 0.6 (sidecar verify) to CLAUDE.md**

After Step 0.5 and before Step 1 (Config), insert:

```markdown
### 0.6. Verify sidecar (safety-net)

The safety-net sidecar runs under launchd (`com.dioteos.klavdiy.sidecar`) and answers inbound Telegram messages when the REPL hangs. On every startup:

1. `launchctl list | grep klavdiy.sidecar` — expect exactly one line, status `0` (running).
2. `pgrep -af "bun.*sidecar.ts"` — expect at least one process.
3. If missing → `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dioteos.klavdiy.sidecar.plist`. Write `restart_note.md` listing the bootstrap, DM admin (unless quiet hours).
4. Touch `./repl-heartbeat` now and after every message/cron — see Heartbeat section. The sidecar fires fallback only when this file is >90 s stale.

See `memory/project_hybrid_sidecar.md` for full architecture, trigger thresholds, and dedup mechanism.
```

- [ ] **Step 5: Add Family C to CLAUDE.md Step 0.5 patch grep checklist**

In Step 0.5, after the Family B grep block, add:

```markdown
   **Family C — `PATCH:hybrid-tee-*`** (always; introduced 2026-05-12 for hybrid safety-net):
   ```
   grep -c "PATCH:hybrid-tee-inbox" <path>/server.ts     # expect 1
   grep -c "PATCH:hybrid-tee-ack"   <path>/server.ts     # expect 2
   grep -c "PATCH:hybrid-tee-dedup" <path>/server.ts     # expect 1
   ```
   Missing any → re-apply per `memory/project_telegram_plugin_patch.md` Family C diffs.
```

- [ ] **Step 6: Verify CLAUDE.md still parses**

Run: `wc -l /Users/dioteos/www/telegram-bot/CLAUDE.md`

Read the file end-to-end to confirm no markdown corruption.

---

### Task 12: Dedup smoke test (plugin skip-send when fallback already fired)

**Files:** none (operational, depends on Task 10 leaving `fallback-fired/888888.json`)

- [ ] **Step 1: Confirm marker exists from Task 10**

```bash
ls /Users/dioteos/www/telegram-bot/fallback-fired/888888.json
```

If missing → recreate: `echo '{"ts":"2026-05-12T02:35:00+03:00","status":"smoke"}' > /Users/dioteos/www/telegram-bot/fallback-fired/888888.json`.

- [ ] **Step 2: Send a real Telegram message that the REPL will pick up**

Admin sends a normal message (e.g. "dedup smoke"). The REPL will receive it, plugin will write to `inbox/<real_id>.json`. Note the real msg_id from the inbox.

- [ ] **Step 3: Manipulate the test — simulate REPL trying to reply to old fallback-fired msg**

We can't easily force REPL to call `reply` with `reply_to=888888` (the dedup-skip lookup target). Instead, verify the dedup logic by direct test:

Read the patched plugin code in the running path (`ps -ef | grep "bun run --cwd" ...`) and confirm the `statSync(`/Users/dioteos/.../fallback-fired/${reply_to}.json`)` block is present in the `reply` tool handler.

```bash
RUNPATH=$(ps -ef | grep "bun run --cwd" | grep telegram | grep -v grep | sed 's/.*--cwd \([^ ]*\).*/\1/')
grep -A 4 "PATCH:hybrid-tee-dedup" "$RUNPATH/server.ts"
```

Expected: the dedup-skip block reads `statSync(\`/Users/dioteos/www/telegram-bot/fallback-fired/\${reply_to}.json\`)` and returns the `'skipped (fallback handled)'` content.

- [ ] **Step 4: Functional dedup test via plugin stderr**

In a separate terminal, tail pm2 logs:

```bash
pm2 logs telegram-klavdiy --raw | grep "skipping\|fallback handled"
```

Then ask admin to send a message with reply context to a message_id 888888 (admin can't actually do this for an arbitrary id, but in production this scenario only fires when REPL did try to reply after a fallback already handled it). For now, this is verified by code review of the patch. Mark step complete when grep in Step 3 confirms the dedup block is loaded.

- [ ] **Step 5: Clean up**

```bash
rm /Users/dioteos/www/telegram-bot/fallback-fired/888888.json
```

---

### Task 13: flock serialization for news pipeline

**Files:**
- Modify: `/Users/dioteos/www/telegram-bot/scripts/news-collect-headless.sh`
- Modify: `/Users/dioteos/www/telegram-bot/scripts/news-digest-headless.sh`

- [ ] **Step 1: Add flock to news-collect-headless.sh**

Find the line `EXIT_CODE=0` (around line 66) followed by `cd /tmp`. Insert BEFORE `cd /tmp`:

```bash
# Serialize against fallback + digest — shared lock prevents posix_spawnp burst.
exec 9>"/tmp/klavdiy-claude-headless.lock"
flock 9
```

So the resulting block is:

```bash
EXIT_CODE=0
# Serialize against fallback + digest — shared lock prevents posix_spawnp burst.
exec 9>"/tmp/klavdiy-claude-headless.lock"
flock 9
cd /tmp
perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_SEC" \
  ...
```

- [ ] **Step 2: Add flock to news-digest-headless.sh**

Same insertion at the analogous location (before `cd /tmp`, after `EXIT_CODE=0`).

- [ ] **Step 3: Smoke-test flock contention**

Simulate two simultaneous launches:

```bash
(/Users/dioteos/www/telegram-bot/scripts/news-collect-headless.sh morning &) 2>/dev/null
sleep 1
TEST_MODE=1 /Users/dioteos/www/telegram-bot/scripts/news-collect-headless.sh midday 2>&1 | tail -5
```

Wait until the first one finishes. Expected: the second waits, then runs. No `posix_spawnp` error in either log.

(If running this against today's collect file would corrupt it, use `TEST_MODE=1` on both. Even simpler — skip and just confirm syntax in Step 4.)

- [ ] **Step 4: Syntax check**

```bash
bash -n /Users/dioteos/www/telegram-bot/scripts/news-collect-headless.sh
bash -n /Users/dioteos/www/telegram-bot/scripts/news-digest-headless.sh
```

Expected: no output (clean syntax).

---

### Task 14: Daily cleanup of inbox/acked/fallback-fired

**Files:**
- Modify: `/Users/dioteos/www/telegram-bot/tasks/health-check.md`

- [ ] **Step 1: Append cleanup step to health-check.md**

After the existing five health-check items, append:

```markdown
6. Cleanup safety-net files: delete `./inbox/*.json`, `./acked/*.json`, `./fallback-fired/*.json` older than 7 days. Use:
   ```bash
   find ./inbox ./acked ./fallback-fired -maxdepth 1 -name '*.json' -mtime +7 -delete
   ```
   Count how many were pruned and include in the health report.
```

---

### Task 15: Memory updates

**Files:**
- Create: `/Users/dioteos/www/telegram-bot/memory/project_hybrid_sidecar.md`
- Modify: `/Users/dioteos/www/telegram-bot/memory/project_telegram_plugin_patch.md`
- Modify: `/Users/dioteos/www/telegram-bot/memory/MEMORY.md` (well, the auto-memory MEMORY.md is elsewhere — see Step 4)

- [ ] **Step 1: Create project_hybrid_sidecar.md**

```markdown
---
name: Hybrid safety-net sidecar
description: launchd Bun sidecar that fires headless claude -p fallback replies when REPL hangs on Telegram inbound. Architecture, trigger thresholds, dedup. Introduced 2026-05-12.
type: project
updated: 2026-05-12
---

The Telegram REPL has a chronic session-hang bug (CC #1589 / #45590) — a single inbound can wedge it for minutes-to-hours until watchdog catches it. The sidecar is a safety-net so users still get answered.

## Components

| Piece | Location | Role |
|---|---|---|
| Plugin Family C patches | `~/.claude/plugins/{cache,marketplaces}/.../server.ts` | tee `./inbox/<id>.json` on inbound; tee `./acked/<id>.json` on react/reply; skip-send if `./fallback-fired/<id>.json` exists |
| Sidecar | `scripts/sidecar.ts` (Bun, under launchd `com.dioteos.klavdiy.sidecar`) | polls `./inbox/` every 5 s; fires fallback when predicate met |
| Fallback wrapper | `scripts/claude-fallback-reply.sh` | acquires shared flock, runs `claude -p` with `headless-prompts/fallback-reply.txt`, replies via curl |
| flock | `/tmp/klavdiy-claude-headless.lock` | shared between fallback + news-collect + news-digest wrappers to prevent posix_spawnp contention |

## Fallback trigger predicate

```
fire IF
  inbox/<id>.json mtime > 60s ago
  AND no acked/<id>.json
  AND no fallback-fired/<id>.json
  AND repl-heartbeat mtime > 90s ago
  AND inbox/<id>.json mtime < 24h ago
```

`repl-heartbeat` is REPL-only (NOT touched by headless news scripts) — this is critical, because the watchdog's `./heartbeat` IS touched by news scripts and would mask hangs during news slots.

## Dedup mechanism

Sidecar writes `fallback-fired/<msg_id>.json` BEFORE spawning the fallback claude -p. The plugin's `reply` tool consults this marker before sending: if it exists for the `reply_to`, send is silently skipped (returns "skipped (fallback handled)"). This handles the race where REPL recovers mid-fallback and tries to send its own reply.

## Logs to check during incidents

- `./logs/sidecar.log` — every tick + every `FALLBACK FIRE`
- `./logs/fallback-<msg_id>-<date>.log` — per-fallback claude -p output
- `./logs/launchd-sidecar.{out,err}` — sidecar wrapper stdout/stderr
- `pm2 logs telegram-klavdiy --raw | grep skipping` — dedup-skips in plugin

## When to disable the sidecar (rare)

If sidecar is misfiring (false-positive fallbacks because heartbeat threshold tuning broke):

```bash
launchctl bootout gui/$(id -u)/com.dioteos.klavdiy.sidecar
```

Re-enable:
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dioteos.klavdiy.sidecar.plist
```

## Tuning

- `INBOX_MIN_AGE_SEC=60` in sidecar.ts → raise if false-fallbacks on slow tasks
- `REPL_HEARTBEAT_STALE_SEC=90` in sidecar.ts → raise to be more conservative
- `POLL_INTERVAL_MS=5000` in sidecar.ts → almost never needs tuning

Spec: `docs/superpowers/specs/2026-05-12-telegram-hybrid-safety-net-design.md`. Plan: `docs/superpowers/plans/2026-05-12-telegram-hybrid-safety-net.md`.
```

- [ ] **Step 2: Append Family C to project_telegram_plugin_patch.md**

After the existing "## Patch family B" section, BEFORE "## Verification", insert:

```markdown
## Patch family C — `PATCH:hybrid-tee-*` (safety-net sidecar tees)

**Why:** The sidecar (`scripts/sidecar.ts` under launchd) needs to observe inbound messages and REPL handling to fire a headless fallback reply when REPL hangs. Plugin tees inbound to `./inbox/`, REPL handlers tee acks to `./acked/`, plugin reply tool skip-sends when sidecar already fired via `./fallback-fired/`. Introduced 2026-05-12.

### C1 — `server.ts` `handleInbound` inbox tee

Insert BEFORE `mcp.notification({...})` near line 962:

```ts
// PATCH:hybrid-tee-inbox — write inbox marker for sidecar safety-net.
if (msgId != null) {
  try {
    const dir = '/Users/dioteos/www/telegram-bot/inbox'
    mkdirSync(dir, { recursive: true })
    writeFileSync(`${dir}/${msgId}.json`, JSON.stringify({
      chat_id, message_id: String(msgId),
      user: from.username ?? String(from.id),
      user_id: String(from.id),
      text, ts: new Date().toISOString(),
    }))
  } catch (e) {
    process.stderr.write(`telegram tee inbox failed: ${e}\n`)
  }
}
```

### C2 — `server.ts` `react` tool ack tee

After `await bot.api.setMessageReaction(...)` in `case 'react':` (around line 585), before return:

```ts
// PATCH:hybrid-tee-ack — write ack marker for sidecar (react path)
try {
  const dir = '/Users/dioteos/www/telegram-bot/acked'
  mkdirSync(dir, { recursive: true })
  writeFileSync(`${dir}/${args.message_id}.json`, JSON.stringify({ ts: new Date().toISOString(), via: 'react' }))
} catch {}
```

### C3 — `server.ts` `reply` tool dedup-skip and ack tee

At top of `case 'reply':` (around line 515), after `const reply_to = ...`:

```ts
// PATCH:hybrid-tee-dedup — if sidecar already fired fallback for this reply_to, skip.
if (reply_to != null) {
  try {
    statSync(`/Users/dioteos/www/telegram-bot/fallback-fired/${reply_to}.json`)
    process.stderr.write(`telegram reply: skipping ${reply_to} — fallback handled it\n`)
    return { content: [{ type: 'text', text: 'skipped (fallback handled)' }] }
  } catch {}
}
```

After the chunks send loop completes, BEFORE the photo/document loop:

```ts
// PATCH:hybrid-tee-ack — write ack marker for sidecar (reply path)
if (reply_to != null && sentIds.length > 0) {
  try {
    const dir = '/Users/dioteos/www/telegram-bot/acked'
    mkdirSync(dir, { recursive: true })
    writeFileSync(`${dir}/${reply_to}.json`, JSON.stringify({ ts: new Date().toISOString(), via: 'reply' }))
  } catch {}
}
```

Hardcoded path `/Users/dioteos/www/telegram-bot/...` because the plugin doesn't load bot env. Single-user bot — acceptable. To relocate the bot, search-and-replace these patches.

Verification:
```
grep -c "PATCH:hybrid-tee-inbox" <path>/server.ts   # → 1
grep -c "PATCH:hybrid-tee-ack"   <path>/server.ts   # → 2
grep -c "PATCH:hybrid-tee-dedup" <path>/server.ts   # → 1
```

`mkdirSync`, `writeFileSync`, `statSync` are already imported in the plugin's existing import block — no new imports needed.
```

- [ ] **Step 3: Update existing "## Current state" section in project_telegram_plugin_patch.md**

Append after the "Loaded into the running plugin via `pm2 restart telegram-klavdiy` at 12:08 EEST 2026-04-26." line:

```markdown
## Family C state (2026-05-12)

Both paths patched with `PATCH:hybrid-tee-inbox` (1×), `PATCH:hybrid-tee-ack` (2×), `PATCH:hybrid-tee-dedup` (1×). Loaded via `pm2 restart telegram-klavdiy` at the end of the safety-net rollout. The daily `tasks/telegram-plugin-update-check.md` task verifies these alongside Families A and B; the startup procedure (CLAUDE.md Step 0.5) has the Family C grep checklist.
```

- [ ] **Step 4: Update auto-memory MEMORY.md index**

The auto-memory MEMORY.md is at `/Users/dioteos/.claude/projects/-Users-dioteos-www-telegram-bot/memory/MEMORY.md`. Add a line:

```markdown
- [project_hybrid_sidecar.md](project_hybrid_sidecar.md) — launchd sidecar fires `claude -p` fallback when REPL hangs on Telegram inbound; trigger=60s no-ack + 90s repl-heartbeat-stale; dedup via `fallback-fired/<id>.json`
```

And also create the file `/Users/dioteos/.claude/projects/-Users-dioteos-www-telegram-bot/memory/project_hybrid_sidecar.md` with content matching what we wrote to the project repo (or just a stub pointing to the canonical version).

Actually simpler: the auto-memory and repo-memory are different stores. The repo `memory/` is the bot's runtime memory (read by Klavdiy on startup). The auto-memory is the harness's memory across sessions. Add an entry to the auto-memory MEMORY.md only — the harness's index — with a one-line summary pointing to the repo location:

```markdown
- [Hybrid safety-net architecture](../../../../www/telegram-bot/memory/project_hybrid_sidecar.md) — sidecar fires fallback when REPL hangs; see also docs/superpowers/specs|plans/2026-05-12-telegram-hybrid-safety-net*
```

(Use a path the harness can resolve. If unsure, just add the bot's path as plain text.)

---

### Task 16: Final commit and admin summary

**Files:** none (operational)

- [ ] **Step 1: Stage all bot-repo changes**

```bash
cd /Users/dioteos/www/telegram-bot
git add -A docs/ scripts/ tasks/ memory/ CLAUDE.md .gitignore inbox/.gitkeep acked/.gitkeep fallback-fired/.gitkeep
git status --short
```

Expected: all the modified + new files staged. Verify nothing unintended (e.g. log files, news files) is in the list. If any extraneous → `git restore --staged <file>`.

- [ ] **Step 2: Commit**

```bash
git commit -m "$(cat <<'EOF'
Hybrid safety-net for Telegram REPL session-hangs

Adds a launchd Bun sidecar (scripts/sidecar.ts) that observes inbound
Telegram messages via plugin tee files (./inbox/, ./acked/) and fires a
headless `claude -p` fallback reply when the REPL fails to react in 60 s
AND ./repl-heartbeat is >90 s stale. Dedup-skip in the plugin's reply
tool prevents duplicate sends when REPL recovers mid-fallback. All three
`claude -p` paths (news-collect, news-digest, fallback) now share
/tmp/klavdiy-claude-headless.lock to eliminate posix_spawnp contention.

Plugin Family C patches (PATCH:hybrid-tee-{inbox,ack,dedup}) live in the
plugin install paths under ~/.claude/plugins/ — diffs documented in
memory/project_telegram_plugin_patch.md so they can be re-applied on
plugin upgrades.

Spec: docs/superpowers/specs/2026-05-12-telegram-hybrid-safety-net-design.md
Plan: docs/superpowers/plans/2026-05-12-telegram-hybrid-safety-net.md
EOF
)"
```

- [ ] **Step 3: Send admin summary via Telegram**

Use the reply tool, threaded to admin's last message in the conversation, with:

```
✅ Гібрид готовий. Що нового:

• Sidecar (Bun під launchd, com.dioteos.klavdiy.sidecar) → polls inbox/ every 5s
• Plugin Family C патчі — tee inbox, ack on react/reply, dedup-skip if fallback вже спрацював
• Fallback wrapper → claude -p під flock з шеред-лок з news pipeline
• Тригер: 60с без ack + repl-heartbeat >90с старе → fire fallback (~15с латентність)
• Dedup: plugin skip-send коли fallback-fired/<id>.json існує — без дублів
• flock /tmp/klavdiy-claude-headless.lock у news-collect / news-digest / fallback — без posix_spawnp колізій

Smoke-tests пройдено: inbox/ack tee працюють, sidecar happy-path не фіре, штучна симуляція hung-REPL — fallback успішно відповів через curl.

Memory + CLAUDE.md оновлено. Сидекар плістом стане авто-стартуватись при логіні. Як завтра побачиш fallback fire — це норма (а не баг), архітектура спрацювала.
```

- [ ] **Step 4: Mark plan complete**

Done. If any task above failed → re-open the relevant task, fix, then re-run from that step.

---

## Self-Review Checklist (run before declaring plan ready)

**Spec coverage:**

- ✅ Family C plugin patches → Tasks 2, 3, 15
- ✅ Sidecar Bun script → Task 5
- ✅ Sidecar wrapper + plist → Tasks 6, 7
- ✅ Fallback wrapper + prompt → Task 9
- ✅ flock serialization → Task 13
- ✅ repl-heartbeat separation → Task 11
- ✅ Cleanup → Task 14
- ✅ CLAUDE.md updates → Task 11 (steps 4, 5)
- ✅ Memory updates → Task 15
- ✅ Smoke tests covering tee, happy path, hung-REPL fallback, dedup → Tasks 4, 8, 10, 12

**Placeholder scan:**

No `TBD`, `TODO`, `add appropriate`, `similar to`. Each task has exact paths and complete code.

**Type consistency:**

- `repl-heartbeat` (filename) used consistently throughout (Tasks 1, 5, 8, 11)
- `fallback-fired/<id>.json` consistent (Tasks 2, 5, 9, 12, 15)
- `PATCH:hybrid-tee-{inbox,ack,dedup}` consistent everywhere
- `/tmp/klavdiy-claude-headless.lock` consistent in Tasks 9, 13, 15
