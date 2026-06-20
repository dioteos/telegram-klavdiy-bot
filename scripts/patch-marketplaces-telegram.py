#!/usr/bin/env python3
"""Idempotent patcher for the marketplaces telegram plugin (Families A/B/C).

The marketplaces clone (~/.claude/plugins/marketplaces/claude-plugins-official)
is re-pulled from upstream main on REPL spawn, wiping local patches. The cache
path is what actually runs and is pinned/patched separately. This script re-applies
the same patches to the marketplaces server.ts + package.json as insurance for when
the running path flips between cache and marketplaces across plugin versions.

Canonical patch source: the running cache server.ts. See CLAUDE.md step 0.5 and
memory/project_telegram_plugin_patch.md. Safe to run repeatedly.
Exit 0 = all markers present after run; exit 1 = a patch site was not found.
"""
import sys, os

MKT = os.path.expanduser(
    "~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"
)
SRV = os.path.join(MKT, "server.ts")
PKG = os.path.join(MKT, "package.json")

# (description, old, new) — each old must appear exactly once when unpatched.
EDITS = [
    ("B:import-execFileSync",
     "import { homedir } from 'os'\nimport { join, extname, sep } from 'path'",
     "import { homedir } from 'os'\nimport { execFileSync } from 'child_process'\nimport { join, extname, sep } from 'path'"),

    ("B:pid-guard",
     "    process.kill(stale, 0)\n    process.stderr.write(`telegram channel: replacing stale poller pid=${stale}\\n`)\n    process.kill(stale, 'SIGTERM')",
     "    process.kill(stale, 0)\n    // PATCH:#1424-pid-guard — verify PID holder is a server.ts before SIGTERM (PID-recycling guard per claude-plugins-official#1424)\n    const cmd = execFileSync('ps', ['-p', String(stale), '-o', 'args='], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })\n    if (cmd.includes('server.ts')) {\n      process.stderr.write(`telegram channel: replacing stale poller pid=${stale}\\n`)\n      process.kill(stale, 'SIGTERM')\n    }"),

    ("C:dedup",
     "        const parseMode = format === 'markdownv2' ? 'MarkdownV2' as const : undefined\n\n        assertAllowedChat(chat_id)",
     "        const parseMode = format === 'markdownv2' ? 'MarkdownV2' as const : undefined\n\n        // PATCH:hybrid-tee-dedup — if sidecar already fired fallback for this reply_to, skip.\n        if (reply_to != null) {\n          try {\n            statSync(`/Users/dioteos/www/telegram-bot/fallback-fired/${reply_to}.json`)\n            process.stderr.write(`telegram reply: skipping ${reply_to} — fallback handled it\\n`)\n            return { content: [{ type: 'text', text: 'skipped (fallback handled)' }] }\n          } catch {}\n        }\n\n        assertAllowedChat(chat_id)"),

    ("A:no-preview-reply",
     "            const sent = await bot.api.sendMessage(chat_id, chunks[i], {\n              ...(shouldReplyTo ? { reply_parameters: { message_id: reply_to } } : {}),\n              ...(parseMode ? { parse_mode: parseMode } : {}),\n            })",
     "            const sent = await bot.api.sendMessage(chat_id, chunks[i], {\n              ...(shouldReplyTo ? { reply_parameters: { message_id: reply_to } } : {}),\n              ...(parseMode ? { parse_mode: parseMode } : {}),\n              link_preview_options: { is_disabled: true }, // PATCH:no-preview (telegram-klavdiy local patch — Anton wants previews always off)\n            })"),

    ("C:ack-reply",
     "          )\n        }\n\n        // Files go as separate messages (Telegram doesn't mix text+file in one",
     "          )\n        }\n\n        // PATCH:hybrid-tee-ack — write ack marker for sidecar (reply path)\n        if (reply_to != null && sentIds.length > 0) {\n          try {\n            const dir = '/Users/dioteos/www/telegram-bot/acked'\n            mkdirSync(dir, { recursive: true })\n            writeFileSync(`${dir}/${reply_to}.json`, JSON.stringify({ ts: new Date().toISOString(), via: 'reply' }))\n          } catch {}\n        }\n\n        // Files go as separate messages (Telegram doesn't mix text+file in one"),

    ("C:ack-react",
     "          { type: 'emoji', emoji: args.emoji as ReactionTypeEmoji['emoji'] },\n        ])\n        return { content: [{ type: 'text', text: 'reacted' }] }",
     "          { type: 'emoji', emoji: args.emoji as ReactionTypeEmoji['emoji'] },\n        ])\n        // PATCH:hybrid-tee-ack — write ack marker for sidecar (react path)\n        try {\n          const dir = '/Users/dioteos/www/telegram-bot/acked'\n          mkdirSync(dir, { recursive: true })\n          writeFileSync(`${dir}/${args.message_id}.json`, JSON.stringify({ ts: new Date().toISOString(), via: 'react' }))\n        } catch {}\n        return { content: [{ type: 'text', text: 'reacted' }] }"),

    ("A:no-preview-edit",
     "        const edited = await bot.api.editMessageText(\n          args.chat_id as string,\n          Number(args.message_id),\n          args.text as string,\n          ...(editParseMode ? [{ parse_mode: editParseMode }] : []),\n        )",
     "        const edited = await bot.api.editMessageText(\n          args.chat_id as string,\n          Number(args.message_id),\n          args.text as string,\n          {\n            ...(editParseMode ? { parse_mode: editParseMode } : {}),\n            link_preview_options: { is_disabled: true }, // PATCH:no-preview (telegram-klavdiy local patch)\n          },\n        )"),

    ("B:no-ppid",
     "const bootPpid = process.ppid\nsetInterval(() => {\n  const orphaned =\n    (process.platform !== 'win32' && process.ppid !== bootPpid) ||\n    process.stdin.destroyed ||\n    process.stdin.readableEnded\n  if (orphaned) shutdown()\n}, 5000).unref()",
     "// PATCH:#1424-no-ppid — dropped `process.ppid !== bootPpid` check; it false-fires\n// when bun-run/shell wrapper exits during normal startup and we get reparented to\n// init. Per anthropics/claude-plugins-official#1424 / fixes #1467.\nsetInterval(() => {\n  if (process.stdin.destroyed || process.stdin.readableEnded) shutdown()\n}, 5000).unref()"),

    ("C:inbox",
     "  const imagePath = downloadImage ? await downloadImage() : undefined\n\n  // image_path goes in meta only",
     "  const imagePath = downloadImage ? await downloadImage() : undefined\n\n  // PATCH:hybrid-tee-inbox — write inbox marker for sidecar safety-net.\n  if (msgId != null) {\n    try {\n      const dir = '/Users/dioteos/www/telegram-bot/inbox'\n      mkdirSync(dir, { recursive: true })\n      writeFileSync(`${dir}/${msgId}.json`, JSON.stringify({\n        chat_id, message_id: String(msgId),\n        user: from.username ?? String(from.id),\n        user_id: String(from.id),\n        text, ts: new Date().toISOString(),\n      }))\n    } catch (e) {\n      process.stderr.write(`telegram tee inbox failed: ${e}\\n`)\n    }\n  }\n\n  // image_path goes in meta only"),
]

