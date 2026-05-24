#!/bin/bash
# Touches ./heartbeat from launchd, every ~2 minutes.
#
# Decoupled from the REPL so a long Opus "Pondering" can't make the heartbeat stale
# and trigger a spurious pm2 restart. The REPL still owns ./repl-heartbeat — the
# sidecar uses that to detect REPL hangs and fire claude -p fallbacks.
#
# Watchdog reads ./heartbeat → answers "is the Mac/launchd alive?"
# Sidecar reads ./repl-heartbeat → answers "is the REPL responsive?"
# Watchdog MCP-subprocess check  → answers "is the Telegram plugin alive?"

set -euo pipefail
cd "$(dirname "$0")/.."
touch ./heartbeat
