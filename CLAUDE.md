# Telegram Bot

Always-on Claude Code bot for Telegram. Powered by PM2 + Claude Channels.

## Startup

Execute this startup procedure in strict order.

**Heartbeat during startup:** Run `touch ./repl-heartbeat` as the very first action (before Step 0), and again after each numbered step completes. Startup takes 3-5 minutes; without periodic touches the sidecar sees a stale heartbeat and fires false fallbacks for any message that arrives mid-startup.

### 0. Wait for Telegram plugin

The Telegram plugin loads asynchronously — it may not be ready when Claude starts.
Search for Telegram tools via ToolSearch. If not found, sleep 5 seconds and retry.
Retry up to 12 times (60 seconds total). If still not available after all retries — write the reason to `./restart_note.md` and exit immediately (run `exit 1` via Bash). PM2 will restart the bot automatically. **Never hang waiting for user input — this is an unattended bot.**

### 0.5. Verify Telegram plugin patch — BOTH paths

The plugin's `server.ts` exists in two locations and the REAL running path flips between them across versions. You **must** treat both as authoritative and patch both:

1. Find the real running path:
   ```
   ps -ef | grep "bun run --cwd" | grep telegram | grep -v grep
   ```
   The `--cwd` argument is the ground truth for the MCP subprocess.

2. Read installed version from `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/.claude-plugin/plugin.json` (field `version`).

3. Compare against `./state.json` → `last_plugin_version`. If different (or state.json missing the field) — this is a plugin update. Send a message to admin **before proceeding further**: `⚠️ Telegram плагін оновлено: {prev} → {current}. Переприменюю патч і перевантажую бот.` Continue with patching.

4. Check PATCH markers in BOTH candidate paths. Two patch families — see `memory/project_telegram_plugin_patch.md` for full diff and rationale.

   **Family A — `PATCH:no-preview`** (always, regardless of version):
   ```
   grep -c "PATCH:no-preview" ~/.claude/plugins/cache/claude-plugins-official/telegram/<version>/server.ts
   grep -c "PATCH:no-preview" ~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts
   ```
   Expected: ≥ 2 in each path that exists.

   **Family B — `PATCH:#1424-*`** (ONLY if `installed.version < 0.0.7` — fixes mid-session disconnect bug; integrated upstream in v0.0.7):
   ```
   grep -c "PATCH:#1424-no-ppid"   <path>/server.ts     # ≥ 1
   grep -c "PATCH:#1424-pid-guard" <path>/server.ts     # ≥ 1
   grep "1>&2"                     <path>/package.json  # must match
   ```
   If installed.version >= 0.0.7 — Family B not needed. Stale markers are harmless.

   **Family C — `PATCH:hybrid-tee-*`** (always; introduced 2026-05-12 for hybrid safety-net sidecar):
   ```
   grep -c "PATCH:hybrid-tee-inbox" <path>/server.ts     # expect 1
   grep -c "PATCH:hybrid-tee-ack"   <path>/server.ts     # expect 2
   grep -c "PATCH:hybrid-tee-dedup" <path>/server.ts     # expect 1
   ```
   Missing any → re-apply per `memory/project_telegram_plugin_patch.md` Family C diffs.

   A path that doesn't exist yet (e.g. cache/<version>/ before the plugin has been loaded once) can be skipped — it'll appear on next plugin spawn.

5. If ANY required marker is missing — re-apply that family's patch to THAT path per `memory/project_telegram_plugin_patch.md`. Patch BOTH paths when both exist (insurance for when the path flips). Then:
   - Update `./state.json` → `last_plugin_version = <current>`
   - Write `./restart_note.md` listing which patches were re-applied to which paths.
   - Run `pm2 restart telegram-klavdiy`
   - Exit — the next startup will load the patched plugin.

   **If harness blocks the cache edit** (it sometimes does for Family B because cache is package-manager-controlled): skip cache, patch marketplaces only, write `restart_note.md` flagging the blocker, notify admin. Marketplaces-only patch is acceptable when running path is marketplaces; if running path is cache, the bug remains until admin authorizes the cache edit.

6. If all required markers OK AND version unchanged — update `./state.json` → `last_plugin_version = <current>` (idempotent) and continue to step 1.

### 0.55. Verify pm2-logrotate

PM2 itself does not rotate logs by default — without rotation `telegram-klavdiy-out.log` grows unbounded (we saw 338 MB / 12 h before installing the module on 2026-05-20). On every startup:

