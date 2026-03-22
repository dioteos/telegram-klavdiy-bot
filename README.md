# telegram-klavdiy-bot

Always-on Claude Code Telegram bot. PM2 keeps it running, `CLAUDE.md` is the brain.

> **Warning:** Runs with `--dangerously-skip-permissions`. Only run on a trusted machine with `/telegram:access policy allowlist`.

## How it works

```
start.sh → expect (PTY) → claude --channels telegram → CLAUDE.md → registers tasks → listens
```

| File | Role |
|------|------|
| `CLAUDE.md` | Bot brain — 6-step startup, ongoing behavior |
| `tasks/*.md` | Scheduled prompts (cron in YAML frontmatter) |
| `memory/*.md` | Persistent cross-session knowledge |
| `config.json` | Admin chat ID (git-ignored) |
| `ecosystem.config.cjs` | PM2: auto-restart, daily fresh session at 4 AM |

## Setup

**Prerequisites:** macOS/Linux, [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [PM2](https://pm2.keymetrics.io), `expect`

```sh
git clone https://github.com/dioteos/telegram-klavdiy-bot.git
cd telegram-klavdiy-bot

# 1. Install Telegram plugin & set token
claude
# inside Claude:
#   /plugin install telegram@claude-plugins-official
#   /reload-plugins
#   /telegram:configure <TOKEN_FROM_BOTFATHER>

# 2. Config
cp config.example.json config.json
# set your chat ID (get it from @userinfobot on Telegram)

# 3. Pair — DM your bot, then:
#   /telegram:access pair <code>
#   /telegram:access policy allowlist

# 4. Launch
pm2 install pm2-logrotate
pm2 start ecosystem.config.cjs
pm2 save && pm2 startup
```

## Tasks

Drop `.md` files in `tasks/`:

```yaml
---
schedule: "0 9 * * *"
enabled: true
---

Prompt for Claude to execute on schedule.
```

Fields: `schedule` (5-field cron), `enabled` (bool), `one_shot` (optional, fire once).

Manage via Telegram: "add a task", "list tasks", "disable daily-news".

## PM2

```sh
pm2 status                    # check
pm2 logs telegram-klavdiy     # logs
pm2 restart telegram-klavdiy  # restart
pm2 stop telegram-klavdiy     # stop
```
