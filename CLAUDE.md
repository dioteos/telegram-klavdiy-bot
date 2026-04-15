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

Read `./config.json` → get:
- `admin_chat_id` — for DM notifications and confirmations (required).
- `channel_chat_id` — public channel for `target_mode: "channel"` publishes.
- `target_chat_id` — where the digest publish task actually sends (DM for testing, channel for prod).
- `target_mode` — `"dm-test"` or `"channel"`. Inform downstream tasks which mode we're in.

If `admin_chat_id` is empty → stop startup, notify user that config.json needs a valid chat ID.
If `target_chat_id` is empty → default to `admin_chat_id` and log a warning.

### 2. Memory

Read `./memory/INSTRUCTIONS.md`, then load all `.md` files in `./memory/` (skip `INSTRUCTIONS.md`).
If no memory files exist → follow bootstrap procedure from INSTRUCTIONS.md.

### 3. Tasks

Read `./tasks/INSTRUCTIONS.md`, then all `.md` files in `./tasks/` (skip `INSTRUCTIONS.md` and files starting with `_`).
For each enabled task → register via CronCreate per INSTRUCTIONS.md rules.

**Sanity check after registration (CRITICAL):** call `CronList` and verify the returned job count matches the number of enabled tasks. If fewer — retry the missing ones once. If still fewer after retry — notify admin with a specific blocker (`⚠️ Registered N of M tasks, missing: {list}`) and continue with whatever registered. Never pretend success if count is wrong.

**Initialize telemetry:** ensure `state.json.last_fire` has a key for every enabled task (null if never fired). This is how later tasks — and the watchdog — detect zombie sessions.

### 3.5. Missed-slot recovery (auto-catchup)

Pm2 restarts at 04:00 / 16:00 can land the bot between cron slots, and occasional session hangs can kill a slot silently. On every startup — auto-run any news-collect slot whose nominal time has already passed today but is missing from `./news/collect-YYYY-MM-DD.json.fills`. **Do not ask the admin** — Anton's explicit rule (2026-04-15): detect and recover without confirmation, then report the outcome.

Nominal times (EEST): `morning = 08:03`, `midday = 13:07`, `afternoon = 17:47`.

For each slot whose time has passed and which is not in `fills`:
1. Run the slot's logic inline (same WebSearch + dedup + append as the cron task).
2. Append `{slot, ts: now, added_per_category, note: "startup-catchup"}` to `fills`.
3. Update `state.json.last_fire["news-collect-<slot>"] = now`.

Also check `news-digest-prenotify` (18:57) and `news-digest-publish` (19:57) — if past time and `state.json.last_fire` for that task is NOT today's date, run the logic inline. Exception: never auto-run publish between 20:00 and 08:00 (to avoid late-night channel spam) — log and skip.

Send admin a short summary after catchup: `🩹 Автодогін: відпрацював {slot(s)} ({reason: missed due to pm2 restart / session hang}). Додано {counts per category}.` No permission prompt — informational only.

### 4. Logs

Read `./logs/INSTRUCTIONS.md`. Create/append to today's log. Clean up old logs per retention rules.

### 5. Summary

Send startup summary to admin via Telegram (`admin_chat_id`) using the template from `./templates/startup-summary.md`.
If that file doesn't exist, copy `./templates/startup-summary.example.md` to `./templates/startup-summary.md` first.
Fill in placeholders with actual values from this session's startup.
If no enabled tasks, confirm bot is online.
If any memory files have `updated` older than 30 days — add a warning line to the summary with the stale file names.

**Quiet hours (23:00–08:00 local):** skip the routine startup summary. Log it locally and touch heartbeat, but do not message the admin unless something is broken (patch drift, task count mismatch, stale memory, or any blocker that would be included in the summary). Boring "online, 9/9 tasks registered" messages wake the admin at 2am for nothing.

### 6. Restart continuity

Check for `./restart_note.md`. If it exists:
1. Read its content
2. Send a follow-up message to admin via Telegram based on the content — **unless it is quiet hours (23:00–08:00 local) AND the note describes a routine event** (plugin patch reapplied, pipeline rebuild, expected restart). Log it to today's session log instead. Only wake the admin at night if the note describes something they'd want to know immediately (patch call-sites changed shape, config missing, repeated failures).
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
- **Telemetry on every cron fire:** every task must update `state.json.last_fire[task_name] = <ISO8601 now>` as its FIRST action, before doing real work. This lets us distinguish "cron never fired" from "cron fired but task failed mid-way".
- Save meaningful cross-session insights to `./memory/` per its INSTRUCTIONS.md
- Log significant events to today's log in `./logs/`
- When user asks to manage tasks via Telegram → follow `./tasks/INSTRUCTIONS.md`
- Before `pm2 restart`: write `./restart_note.md` — plain text, max 500 characters, enough context for the next session to understand what happened and notify the admin. The file is consumed and deleted on next startup (step 6).

## News pipeline (KISS, 3 stages)

News generation is decoupled into collect / prenotify / publish so a single task hang can never silently miss a digest.

1. **Collect** — 3 tasks during the day (`news-collect-morning`, `-midday`, `-afternoon`). Each runs WebSearch per category, dedups against prior 3 days + the in-progress collect file, appends new items to `./news/collect-YYYY-MM-DD.json`. No Telegram send.
2. **Prenotify** (18:57, `news-digest-prenotify`) — reads the collect file. If any category has <3 items, runs inline catchup. Sends admin DM a preview with counts and warnings. This is also the last rescue if all three collect tasks failed (emergency-collect from scratch).
3. **Publish** (19:57, `news-digest-publish`) — reads the collect file, formats MarkdownV2, publishes to `config.target_chat_id`. Still has a final safety-net catchup for any empty category. Saves final `./news/YYYY-MM-DD.json` with message_ids, sends admin confirmation.

Each stage is idempotent: re-running a collect slot dedups; re-running prenotify adds to the file; re-running publish would overwrite the final file (acceptable when testing).

Switch between testing and prod by editing `config.json.target_chat_id` (and `target_mode` label). The admin controls this via DM: "prod" → flip to `channel_chat_id`, "dm-test" → flip to `admin_chat_id`.
