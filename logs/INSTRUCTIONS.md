# Logs

Daily session logs for diagnostics and history.

## Format

One file per day: `YYYY-MM-DD.md`

```markdown
# Session Log — YYYY-MM-DD

## HH:MM — Session start
- Memory loaded: N files
- Tasks registered: N
- Reason: startup / pm2 restart / manual

## HH:MM — Event
- Description of what happened
```

## When to log

- Session start (always)
- Task execution results
- Errors or unexpected behavior
- Session-significant events (new memory saved, task created/modified)

## Retention

On startup, delete log files older than 7 days.

## Skip rules

Skip `INSTRUCTIONS.md` (this file) when processing logs.
