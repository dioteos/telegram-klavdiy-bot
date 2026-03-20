#!/usr/bin/env bash
export PATH="/Users/dioteos/.local/bin:/Users/dioteos/.bun/bin:/Users/dioteos/.nvm/versions/node/v22.22.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/Users/dioteos"
export TERM="xterm-256color"
cd /Users/dioteos

# expect allocates its own PTY — no tmux/screen needed
exec expect -c '
set timeout -1
spawn claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions
expect eof
'