1. `pm2 list 2>/dev/null | grep -E "pm2-logrotate"` — expect one row, status `online`.
2. If missing → install + configure (one-time recovery):
   ```bash
   pm2 install pm2-logrotate
   pm2 set pm2-logrotate:max_size 20M
   pm2 set pm2-logrotate:retain 7
   pm2 set pm2-logrotate:compress true
   pm2 set pm2-logrotate:workerInterval 30
   pm2 save
   ```
3. Sanity-check: `ls -lh ~/.pm2/logs/telegram-klavdiy-out.log` should be <100 MB. If larger — logrotate misconfigured; write `restart_note.md` and DM admin (any hour — disk-eating bug is fresh breakage).

### 0.6. Verify sidecar (safety-net)

The safety-net sidecar runs under launchd (`com.dioteos.klavdiy.sidecar`) and answers inbound Telegram messages when the REPL hangs. On every startup:

1. `launchctl list | grep klavdiy.sidecar` — expect exactly one line, status `0` (running).
2. `pgrep -af "bun.*sidecar.ts"` — expect at least one process.
3. If missing → `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dioteos.klavdiy.sidecar.plist`. Write `restart_note.md` listing the bootstrap, DM admin (unless quiet hours).
4. Touch `./repl-heartbeat` now and after every message/cron — see Heartbeat section. The sidecar fires fallback only when this file is >90 s stale.

See `memory/project_hybrid_sidecar.md` for full architecture, trigger thresholds, and dedup mechanism.

### 1. Config

Read `./config.json` → get:
- `admin_chat_id` — for DM notifications and confirmations (required).
- `channel_chat_id` — public channel for `target_mode: "channel"` publishes.
- `target_chat_id` — where the digest publish task actually sends (DM for testing, channel for prod).
- `target_mode` — `"dm-test"` or `"channel"`. Inform downstream tasks which mode we're in.

If `admin_chat_id` is empty → stop startup, notify user that config.json needs a valid chat ID.
If `target_chat_id` is empty → default to `admin_chat_id` and log a warning.

### 2. Memory

Read `./memory/INSTRUCTIONS.md`, then load all `.md` files in `./memory/` (skip `INSTRUCTIONS.md`).
If no memory files exist → follow bootstrap procedure from INSTRUCTIONS.md.

### 3. Tasks

Read `./tasks/INSTRUCTIONS.md`, then all `.md` files in `./tasks/` (skip `INSTRUCTIONS.md` and files starting with `_`).
For each enabled task → register via CronCreate per INSTRUCTIONS.md rules.

**Sanity check after registration (CRITICAL):** call `CronList` and verify the returned job count matches the number of enabled tasks. If fewer — retry the missing ones once. If still fewer after retry — notify admin with a specific blocker (`⚠️ Registered N of M tasks, missing: {list}`) and continue with whatever registered. Never pretend success if count is wrong.

**Initialize telemetry:** ensure `state.json.last_fire` has a key for every enabled task (null if never fired). This is how later tasks — and the watchdog — detect zombie sessions.

### 3.5. Missed-slot recovery (auto-catchup)

Pm2 restarts at 04:00 / 16:00 can land the bot between cron slots, and occasional session hangs can kill a slot silently. On every startup — auto-run any news-collect slot whose nominal time has already passed today but is missing from `./news/collect-YYYY-MM-DD.json.fills`. **Do not ask the admin** — Anton's explicit rule (2026-04-15): detect and recover without confirmation, then report the outcome.

Nominal times (EEST): `morning = 08:03`, `midday = 13:07`, `afternoon = 17:47`.

For each slot whose time has passed and which is not in `fills`:
1. Run the slot's logic inline (same WebSearch + dedup + append as the cron task).
2. Append `{slot, ts: now, added_per_category, note: "startup-catchup"}` to `fills`.
3. Update `state.json.last_fire["news-collect-<slot>"] = now`.

Also check `news-digest-prenotify` (18:57) and `news-digest-publish` (19:15) — if past time and `state.json.last_fire` for that task is NOT today's date, run the logic inline. Exception: never auto-run publish between 20:00 and 08:00 (to avoid late-night channel spam) — log and skip.

Send admin a short summary after catchup: `🩹 Автодогін: відпрацював {slot(s)} ({reason: missed due to pm2 restart / session hang}). Додано {counts per category}.` No permission prompt — informational only.

