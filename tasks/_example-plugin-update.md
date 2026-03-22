---
schedule: "0 19 * * *"
enabled: true
---

Check for updates to the Telegram plugin for Claude Code (telegram@claude-plugins-official).

Steps:
1. Find the installed version: `ls ~/.claude/plugins/cache/claude-plugins-official/telegram/`
2. Find the latest version: `npm view claude-channel-telegram version`
3. Compare installed vs latest

If a new version exists — send a message with both version numbers and the update command.

If versions match — do nothing, finish silently.
