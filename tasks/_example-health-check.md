---
schedule: "0 10 * * *"
enabled: true
---

Run a daily health check of the bot and its environment. Collect:

1. PM2 process status: `pm2 jlist` — find the bot process, report status, uptime, restarts, memory usage
2. Disk usage: `du -sh` for the bot directory
3. Memory files: count `.md` files in `./memory/`, flag any with `updated` older than 30 days
4. Task files: count loadable tasks in `./tasks/` (skip `_*` and `INSTRUCTIONS.md`), report how many are enabled vs disabled
5. Logs: count log files in `./logs/`, check if any are older than 7 days (should have been cleaned)

Send a compact health report to admin. If everything is normal — one short message. If any issues found — highlight them clearly.
