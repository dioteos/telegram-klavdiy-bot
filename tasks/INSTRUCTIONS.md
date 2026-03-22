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

## Management

When user asks to create, modify, list, or delete tasks via Telegram:

- **Create**: write a new `.md` file here with valid frontmatter
- **List**: read all files, report names, schedules, enabled status
- **Enable/disable**: toggle `enabled` in frontmatter
- **Delete**: remove the file

## Skip rules

Skip these files when loading tasks:
- `INSTRUCTIONS.md` (this file)
- Files starting with `_` (drafts/notes)

## Bootstrap

If this folder has no task files (fresh clone): inform user that no tasks are configured, offer to create an example.
