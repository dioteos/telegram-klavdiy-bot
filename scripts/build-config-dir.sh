#!/usr/bin/env bash
set -euo pipefail

# Build the bot's isolated CLAUDE_CONFIG_DIR as a symlink mirror of ~/.claude that
# contains EVERYTHING except .credentials.json.
#
# WHY (root cause, 2026-06-23): ~/.claude/.credentials.json holds a refreshable /login
# subscription credential (8h access token + refresh token). Claude Code 2.1.x has a
# regression (gh #68241 / #70124) where this on-disk file OVERRIDES the env var
# CLAUDE_CODE_OAUTH_TOKEN. So even though start.sh exports our static 1-year setup-token,
# the bot was actually authenticating with the 8h cred and getting 401 every ~8h when its
# refresh failed in the daemon context (locked Keychain can't write the rotated token +
# multiple concurrent claude processes racing the single-use refresh token + occasional
# upstream 5xx during refresh, gh #61912). Proven locally: the two 401 events on 2026-06-23
# were 8.13h apart, each ending exactly when credentials.json was refreshed.
#
# With this mirror as CLAUDE_CONFIG_DIR, the bot sees the telegram plugin + channel config
# (symlinked) but NO refreshable cred → it uses the static setup-token (no expiry, no
# refresh, no Keychain). Idempotent — safe to re-run after a Claude Code update adds new
# files under ~/.claude.

SRC="$HOME/.claude"
DST="$HOME/.claude-klavdiy"

mkdir -p "$DST"

# Remove a leaked real credentials.json if one ever got written into the isolated dir
# (would re-introduce the shadowing). The static token never creates one, but be safe.
if [ -e "$DST/.credentials.json" ] && [ ! -L "$DST/.credentials.json" ]; then
  echo "WARNING: real .credentials.json found in $DST — removing (it would re-shadow the static token)"
  rm -f "$DST/.credentials.json"
fi

linked=0
while IFS= read -r entry; do
  # Never mirror the refreshable credential — that is the entire point.
  [ "$entry" = ".credentials.json" ] && continue
  # Skip per-session transcript logs (noise).
  case "$entry" in *.jsonl) continue;; esac
  if [ -L "$DST/$entry" ] || [ -e "$DST/$entry" ]; then rm -rf "$DST/$entry"; fi
  ln -s "$SRC/$entry" "$DST/$entry"
  linked=$((linked + 1))
done < <(ls -1A "$SRC")

echo "config dir mirror ready: $DST ($linked entries linked, .credentials.json excluded)"
if [ -e "$DST/.credentials.json" ]; then
  echo "ERROR: .credentials.json present in $DST — fix before starting the bot" >&2
  exit 1
fi
