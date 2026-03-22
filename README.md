# telegram-klavdiy-bot

A personal Telegram bot powered by [Claude Code](https://docs.anthropic.com/en/docs/claude-code). It responds to your messages, runs scheduled tasks (news digests, health checks, plugin updates — anything you describe in plain text), and remembers context across sessions.

There's no application code — `CLAUDE.md` is the entire bot logic. Claude Code reads it on startup and follows the instructions: load config, restore memory, register cron tasks, and start listening. PM2 keeps the process alive and restarts it daily for a fresh session.

> Klavdiy (Клавдій) is the Ukrainian name for Claude.

> **Warning:** This bot runs with `--dangerously-skip-permissions` — Claude Code executes all tool calls without asking for confirmation. Only run on a trusted machine and restrict access via `/telegram:access policy allowlist`.

## How it works

The [Telegram channel plugin](https://github.com/anthropics/claude-code-plugins) connects Claude Code to Telegram. `start.sh` launches Claude Code inside an `expect` PTY wrapper (Claude Code requires a TTY) with a 23-hour safety timeout. On launch, Claude receives a prompt that triggers the 6-step startup procedure defined in `CLAUDE.md`:

1. **Config** — read `config.json` for the admin chat ID
2. **Memory** — load persistent knowledge from `memory/*.md` (preferences, feedback, project context carried across sessions)
3. **Tasks** — register scheduled prompts from `tasks/*.md` via CronCreate
4. **Logs** — create today's session log, clean up logs older than 7 days
5. **Summary** — send a startup report to the admin via Telegram
6. **Restart continuity** — check for a `restart_note.md` left by the previous session and relay it

After startup, the bot listens for Telegram messages and fires cron tasks on schedule.

```
start.sh → expect (PTY, 23h timeout)
  → claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions
    → reads CLAUDE.md → startup procedure → listens for messages + cron
```

> **Note:** Cron jobs are session-only — they live in memory and disappear when Claude exits. PM2 restarts the bot daily at 4:00 AM (`cron_restart` in `ecosystem.config.cjs`), which gives a fresh session and re-registers all tasks automatically.

| File | Role |
|------|------|
| `CLAUDE.md` | Bot brain — startup procedure, ongoing behavior rules |
| `config.json` | Admin chat ID (gitignored, created from example) |
| `tasks/_*.md` | Example tasks (tracked). User tasks are gitignored |
| `memory/*.md` | Persistent cross-session knowledge (gitignored) |
| `templates/` | Message templates (`.example.md` tracked, user copy gitignored) |
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

Install the Telegram channel plugin and configure the token:

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

### 4. Create your tasks

Copy an example and remove the `_` prefix:

```sh
cp tasks/_example-ping.md tasks/ping.md
```

Edit the schedule and prompt to your needs. See [Tasks](#tasks) below for the format. There are four examples included: `_example-ping`, `_example-news-digest`, `_example-plugin-update`, and `_example-health-check`.

### 5. Customize the startup template (optional)

```sh
cp templates/startup-summary.example.md templates/startup-summary.md
```

Edit the template to change language or format. If you skip this step, the bot uses the English example.

### 6. Start

```sh
pm2 install pm2-logrotate
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup
```

Done. Message your bot on Telegram.

## Tasks

Task files live in `tasks/`. Files prefixed with `_` are tracked examples — the bot skips them. Your actual tasks are regular `.md` files (gitignored, never pushed).

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

- **Tasks** → copy `tasks/_example-*.md`, remove `_` prefix, edit
- **Language** → edit your task prompts and `templates/startup-summary.md`
- **Rules** → create `.claude/rules/*.md` ([Claude Code docs](https://docs.anthropic.com/en/docs/claude-code))
- **Preferences** → edit `CLAUDE.md` or `~/.claude/CLAUDE.md`

## PM2

```sh
pm2 status                   # check status
pm2 logs telegram-klavdiy     # view logs
pm2 restart telegram-klavdiy  # restart
pm2 stop telegram-klavdiy     # stop
```