### 4. Logs

Read `./logs/INSTRUCTIONS.md`. Create/append to today's log. Clean up old logs per retention rules.

### 5. Summary

Send startup summary to admin via Telegram (`admin_chat_id`) using the template from `./templates/startup-summary.md`.
If that file doesn't exist, copy `./templates/startup-summary.example.md` to `./templates/startup-summary.md` first.
Fill in placeholders with actual values from this session's startup.
If no enabled tasks, confirm bot is online.
Do NOT add a stale-memory warning based on `updated` age alone — see `memory/feedback_memory_not_stale_by_date.md`. Behavioral/config memory stays correct for years; the daytime health-check (10:00) handles memory audits with content judgment.

**Quiet hours (00:00–08:00 local):** skip the routine startup summary. Log it locally and touch `./repl-heartbeat` (NEVER `./heartbeat` — that one is launchd-owned, see the Heartbeat section). DM the admin ONLY for fresh breakage detected this session (patch drift this startup, task count mismatch, restart_note with non-routine content, new pipeline failure). Do NOT DM about chronic conditions that existed at the previous startup — stale-looking memory dates, same disabled tasks, same plugin version still patched. See `memory/feedback_quiet_hours_strict.md` and `memory/feedback_memory_not_stale_by_date.md`. Boring "online, N/N tasks registered" messages wake the admin at 2am for nothing.

### 6. Restart continuity

Check for `./restart_note.md`. If it exists:
1. Read its content
2. Send a follow-up message to admin via Telegram based on the content — **unless it is quiet hours (00:00–08:00 local) AND the note describes a routine event** (plugin patch reapplied, pipeline rebuild, expected restart). Log it to today's session log instead. Only wake the admin at night if the note describes something they'd want to know immediately (patch call-sites changed shape, config missing, repeated failures).
3. Delete the file

If the file doesn't exist — skip this step (normal cold start).

## Heartbeat

Three independent signals, three owners — no single point can both fail and mask the failure:

1. **Machine liveness — `./heartbeat`** — touched every 120 s by launchd agent `com.dioteos.klavdiy.heartbeat` (script: `./scripts/touch-machine-heartbeat.sh`). The REPL must NOT touch this file — keeping it owned by launchd is what lets a long Opus "Pondering" run without triggering a spurious pm2 restart. Watchdog restarts the bot if this file is older than 15 minutes (5-min grace post-restart). Stale here means launchd / the Mac itself is wedged, not just the REPL.

2. **REPL liveness — `./repl-heartbeat`** — touched by the REPL after each cron fire, after each Telegram message reply, and by the every-8-min keepalive task. Headless news scripts must NOT touch it (a news job hanging must not mask a REPL hang). Two consumers, two thresholds:
   - **Sidecar** (soft): >90 s stale + inbound message unacked → fire `claude -p` fallback reply. Session stays alive.
   - **Watchdog** (hard): >10 min stale → `pm2 restart`. Catches REPL hangs the sidecar can't fix.

3. **MCP plugin liveness** — watchdog checks that the bot's claude has a live `bun run --cwd .../telegram/...` child process. If the subprocess dies mid-session (recurring bug — see `memory/project_session_hanging.md`), the REPL can still SEND via curl fallback but cannot RECEIVE `getUpdates` → bot is silently deaf. Watchdog catches this within 2 minutes and restarts.

The split was introduced 2026-05-23: previously the REPL touched `./heartbeat` too, which meant any long Opus thinking → socket-closed → REPL hang → watchdog restart cascade. After decoupling, only true breakage (MCP subprocess dead, Mac wedged, REPL hung >10 min) restarts pm2. Short REPL hangs (<10 min) are caught by the sidecar with fallback replies — no restart needed.

## Ongoing

- On cron trigger: execute the task prompt, send results to admin
- CronCreate jobs are session-only, auto-expire after 7 days
- PM2 restarts the bot at 4:00 AM and 4:00 PM daily for a fresh session — tasks re-register automatically on startup
- **Telemetry on every cron fire:** every task must update `state.json.last_fire[task_name] = <ISO8601 now>` as its FIRST action, before doing real work. This lets us distinguish "cron never fired" from "cron fired but task failed mid-way".
- Save meaningful cross-session insights to `./memory/` per its INSTRUCTIONS.md
- Log significant events to today's log in `./logs/`
- When user asks to manage tasks via Telegram → follow `./tasks/INSTRUCTIONS.md`
- Before `pm2 restart`: write `./restart_note.md` — plain text, max 500 characters, enough context for the next session to understand what happened and notify the admin. The file is consumed and deleted on next startup (step 6).

