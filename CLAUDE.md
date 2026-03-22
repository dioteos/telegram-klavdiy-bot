# Telegram Bot

Always-on Claude Code bot for Telegram. Powered by PM2 + Claude Channels.

## Startup

When Telegram plugin tools are available, execute this startup procedure in strict order:

### 1. Config

Read `./config.json` → get `admin_chat_id`.
If missing → read `config.example.json` for schema, ask user via Telegram or AskUserQuestion.
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
Fill in placeholders with actual values from this session's startup.
If no enabled tasks, confirm bot is online.

### 6. Restart continuity

Check for `./restart_note.md`. If it exists:
1. Read its content
2. Send a follow-up message to admin via Telegram based on the content
3. Delete the file

If the file doesn't exist — skip this step (normal cold start).

## Ongoing

- On cron trigger: execute the task prompt, send results to admin
- CronCreate jobs are session-only, auto-expire after 7 days
- PM2 restarts the bot daily at 4:00 AM for a fresh session — tasks re-register automatically on startup
- Save meaningful cross-session insights to `./memory/` per its INSTRUCTIONS.md
- Log significant events to today's log in `./logs/`
- When user asks to manage tasks via Telegram → follow `./tasks/INSTRUCTIONS.md`
- Before `pm2 restart`: write `./restart_note.md` with a short message for the next session to send (context of what happened, what to tell the user). The file is consumed and deleted on next startup (step 6).
