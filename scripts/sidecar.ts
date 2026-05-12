#!/usr/bin/env bun
// Sidecar safety-net for the Telegram REPL.
// Polls ./inbox/ every 5 s; fires a headless claude -p fallback when an inbound
// message has sat unhandled past 60 s AND the REPL is verifiably hung
// (repl-heartbeat > 90 s old). Writes ./fallback-fired/<id>.json before
// spawning to prevent races; the plugin's reply tool consults the same marker
// to dedup-skip if REPL recovers later.

import { readdir, stat, mkdir, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { spawn } from 'node:child_process'

const BOT_DIR = '/Users/dioteos/www/telegram-bot'
const INBOX = `${BOT_DIR}/inbox`
const ACKED = `${BOT_DIR}/acked`
const FIRED = `${BOT_DIR}/fallback-fired`
const REPL_HEARTBEAT = `${BOT_DIR}/repl-heartbeat`
const FALLBACK_WRAPPER = `${BOT_DIR}/scripts/claude-fallback-reply.sh`

const INBOX_MIN_AGE_SEC = 60
const REPL_HEARTBEAT_STALE_SEC = 90
const POLL_INTERVAL_MS = 5000
const MAX_INBOX_AGE_SEC = 24 * 3600  // skip anything older than 24 h — assume dead

function ts() {
  return new Date().toISOString()
}

async function ensureDirs() {
  for (const d of [INBOX, ACKED, FIRED]) {
    await mkdir(d, { recursive: true })
  }
}

async function fileAgeSec(path: string): Promise<number> {
  try {
    const s = await stat(path)
    return (Date.now() - s.mtimeMs) / 1000
  } catch {
    return Infinity
  }
}

async function fireFallback(msgId: string, inboxAge: number, hbAge: number) {
  const firedPath = `${FIRED}/${msgId}.json`
  await writeFile(firedPath, JSON.stringify({
    ts: ts(),
    inbox_age_sec: Math.round(inboxAge),
    repl_heartbeat_age_sec: Math.round(hbAge),
  }))
  console.log(`[${ts()}] FALLBACK FIRE msg=${msgId} inbox_age=${Math.round(inboxAge)}s hb_age=${Math.round(hbAge)}s`)
  const child = spawn(FALLBACK_WRAPPER, [msgId], {
    stdio: 'ignore',
    detached: true,
  })
  child.unref()
}

async function checkInbox() {
  let entries: string[]
  try {
    entries = await readdir(INBOX)
  } catch {
    return
  }
  for (const f of entries) {
    if (!f.endsWith('.json') || f === '.gitkeep.json') continue
    const msgId = f.slice(0, -'.json'.length)

    if (existsSync(`${ACKED}/${msgId}.json`)) continue
    if (existsSync(`${FIRED}/${msgId}.json`)) continue

    const inboxAge = await fileAgeSec(`${INBOX}/${f}`)
    if (inboxAge < INBOX_MIN_AGE_SEC) continue
    if (inboxAge > MAX_INBOX_AGE_SEC) continue

    const hbAge = await fileAgeSec(REPL_HEARTBEAT)
    if (hbAge < REPL_HEARTBEAT_STALE_SEC) continue

    try {
      await fireFallback(msgId, inboxAge, hbAge)
    } catch (e) {
      console.error(`[${ts()}] fire failed msg=${msgId}: ${e}`)
    }
  }
}

async function main() {
  await ensureDirs()
  console.log(`[${ts()}] sidecar started — poll=${POLL_INTERVAL_MS}ms inbox_min_age=${INBOX_MIN_AGE_SEC}s hb_stale=${REPL_HEARTBEAT_STALE_SEC}s`)
  while (true) {
    try {
      await checkInbox()
    } catch (e) {
      console.error(`[${ts()}] tick failed: ${e}`)
    }
    await new Promise(r => setTimeout(r, POLL_INTERVAL_MS))
  }
}

main()