## News pipeline (KISS, 3 stages — all headless via launchd)

News generation is decoupled into collect / prenotify / publish so a single task hang can never silently miss a digest. Since 2026-04-26 ALL three stages run as short-lived `claude -p` processes spawned by launchd — no REPL cron involvement.

1. **Collect** — 3 launchd jobs at 08:03 / 13:07 / 17:47 EEST. Each invocation reads `./tasks/news-collect-{slot}.md` as the spec, runs WebSearch per category, dedups against prior 3 days + the in-progress collect file, appends new items to `./news/collect-YYYY-MM-DD.json`. No Telegram send. Wrapper: `./scripts/news-collect-headless.sh {slot}`. Plists: `~/Library/LaunchAgents/com.dioteos.klavdiy.news-collect-{slot}.plist`. Logs: `./logs/headless-{slot}-YYYY-MM-DD.log` and `./logs/launchd-news-collect-{slot}.{out,err}`. **Anti-anniversary rule (2026-06-29):** a snippet saying "{N} {month}" without a year does NOT mean the current year — last year's big events (massive strikes, Iran/Hormuz) resurface in search as same-day anniversaries. Collect MUST verify each source's YEAR (URL slug/path date, or unix-timestamp like `175xxxxxxx`→2025) before stamping `event_date=today`, and reject any link whose year ≠ current. Every published link must be a real WebSearch result dated ≤48h. See `news-collect-morning.md` step 4b-bis.
2. **Prenotify** (18:57, launchd) — reads collect file, runs WebSearch catchup if any category <3, sends admin DM via curl (no MCP). Also last rescue: emergency-collect from scratch if collect file missing. Wrapper: `./scripts/news-digest-headless.sh prenotify`. Plist: `com.dioteos.klavdiy.news-digest-prenotify.plist`. Token: sourced from `~/.claude/channels/telegram/.env`. Logs: `./logs/headless-digest-prenotify-YYYY-MM-DD.log`.
3. **Publish** (19:15, launchd) — reads collect file, applies freshness filter (HARD RULE 5/7 today, max 1 today-2 exception) **+ defensive anti-anniversary YEAR-check on each source URL before publish (drop year≠current even if event_date==today)**, formats MarkdownV2 via inline Python, publishes 5 categories + footer to `config.target_chat_id` via curl. Still has final safety-net catchup for any empty category. Saves `./news/YYYY-MM-DD.json` with message_ids, sends admin confirmation. Wrapper: `./scripts/news-digest-headless.sh publish`. Plist: `com.dioteos.klavdiy.news-digest-publish.plist`. Logs: `./logs/headless-digest-publish-YYYY-MM-DD.log`.

All `tasks/news-{collect,digest}-*.md` files have `enabled: false` — the REPL startup skips them. They exist only as the source-of-truth spec that the headless wrappers Read at runtime.

Each stage is idempotent: re-running a collect slot dedups; re-running prenotify adds to fills; re-running publish would overwrite the final file (acceptable when testing).

**Why fully headless:** WebSearch + many CronCreate jobs in REPL hits upstream bugs (#45590 inbound silence past 5 crons, #38866 WebSearch hangs at >90% context, #50920 autoCompact never fires on cron-wake), AND the keepalive-every-8-min flow keeps the REPL non-idle, causing daily cron jobs (prenotify 18:57 / publish 19:15) to miss their 15-min jitter windows. Externalising every news stage to short-lived processes removes that surface — each headless run starts fresh, exits cleanly, can't poison the REPL session. Net REPL cron count drops to 4 (keepalive, health-check, startup-ideas, telegram-plugin-update-check) — none of them daily-deadline-critical for content.

**Curl-only for digest:** prenotify and publish do not have the Telegram MCP plugin (headless `claude -p` doesn't inherit MCP). They send via raw HTTPS to `api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage`. The token is exported by the wrapper from `~/.claude/channels/telegram/.env` before spawning claude -p. Same fallback path the REPL uses when its own MCP plugin disconnects.

Switch between testing and prod by editing `config.json.target_chat_id` (and `target_mode` label). The admin controls this via DM: "prod" → flip to `channel_chat_id`, "dm-test" → flip to `admin_chat_id`.
