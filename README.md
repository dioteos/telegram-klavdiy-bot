# telegram-klavdiy-bot

Claude Code як Telegram-бот через PM2 + expect. Працює як always-on сервіс.

## Передумови

- macOS / Linux
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`npm i -g @anthropic-ai/claude-code`)
- [Bun](https://bun.sh) (`curl -fsSL https://bun.sh/install | bash`)
- [PM2](https://pm2.keymetrics.io) (`npm i -g pm2`)
- `expect` (macOS — вже є, Linux — `apt install expect`)

## Налаштування

### 1. Створи бота

Відкрий [@BotFather](https://t.me/BotFather) → `/newbot` → задай ім'я та username (має закінчуватись на `bot`). Скопіюй токен.

### 2. Встанови плагін

Запусти `claude` і виконай:

```
/plugin install telegram@claude-plugins-official
/reload-plugins
/telegram:configure <TOKEN>
```

Токен зберігається в `~/.claude/channels/telegram/.env`.

### 3. Спарюй бота

Запусти Claude з каналом:

```sh
claude --channels plugin:telegram@claude-plugins-official
```

Напиши боту в Telegram — отримаєш код. В сесії Claude:

```
/telegram:access pair <код>
/telegram:access policy allowlist
```

### 4. Розгорни як сервіс

Клонуй репо та відредагуй шляхи в `start.sh` і `ecosystem.config.cjs` під свою систему.

```sh
git clone https://github.com/dioteos/telegram-klavdiy-bot.git
cd telegram-klavdiy-bot

# Відредагуй шляхи
vim start.sh
vim ecosystem.config.cjs

# Запусти
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup  # автостарт після ребуту
```

## Як це працює

- `start.sh` — запускає `claude` через `expect`, який алокує PTY (Claude Code потребує TTY)
- `ecosystem.config.cjs` — PM2 конфіг з автоперезапуском (макс 10 рестартів, затримка 30с)
- PM2 тримає процес живим, `expect` забезпечує TTY-емуляцію

## Управління

```sh
pm2 status              # статус
pm2 logs telegram-klavdiy  # логи
pm2 restart telegram-klavdiy
pm2 stop telegram-klavdiy
```
