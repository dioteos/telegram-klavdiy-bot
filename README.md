# telegram-klavdiy-bot

Always-on Claude Code Telegram bot via PM2 + expect.

> **Warning:** This bot runs with `--dangerously-skip-permissions` — Claude Code executes all tool calls without asking for confirmation. Only run on a trusted machine and restrict access via `/telegram:access policy allowlist`.

## How it works

```
start.sh → expect (PTY) → claude --channels telegram → reads CLAUDE.md → registers tasks → listens
```

- `CLAUDE.md` — bot brain: reads `config.json`, registers tasks from `tasks/`, handles Telegram messages
- `tasks/*.md` — scheduled tasks as markdown files with cron in YAML frontmatter
- `config.json` — your admin chat ID (created during setup, git-ignored)
- `start.sh` — launches Claude via `expect` (allocates a PTY, required by Claude Code)
- `ecosystem.config.cjs` — PM2 config with auto-restart and daily fresh session at 4:00 AM

## Setup

### 1. Prerequisites

- macOS / Linux
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`npm i -g @anthropic-ai/claude-code`)
- [Bun](https://bun.sh) (`curl -fsSL https://bun.sh/install | bash`)
- [PM2](https://pm2.keymetrics.io) (`npm i -g pm2`)
- `expect` (built-in on macOS, `apt install expect` on Linux)

### 2. Clone and configure

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

### 3. Set your admin chat ID

```sh
cp config.example.json config.json
```

Edit `config.json` — set your Telegram chat ID. To find it, message [@userinfobot](https://t.me/userinfobot).

### 4. Pair the bot

Launch Claude with the channel:

```sh
claude --channels plugin:telegram@claude-plugins-official
```

DM your bot on Telegram — you'll get a pairing code:

```
/telegram:access pair <code>
/telegram:access policy allowlist
```

### 5. Start

```sh
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup  # auto-start after reboot
```

Done. Message your bot on Telegram.

## Tasks

Drop `.md` files in `tasks/` to schedule recurring jobs. Format:

```md
---
schedule: "0 9 * * *"
enabled: true
---

Your prompt here. Claude executes this on schedule.
```

- `schedule` — 5-field cron (minute hour day month weekday)
- `enabled` — `true` to activate, `false` to skip
- `one_shot` (optional) — `true` to fire once and auto-disable
- Filename = task name
- Body = prompt for Claude

You can also manage tasks by messaging the bot: "add a task", "list tasks", "disable daily-news".

## Customization

- **Your tasks** → add `.md` files to `tasks/`
- **Your rules** → create `.claude/rules/*.md` ([docs](https://code.claude.com/docs/en/memory))
- **Your preferences** → edit `CLAUDE.md` or `~/.claude/CLAUDE.md`

## Management

```sh
pm2 status                    # check status
pm2 logs telegram-klavdiy     # view logs
pm2 restart telegram-klavdiy  # restart
pm2 stop telegram-klavdiy     # stop
```
