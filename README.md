# telegram-klavdiy-bot

Always-on Claude Code Telegram bot. PM2 keeps it running, `CLAUDE.md` is the brain.

> **Warning:** This bot runs with `--dangerously-skip-permissions` — Claude Code executes all tool calls without asking for confirmation. Only run on a trusted machine and restrict access via `/telegram:access policy allowlist`.

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
| `start.sh` | Launches Claude via `expect` (allocates a PTY) |
| `ecosystem.config.cjs` | PM2: auto-restart, daily fresh session at 4 AM |

## Setup

### Prerequisites

- macOS / Linux
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`npm i -g @anthropic-ai/claude-code`)
- [PM2](https://pm2.keymetrics.io) (`npm i -g pm2`)
- `expect` (built-in on macOS, `apt install expect` on Linux)

### 1. Clone and configure

```sh
git clone https://github.com/dioteos/telegram-klavdiy-bot.git
cd telegram-klavdiy-bot
```

Create a bot via [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token.

Install the plugin and configure the token:

```sh
claude
# inside Claude:
/plugin install telegram@claude-plugins-official
/reload-plugins
/telegram:configure <TOKEN>
```

### 2. Set your admin chat ID

```sh
cp config.example.json config.json
```

Edit `config.json` — set your Telegram chat ID. To find it, message [@userinfobot](https://t.me/userinfobot).

### 3. Pair the bot

Launch Claude with the channel:

```sh
claude --channels plugin:telegram@claude-plugins-official
```

DM your bot on Telegram — you'll get a pairing code:

```
/telegram:access pair <code>
/telegram:access policy allowlist
```

### 4. Start

```sh
pm2 install pm2-logrotate
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup
```

Done. Message your bot on Telegram.

## Tasks

Drop `.md` files in `tasks/` to schedule recurring jobs:

```yaml
---
schedule: "0 9 * * *"
enabled: true
---

Prompt for Claude to execute on schedule.
```

- `schedule` — 5-field cron (minute hour day month weekday)
- `enabled` — `true` to activate, `false` to skip
- `one_shot` (optional) — `true` to fire once and auto-disable
- Filename = task name
- Body = prompt for Claude

Manage via Telegram: "add a task", "list tasks", "disable daily-news".

## Customization

- **Tasks** → add `.md` files to `tasks/`
- **Rules** → create `.claude/rules/*.md` ([docs](https://code.claude.com/docs/en/memory))
- **Preferences** → edit `CLAUDE.md` or `~/.claude/CLAUDE.md`

## PM2

```sh
pm2 status                    # check status
pm2 logs telegram-klavdiy     # view logs
pm2 restart telegram-klavdiy  # restart
pm2 stop telegram-klavdiy     # stop
```
