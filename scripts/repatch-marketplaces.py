#!/usr/bin/env python3
"""Re-apply Families A/B/C to the marketplaces telegram plugin copy.

Anchored on code shapes, not line numbers (marketplaces can lead cache).
Every patch is idempotent: if its marker is already present, it is skipped.
Refuses to write anything unless every required anchor matched exactly once.
"""
import sys, os, json

MKT = os.path.expanduser(
    "~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram")
SRV = os.path.join(MKT, "server.ts")
PKG = os.path.join(MKT, "package.json")
BOT = "/Users/dioteos/www/telegram-bot"

src = open(SRV).read()
orig = src
applied, skipped, failed = [], [], []

# Family B (#1424 mid-session-disconnect backport) was integrated upstream in
# v0.0.7 — its anchor code no longer exists there. Applying it unconditionally
# makes the whole all-or-nothing run abort with exit 2, which would also block
# the still-required A and C families. Gate it on the installed version.
INSTALLED = json.load(
    open(os.path.join(MKT, ".claude-plugin", "plugin.json")))["version"]
VER = tuple(int(x) for x in INSTALLED.split(".")[:3])
NEED_B = VER < (0, 0, 7)


def patch(name, marker, old, new):
    """Replace `old` with `new` exactly once, unless `marker` already present."""
    global src
    if marker in src:
        skipped.append(name)
        return
    n = src.count(old)
    if n != 1:
        failed.append(f"{name}: anchor matched {n}x (need exactly 1)")
        return
    src = src.replace(old, new, 1)
    applied.append(name)


# ---------- Family A1 — reply sendMessage ----------
patch("A1 no-preview/sendMessage", "link_preview_options: { is_disabled: true }, // PATCH:no-preview",
"""              ...(parseMode ? { parse_mode: parseMode } : {}),
            })""",
"""              ...(parseMode ? { parse_mode: parseMode } : {}),
              link_preview_options: { is_disabled: true }, // PATCH:no-preview
            })""")

# ---------- Family A2 — editMessageText ----------
patch("A2 no-preview/editMessageText", "editParseMode ? { parse_mode: editParseMode } : {}",
"""          args.text as string,
          ...(editParseMode ? [{ parse_mode: editParseMode }] : []),
        )""",
"""          args.text as string,
          {
            ...(editParseMode ? { parse_mode: editParseMode } : {}),
            link_preview_options: { is_disabled: true }, // PATCH:no-preview
          },
        )""")

# ---------- Family B — only for installed < 0.0.7 (fixed upstream in 0.0.7) ----------
if not NEED_B:
    skipped.append(f"B1/B2/B2b/B3 (#1424 not needed — v{INSTALLED} >= 0.0.7)")

# ---------- Family B1 — orphan watchdog, drop ppid check ----------
if NEED_B:
    patch("B1 #1424-no-ppid", "PATCH:#1424-no-ppid",
"""// Orphan watchdog: stdin events above don't reliably fire when the parent
// chain (`bun run` wrapper → shell → us) is severed by a crash. Poll for
// reparenting (POSIX) or a dead stdin pipe and self-terminate.
const bootPpid = process.ppid
setInterval(() => {
  const orphaned =
    (process.platform !== 'win32' && process.ppid !== bootPpid) ||
    process.stdin.destroyed ||
    process.stdin.readableEnded
  if (orphaned) shutdown()
}, 5000).unref()""",
"""// Orphan watchdog: belt-and-suspenders for the stdin 'end'/'close' handlers above.
// PATCH:#1424-no-ppid — dropped `process.ppid !== bootPpid` check; it false-fires
// when bun-run/shell wrapper exits during normal startup and we get reparented to
// init. Per anthropics/claude-plugins-official#1424 / fixes #1467.
setInterval(() => {
  if (process.stdin.destroyed || process.stdin.readableEnded) shutdown()
}, 5000).unref()""")

# ---------- Family B2 — PID-recycling guard ----------
if NEED_B:
    patch("B2 #1424-pid-guard", "PATCH:#1424-pid-guard",
"""    process.kill(stale, 0)
    process.stderr.write(`telegram channel: replacing stale poller pid=${stale}\\n`)
    process.kill(stale, 'SIGTERM')
  }""",
"""    process.kill(stale, 0)
    // PATCH:#1424-pid-guard — verify PID holder is a server.ts before SIGTERM (PID-recycling guard per claude-plugins-official#1424)
    const cmd = execFileSync('ps', ['-p', String(stale), '-o', 'args='], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
    if (cmd.includes('server.ts')) {
      process.stderr.write(`telegram channel: replacing stale poller pid=${stale}\\n`)
      process.kill(stale, 'SIGTERM')
    }
  }""")

