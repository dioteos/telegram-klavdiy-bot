# telegram-klavdiy-bot

Claude Code as an always-on Telegram bot via PM2 + expect.

## Prerequisites

- macOS / Linux
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`npm i -g @anthropic-ai/claude-code`)
- [Bun](https://bun.sh) (`curl -fsSL https://bun.sh/install | bash`)
- [PM2](https://pm2.keymetrics.io) (`npm i -g pm2`)
- `expect` (built-in on macOS, `apt install expect` on Linux)

## Setup

### 1. Create a bot

Open [@BotFather](https://t.me/BotFather) → `/newbot` → set a name and username (must end with `bot`). Copy the token.

### 2. Install the plugin

Start `claude` and run:

```
/plugin install telegram@claude-plugins-official
/reload-plugins
/telegram:configure <TOKEN>
```

Token is saved to `~/.claude/channels/telegram/.env`.

### 3. Pair the bot

Launch Claude with the channel:

```sh
claude --channels plugin:telegram@claude-plugins-official
```

DM your bot on Telegram — you'll get a pairing code. In the Claude session:

```
/telegram:access pair <code>
/telegram:access policy allowlist
```

### 4. Deploy as a service

Clone the repo and start with PM2 — no path editing needed, everything resolves automatically.

```sh
git clone https://github.com/dioteos/telegram-klavdiy-bot.git
cd telegram-klavdiy-bot
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup  # auto-start after reboot
```

## How it works

- `start.sh` — runs `claude` via `expect`, which allocates a PTY (Claude Code requires a TTY). Resolves `$HOME` and `$PATH` dynamically — no hardcoded paths.
- `ecosystem.config.cjs` — PM2 config with auto-restart (max 10 restarts, 30s delay). Uses `os.homedir()` and `__dirname` for portability.

## Management

```sh
pm2 status                    # check status
pm2 logs telegram-klavdiy     # view logs
pm2 restart telegram-klavdiy
pm2 stop telegram-klavdiy
```
