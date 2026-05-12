# Telegram Bot — Hybrid Safety-Net Architecture

**Date:** 2026-05-12
**Author:** Klavdiy (Claude) + Anton
**Status:** Approved (Telegram chat, msg 2218)

## Problem

The bot has been chronically unstable: 7-11 PM2 restarts per day instead of the planned 2 (04:00 / 16:00). Today (2026-05-11) the user was unanswered for ~50 minutes because the long-lived Claude Code REPL session hung on an inbound message (known upstream bugs claude-plugins-official#1589, #45590), and the watchdog cooldown delayed restart. News pipeline `claude -p` launchd jobs further destabilise things via `posix_spawnp` exhaustion at slot boundaries.

## Goal

**100 % reachability** for Telegram inbound messages. Every message gets a reply, even when the primary REPL is hung. Latency degrades gracefully (≤2 s when REPL healthy → ≤2 min via fallback when REPL hung), but the bot is never silent.

## Non-goals

- Fixing the upstream REPL session-hang bug. We accept it and route around it.
- Faster-than-current latency on the happy path.
- Migrating the remaining four REPL cron tasks (keepalive, health-check, startup-ideas, plugin-update-check) to launchd. Out of scope; `keepalive` must stay in REPL because it is the REPL liveness signal that the watchdog and sidecar consume.

## Approach — Hybrid

**REPL stays primary** (current behaviour: fast <1 s replies when alive). A **standalone sidecar** under launchd observes every inbound message and fires a **headless `claude -p` fallback reply** when the REPL fails to react within a threshold. Dedup is prevented by writing fired-markers that the plugin's `reply` tool consults before sending.

## Architecture

```
┌──────────────────────────┐
│  Telegram Bot API        │
└──────────┬───────────────┘
           │ getUpdates
           ▼
┌──────────────────────────────────────────┐
│  PM2 telegram-klavdiy (Claude Code REPL) │
│  └─ Telegram MCP plugin (server.ts)      │
│     - tees inbound to ./inbox/<id>.json  │  ← PATCH:hybrid-tee-inbox
│     - on react: ./acked/<id>.json        │  ← PATCH:hybrid-tee-ack
│     - on reply: ./acked/<id>.json AND    │  ← PATCH:hybrid-tee-ack
│       skips send if ./fallback-fired/    │  ← PATCH:hybrid-tee-dedup
└──────────────────────────────────────────┘
           ▲
           │ observes (read-only on plugin files)
           │
┌──────────────────────────────────────────┐
│  launchd com.dioteos.klavdiy.sidecar     │
│  └─ scripts/sidecar.ts (Bun, long-lived) │
│     - polls ./inbox/ every 5 s           │
│     - fires fallback when:               │
│         inbox > 60 s old                 │
│         AND no ack file                  │
│         AND heartbeat > 90 s stale       │
│     - writes ./fallback-fired/<id>.json  │
│     - spawns claude-fallback-reply.sh    │
└────────────────┬─────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────┐
│  scripts/claude-fallback-reply.sh        │
│  - flock /tmp/klavdiy-claude-headless.lock│
│  - claude -p with fallback prompt        │
│  - claude curls Telegram Bot API directly│
└──────────────────────────────────────────┘
```

## Components

### 1. Plugin patches — Family C `hybrid-tee`

Applied to **both** `~/.claude/plugins/cache/claude-plugins-official/telegram/<v>/server.ts` and `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts`. Path is hardcoded to `/Users/dioteos/www/telegram-bot/{inbox,acked,fallback-fired}/` (single-user single-host bot).

**C1 — Inbox tee in `handleInbound`** (after the existing ack-reaction block, before `mcp.notification`):

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

**C2 — Ack tee in `react` tool handler** (after `setMessageReaction` succeeds):

```ts
// PATCH:hybrid-tee-ack — write ack marker for sidecar
try {
  const dir = '/Users/dioteos/www/telegram-bot/acked'
  mkdirSync(dir, { recursive: true })
  writeFileSync(`${dir}/${args.message_id}.json`, JSON.stringify({ ts: new Date().toISOString(), via: 'react' }))
} catch {}
```

**C3 — Ack tee + dedup-skip in `reply` tool handler** (at top of `case 'reply':`, AND after successful send):

At top (before sending anything):
```ts
// PATCH:hybrid-tee-dedup — if sidecar already fired fallback for this reply_to, skip.
if (reply_to != null) {
  const firedFile = `/Users/dioteos/www/telegram-bot/fallback-fired/${reply_to}.json`
  try { if (statSync(firedFile)) {
    process.stderr.write(`telegram reply: skipping ${reply_to} — fallback handled it\n`)
    return { content: [{ type: 'text', text: 'skipped (fallback handled)' }] }
  } } catch {}
}
```

After successful first chunk send:
```ts
// PATCH:hybrid-tee-ack — write ack marker for sidecar (reply path)
if (reply_to != null) {
  try {
    const dir = '/Users/dioteos/www/telegram-bot/acked'
    mkdirSync(dir, { recursive: true })
    writeFileSync(`${dir}/${reply_to}.json`, JSON.stringify({ ts: new Date().toISOString(), via: 'reply' }))
  } catch {}
}
```

### 2. Sidecar — `scripts/sidecar.ts` (Bun)

Long-lived loop. Polls `./inbox/` every 5 s. For each unhandled inbox entry, checks the trigger predicate. Fires fallback when met.

**Trigger predicate (fallback fires):**

```
inbox/<msgId>.json mtime > 60 s ago
AND no acked/<msgId>.json
AND no fallback-fired/<msgId>.json
AND repl-heartbeat mtime > 90 s ago
```

**Why a separate `repl-heartbeat` file (and not the existing `heartbeat`):** The existing `./heartbeat` is touched by both the REPL (keepalive + per-message + per-task) AND the launchd news headless wrappers (`news-collect-headless.sh`, `news-digest-headless.sh`, all four headless prompts). The watchdog uses `./heartbeat` with a 15-min max age — fine for coarse system-liveness. But for the sidecar's 90-s threshold a news job that just touched heartbeat at the end of its run would mask a REPL hang for up to 15 min. So we introduce `./repl-heartbeat` touched **only** by the REPL (keepalive cron + on every inbound message processed + on every cron task fire). Headless scripts and the watchdog do not touch it. CLAUDE.md startup section and `tasks/keepalive.md` get a one-line update to touch both files.

**Fallback action:**

1. Write `fallback-fired/<msgId>.json` atomically (before spawning, to prevent races).
2. Detached spawn of `scripts/claude-fallback-reply.sh <msgId>`.
3. Log to `logs/sidecar.log`.

**Edge case — REPL handled-but-no-tee:** If plugin patch failed and ack file wasn't written but REPL did reply, fallback may double-send. Mitigation: dedup-skip patch (C3) catches this iff REPL is still alive enough to send the reply. If REPL is hung, fallback is correct.

### 3. Fallback wrapper — `scripts/claude-fallback-reply.sh`

Reuses pattern from `news-digest-headless.sh`:
- Loads `TELEGRAM_BOT_TOKEN` from `~/.claude/channels/telegram/.env`.
- Reads `./inbox/<msgId>.json` for chat_id and text.
- Reads `scripts/headless-prompts/fallback-reply.txt`, substitutes placeholders.
- Acquires `flock /tmp/klavdiy-claude-headless.lock` (shared with news headless wrappers — see §5).
- Runs `perl -e 'alarm 120; exec @ARGV' claude -p "$PROMPT" --add-dir "$BOT_DIR" --dangerously-skip-permissions --output-format text`.
- On non-zero exit: send a degraded "I'm hung, try again" notice via curl directly so user still gets something.
- `touch heartbeat` at end.

### 4. Fallback prompt — `scripts/headless-prompts/fallback-reply.txt`

System prompt for the fallback claude:

```
You are Klavdiy, an always-on Telegram bot. The primary REPL session is unresponsive (session-hang bug). You are the headless safety-net invoked by the sidecar to answer this user message so they don't go unanswered.

Hard rules:
- One-shot invocation. No back-and-forth in this process.
- No Telegram MCP plugin available — reply via curl to Telegram Bot API.
- chat_id=__CHAT_ID__  reply_to_message_id=__MESSAGE_ID__
- TELEGRAM_BOT_TOKEN is in env.
- Bot directory: __BOT_DIR__. For context: read CLAUDE.md and select memory/*.md files relevant to the question. Don't read all 30.
- Reply briefly in Ukrainian. First sentence: identify yourself as the fallback ("🛟 Я fallback бо основна сесія залипла…"), then answer.
- Send via curl:
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      --data-urlencode "chat_id=__CHAT_ID__" \
      --data-urlencode "text=<your reply>" \
      --data-urlencode "reply_to_message_id=__MESSAGE_ID__"

INBOUND_MESSAGE_TEXT:
__TEXT__
```

### 5. Shared claude -p serialization — flock

The news headless wrappers (`news-collect-headless.sh`, `news-digest-headless.sh`) currently spawn `claude -p` without serialization. Combined with the sidecar fallback, concurrent `claude -p` invocations can hit macOS `posix_spawnp` limits, the exact failure mode we're trying to eliminate.

Add `exec 9>/tmp/klavdiy-claude-headless.lock; flock 9` to all three wrappers (`news-collect-headless.sh`, `news-digest-headless.sh`, `claude-fallback-reply.sh`) so they serialize. Worst-case fallback waits 1-2 min for a running news slot; acceptable.

### 6. launchd plist — `com.dioteos.klavdiy.sidecar.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.dioteos.klavdiy.sidecar</string>
  <key>ProgramArguments</key><array>
    <string>/Users/dioteos/www/telegram-bot/scripts/sidecar.sh</string>
  </array>
  <key>WorkingDirectory</key><string>/Users/dioteos/www/telegram-bot</string>
  <key>StandardOutPath</key><string>/Users/dioteos/www/telegram-bot/logs/launchd-sidecar.out</string>
  <key>StandardErrorPath</key><string>/Users/dioteos/www/telegram-bot/logs/launchd-sidecar.err</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>/Users/dioteos</string>
  </dict>
</dict></plist>
```

`scripts/sidecar.sh` wraps `bun scripts/sidecar.ts`, sets up PATH, redirects to `logs/sidecar.log`. Same pattern as `news-*-headless.sh`.

### 7. Directory layout (new files)

```
/Users/dioteos/www/telegram-bot/
├── inbox/<message_id>.json              # written by plugin tee (gitignored)
├── acked/<message_id>.json              # written by plugin tee (gitignored)
├── fallback-fired/<message_id>.json     # written by sidecar (gitignored)
├── scripts/
│   ├── sidecar.sh                       # launchd wrapper
│   ├── sidecar.ts                       # Bun loop
│   ├── claude-fallback-reply.sh         # one-shot fallback wrapper
│   └── headless-prompts/
│       └── fallback-reply.txt           # claude -p prompt template
├── logs/
│   ├── sidecar.log                      # daily, kept 7d (cleaned with other logs)
│   ├── fallback-<msgId>-<date>.log
│   ├── launchd-sidecar.out
│   └── launchd-sidecar.err
└── docs/superpowers/specs/
    └── 2026-05-12-telegram-hybrid-safety-net-design.md   # this file
```

### 8. Cleanup

A daily prune (added to `health-check.md` or as its own short cron): delete `inbox/`, `acked/`, `fallback-fired/` files older than 7 days. Same retention as logs.

### 9. CLAUDE.md updates

Add to startup procedure:

- **Step 0.6 — Verify sidecar** — `launchctl list | grep klavdiy.sidecar` returns one entry; if not, `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dioteos.klavdiy.sidecar.plist`. Notify admin if had to bootstrap.
- **Step 0.5 — Patch verification** — add Family C markers (`PATCH:hybrid-tee-inbox`, `PATCH:hybrid-tee-ack`, `PATCH:hybrid-tee-dedup`) to the grep checklist alongside Family A and B.
- **Heartbeat clause** — Step 5 and the Heartbeat section both currently say `touch ./heartbeat`. Update to `touch ./heartbeat ./repl-heartbeat` everywhere the REPL touches heartbeat: Step 5 post-summary, after each Telegram message processed, after each cron task. The keepalive task body gets the same update.

### 10. Memory updates

- Append Family C to `memory/project_telegram_plugin_patch.md` with full diffs.
- New file `memory/project_hybrid_sidecar.md` documenting the safety-net architecture, trigger thresholds, dedup mechanism, what to check when investigating a "fallback fired" incident.

## Trade-offs and accepted risks

| Concern | Accepted? | Notes |
|---|---|---|
| Plugin upgrade may break Family C patches | Yes | We already maintain Family A & B through upgrades. `tasks/telegram-plugin-update-check.md` (21:00) detects and re-applies. |
| Hardcoded `/Users/dioteos/www/telegram-bot` path in plugin patch | Yes | Single-user bot; if we ever move, search-and-replace. |
| Sidecar polls every 5 s (CPU/IO) | Yes | One `readdir` of a directory with <50 files. Negligible. |
| Fallback adds 1-2 API calls per hang event | Yes | Anton's explicit preference (chat msg 2214 option B). |
| Heartbeat-fresh-but-REPL-busy → user waits 5 min for response when sending message during a long REPL task | Yes | This is the cost of preventing duplicates. Better than duplicates. If becomes a real problem, raise the heartbeat threshold or add a per-message "I'm busy" notice. |
| Plugin reply-tool dedup-skip patch may fail closed (REPL silenced when it shouldn't be) | Mitigated | Skip only happens if `fallback-fired/<reply_to>.json` exists. We only write that file when the sidecar actually fired. Plugin always logs the skip to stderr. |

## Test plan

Each component gets a manual smoke test before declaring success.

1. **Plugin tee patches** — send a Telegram message, verify `inbox/<msgId>.json` appears within 1 s. React via REPL, verify `acked/<msgId>.json` appears.
2. **Sidecar happy path** — sidecar should NOT fire when REPL responds normally. Send a message, check `fallback-fired/` stays empty.
3. **Sidecar hung-REPL** — `pm2 stop telegram-klavdiy`, send a Telegram message, wait 2 min. Expect: fallback fires, claude -p sends a reply tagged "🛟 fallback".
4. **Dedup** — start REPL hung (heartbeat stale), send message, let fallback fire, then restart REPL. REPL eventually picks up the inbound from MCP queue and tries to reply. Plugin patch must skip-send. Verify only one reply in chat.
5. **flock serialization** — kick off a news collect manually while triggering a fallback. Verify both run sequentially, neither errors with `posix_spawnp`.
6. **Sidecar crash recovery** — `kill` the sidecar process. launchd KeepAlive should respawn within 10 s (ThrottleInterval).

## Implementation order

1. Spec doc (this file) → commit.
2. Implementation plan via superpowers:writing-plans skill.
3. Plugin Family C patches in both paths (cache + marketplaces), `pm2 restart telegram-klavdiy`.
4. Smoke test #1 — verify tees appear.
5. Sidecar: `sidecar.ts`, `sidecar.sh`, plist. `launchctl bootstrap`.
6. Smoke test #2 — happy path no fallback.
7. Fallback wrapper + prompt.
8. Smoke test #3 — hung REPL fallback.
9. flock serialization in three wrappers.
10. Dedup smoke test #4.
11. Memory + CLAUDE.md updates.
12. Commit everything, send admin summary.

## Open questions (none blocking)

None — design is complete. Below are deliberate non-decisions:

- *Should we also migrate health-check / startup-ideas / plugin-update-check to launchd?* — Out of scope. They are once-a-day, low impact. Defer.
- *Should the fallback reply be smarter (RAG over memory, persistent conversation across fallback events)?* — No. Fallback is exceptional. Keep it dumb and reliable.