# ---------- B2b — execFileSync import (required by B2) ----------
if NEED_B:
    patch("B2b execFileSync import", "import { execFileSync }",
"""import { homedir } from 'os'
import { join, extname, sep } from 'path'""",
"""import { homedir } from 'os'
import { execFileSync } from 'child_process'
import { join, extname, sep } from 'path'""")

# ---------- Family C1 — inbox tee ----------
patch("C1 hybrid-tee-inbox", "PATCH:hybrid-tee-inbox",
"""  const imagePath = downloadImage ? await downloadImage() : undefined
""",
"""  const imagePath = downloadImage ? await downloadImage() : undefined

  // PATCH:hybrid-tee-inbox — write inbox marker for sidecar safety-net.
  if (msgId != null) {
    try {
      const dir = '%s/inbox'
      mkdirSync(dir, { recursive: true })
      writeFileSync(`${dir}/${msgId}.json`, JSON.stringify({
        chat_id, message_id: String(msgId),
        user: from.username ?? String(from.id),
        user_id: String(from.id),
        text, ts: new Date().toISOString(),
      }))
    } catch (e) {
      process.stderr.write(`telegram tee inbox failed: ${e}\\n`)
    }
  }
""" % BOT)

# ---------- Family C2 — react ack tee ----------
patch("C2 hybrid-tee-ack/react", "via: 'react'",
"""        ])
        return { content: [{ type: 'text', text: 'reacted' }] }""",
"""        ])
        // PATCH:hybrid-tee-ack — write ack marker for sidecar (react path)
        try {
          const dir = '%s/acked'
          mkdirSync(dir, { recursive: true })
          writeFileSync(`${dir}/${args.message_id}.json`, JSON.stringify({ ts: new Date().toISOString(), via: 'react' }))
        } catch {}
        return { content: [{ type: 'text', text: 'reacted' }] }""" % BOT)

# ---------- Family C3a — reply dedup-skip ----------
patch("C3a hybrid-tee-dedup", "PATCH:hybrid-tee-dedup",
"""        const reply_to = args.reply_to != null ? Number(args.reply_to) : undefined
        const files = (args.files as string[] | undefined) ?? []""",
"""        const reply_to = args.reply_to != null ? Number(args.reply_to) : undefined
        // PATCH:hybrid-tee-dedup — if sidecar already fired fallback for this reply_to, skip.
        if (reply_to != null) {
          try {
            statSync(`%s/fallback-fired/${reply_to}.json`)
            process.stderr.write(`telegram reply: skipping ${reply_to} — fallback handled it\\n`)
            return { content: [{ type: 'text', text: 'skipped (fallback handled)' }] }
          } catch {}
        }
        const files = (args.files as string[] | undefined) ?? []""" % BOT)

# ---------- Family C3b — reply ack tee ----------
patch("C3b hybrid-tee-ack/reply", "via: 'reply'",
"""        // Files go as separate messages (Telegram doesn't mix text+file in one""",
"""        // PATCH:hybrid-tee-ack — write ack marker for sidecar (reply path)
        if (reply_to != null && sentIds.length > 0) {
          try {
            const dir = '%s/acked'
            mkdirSync(dir, { recursive: true })
            writeFileSync(`${dir}/${reply_to}.json`, JSON.stringify({ ts: new Date().toISOString(), via: 'reply' }))
          } catch {}
        }

        // Files go as separate messages (Telegram doesn't mix text+file in one""" % BOT)

if failed:
    print("REFUSING TO WRITE — anchor mismatch (patch site changed shape):")
    for f in failed:
        print("   ", f)
    sys.exit(2)

if src != orig:
    open(SRV, "w").write(src)

# ---------- Family B3 — package.json stdout redirect ----------
pkg = open(PKG).read() if NEED_B else ""
if not NEED_B:
    pass
elif "1>&2" not in pkg:
    if pkg.count("bun install --no-summary && bun server.ts") == 1:
        pkg = pkg.replace("bun install --no-summary && bun server.ts",
                          "bun install --no-summary 1>&2 && bun server.ts", 1)
        open(PKG, "w").write(pkg)
        applied.append("B3 package.json 1>&2")
    else:
        print("WARN: package.json start script shape changed — not patched")
else:
    skipped.append("B3 package.json 1>&2")

print("APPLIED :", ", ".join(applied) if applied else "(none)")
print("SKIPPED :", ", ".join(skipped) if skipped else "(none)")
