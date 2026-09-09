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

On startup, delete DATED log files older than 7 days. Only ever match dated
filenames — never a bare `*.md` or `*.log` glob:

```bash
find logs -maxdepth 1 -name '20*.md' -mtime +7 -delete
find logs -maxdepth 1 -name '*-20??-??-??.log' -mtime +7 -delete
```

Never delete (these are long-lived, not dated dailies):

- `INSTRUCTIONS.md` — wiped by a bare `*.md -mtime +7` glob
- `sidecar.log` — append-only incident log. It records ONLY the startup banner
  and `FALLBACK FIRE` lines, so an mtime days old is normal, not staleness. The
  running sidecar holds an open fd on it (`exec bun ... >> sidecar.log` in
  `scripts/sidecar.sh`), so deleting it silently sends every future fallback log
  line to an unlinked inode. If it is ever deleted: `touch` it, then
  `launchctl kickstart -k gui/$(id -u)/com.dioteos.klavdiy.sidecar` to reopen the fd.
- `launchd-*.out` / `launchd-*.err` — same open-fd problem, launchd-owned

## Skip rules

Skip `INSTRUCTIONS.md` (this file) when processing logs.