MARKERS = {  # marker -> expected min count
    "PATCH:no-preview": 2,
    "PATCH:#1424-no-ppid": 1,
    "PATCH:#1424-pid-guard": 1,
    "PATCH:hybrid-tee-inbox": 1,
    "PATCH:hybrid-tee-ack": 2,
    "PATCH:hybrid-tee-dedup": 1,
}

def main():
    if not os.path.exists(SRV):
        print(f"server.ts not present at {SRV} — skipping (will appear on next spawn)")
        return 0
    src = open(SRV, encoding="utf-8").read()
    failed = []
    for desc, old, new in EDITS:
        if new in src:
            continue  # already applied
        if old not in src:
            failed.append(desc)
            continue
        if src.count(old) != 1:
            failed.append(f"{desc} (ambiguous: {src.count(old)} matches)")
            continue
        src = src.replace(old, new, 1)
    open(SRV, "w", encoding="utf-8").write(src)

    # package.json 1>&2
    pkg = open(PKG, encoding="utf-8").read()
    if "1>&2" not in pkg:
        if "bun install --no-summary && bun server.ts" in pkg:
            pkg = pkg.replace("bun install --no-summary && bun server.ts",
                              "bun install --no-summary 1>&2 && bun server.ts", 1)
            open(PKG, "w", encoding="utf-8").write(pkg)
        else:
            failed.append("B:pkg-1>&2 (start script shape changed)")

    # verify markers
    src = open(SRV, encoding="utf-8").read()
    for m, want in MARKERS.items():
        got = src.count(m)
        if got < want:
            failed.append(f"marker {m}: {got} < {want}")
    pkg = open(PKG, encoding="utf-8").read()
    if "1>&2" not in pkg:
        failed.append("pkg 1>&2 missing")

    if failed:
        print("FAIL: " + "; ".join(failed))
        return 1
    print("OK: all marketplaces patches applied (A x2, B pid-guard/no-ppid/pkg, C inbox/ack x2/dedup)")
    return 0

sys.exit(main())
