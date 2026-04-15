# Tasks

Scheduled prompts that Claude executes via CronCreate.

## Format

Files in this folder with `.md` extension and YAML frontmatter:

```
---
schedule: "0 9 * * *"
enabled: true
---

Prompt for Claude to execute on schedule.
```

### Fields

- `schedule` (required): 5-field cron expression — minute hour day-of-month month day-of-week
- `enabled` (required): boolean `true` or `false` (not string `"true"`)
- `one_shot` (optional): `true` = fire once, then auto-disable

Filename = task name. Body below frontmatter = prompt.

## Registration

On startup, for each file with `enabled: true`:
1. Validate `schedule` is a valid 5-field cron expression. If invalid → skip, report in summary.
2. Prepend routing: `"Send results to telegram chat_id {admin_chat_id}: {body}"`
3. Register via CronCreate. If `one_shot: true` → pass `recurring: false`.
4. If CronCreate fails → log error, continue with remaining tasks.
5. If task execution fails at runtime → send a short error message to admin (task name + what went wrong). Never fail silently.

After all tasks registered, call `CronList` and compare count to the number of enabled tasks. If short — retry missing ones once. If still short — notify admin explicitly. This catches CronCreate deduplication or silent drops.

## Telemetry on every fire

Every task's first action (before the real work) is:
1. `touch ./heartbeat`
2. Update `./state.json.last_fire["{task_name}"] = "<ISO8601 now with timezone>"` (use `date -Iseconds` or equivalent).

This gives us a timestamp per task. Without it we can't tell "cron never fired" from "task crashed mid-way".

The task name key matches the filename without `.md` extension (`news-collect-morning`, `daily-health-check`, etc).

## Management

When user asks to create, modify, list, or delete tasks via Telegram:

- **Create**: write a new `.md` file here with valid frontmatter
- **List**: read all files, report names, schedules, enabled status
- **Enable/disable**: toggle `enabled` in frontmatter
- **Delete**: remove the file

## File conventions

- `_*.md` — tracked example templates. The bot skips these (never registered). Users copy them and remove the `_` prefix to create their own tasks.
- Regular `.md` files — user tasks. Gitignored so personal schedules and prompts are never pushed.
- `INSTRUCTIONS.md` — this file. Always skipped by the bot.

## Skip rules

Skip these files when loading tasks:
- `INSTRUCTIONS.md` (this file)
- Files starting with `_` (example templates)

## Bootstrap

If this folder has no loadable task files (fresh clone): inform user that no tasks are configured, suggest copying an example: `cp tasks/_example-ping.md tasks/ping.md`.
