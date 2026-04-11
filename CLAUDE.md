# Telegram Bot

Always-on Claude Code bot for Telegram. Powered by PM2 + Claude Channels.

## Startup

Execute this startup procedure in strict order.

### 0. Wait for Telegram plugin

The Telegram plugin loads asynchronously — it may not be ready when Claude starts.
Search for Telegram tools via ToolSearch. If not found, sleep 5 seconds and retry.
Retry up to 12 times (60 seconds total). If still not available after all retries — write the reason to `./restart_note.md` and exit immediately (run `exit 1` via Bash). PM2 will restart the bot automatically. **Never hang waiting for user input — this is an unattended bot.**

### 0.5. Verify Telegram plugin patch — BOTH paths

The plugin's `server.ts` exists in two locations and the REAL running path flips between them across versions. You **must** treat both as authoritative and patch both:

1. Find the real running path:
   ```
   ps -ef | grep "bun run --cwd" | grep telegram | grep -v grep
   ```
   The `--cwd` argument is the ground truth for the MCP subprocess.

2. Read installed version from `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/.claude-plugin/plugin.json` (field `version`).

3. Compare against `./state.json` → `last_plugin_version`. If different (or state.json missing the field) — this is a plugin update. Send a message to admin **before proceeding further**: `⚠️ Telegram плагін оновлено: {prev} → {current}. Переприменюю патч і перевантажую бот.` Continue with patching.

4. Check PATCH markers in BOTH candidate paths:
   ```
   grep -c "PATCH:no-preview" ~/.claude/plugins/cache/claude-plugins-official/telegram/<version>/server.ts
   grep -c "PATCH:no-preview" ~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts
   ```
   Expected: ≥ 2 in each path that exists. A path that doesn't exist yet (e.g. cache/<version>/ before the plugin has been loaded once) can be skipped — it'll appear on next plugin spawn.

5. If ANY existing path has <2 markers — re-apply the patch to THAT path per memory `project_telegram_plugin_patch.md`. Even if the running path is already patched, also patch the non-running path (insurance for when the path flips). Then:
   - Update `./state.json` → `last_plugin_version = <current>`
   - Write `./restart_note.md` ("Patch reapplied to {path(s)} for telegram plugin v{version} no-preview — restart triggered")
   - Run `pm2 restart telegram-klavdiy`
   - Exit — the next startup will load the patched plugin.

6. If both paths OK AND version unchanged — update `./state.json` → `last_plugin_version = <current>` (idempotent) and continue to step 1.

### 1. Config

Read `./config.json` → get `admin_chat_id`.
If missing or unparseable → read `config.example.json` for schema, ask user via Telegram or AskUserQuestion.
If `admin_chat_id` is empty → stop startup, notify user that config.json needs a valid chat ID.

### 2. Memory

Read `./memory/INSTRUCTIONS.md`, then load all `.md` files in `./memory/` (skip `INSTRUCTIONS.md`).
If no memory files exist → follow bootstrap procedure from INSTRUCTIONS.md.

### 3. Tasks

Read `./tasks/INSTRUCTIONS.md`, then all `.md` files in `./tasks/` (skip `INSTRUCTIONS.md` and files starting with `_`).
For each enabled task → register via CronCreate per INSTRUCTIONS.md rules.

### 4. Logs

Read `./logs/INSTRUCTIONS.md`. Create/append to today's log. Clean up old logs per retention rules.

### 5. Summary

Send startup summary to admin via Telegram (`admin_chat_id`) using the template from `./templates/startup-summary.md`.
If that file doesn't exist, copy `./templates/startup-summary.example.md` to `./templates/startup-summary.md` first.
Fill in placeholders with actual values from this session's startup.
If no enabled tasks, confirm bot is online.
If any memory files have `updated` older than 30 days — add a warning line to the summary with the stale file names.

### 6. Restart continuity

Check for `./restart_note.md`. If it exists:
1. Read its content
2. Send a follow-up message to admin via Telegram based on the content
3. Delete the file

If the file doesn't exist — skip this step (normal cold start).

## Heartbeat

A watchdog process monitors this bot's health via `./heartbeat`. You **must** keep it fresh:
- Run `touch ./heartbeat` immediately after completing Step 5 (startup summary)
- Run `touch ./heartbeat` after processing each Telegram message
- Run `touch ./heartbeat` after executing each cron task

If the heartbeat file is older than 10 minutes, the watchdog will restart the bot. This is critical for reliability — never skip heartbeat updates.

## Ongoing

- On cron trigger: execute the task prompt, send results to admin
- CronCreate jobs are session-only, auto-expire after 7 days
- PM2 restarts the bot at 4:00 AM and 4:00 PM daily for a fresh session — tasks re-register automatically on startup
- Save meaningful cross-session insights to `./memory/` per its INSTRUCTIONS.md
- Log significant events to today's log in `./logs/`
- When user asks to manage tasks via Telegram → follow `./tasks/INSTRUCTIONS.md`
- Before `pm2 restart`: write `./restart_note.md` — plain text, max 500 characters, enough context for the next session to understand what happened and notify the admin. The file is consumed and deleted on next startup (step 6).
