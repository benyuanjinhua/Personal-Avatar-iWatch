// Real-gateway end-to-end: full northbound chain against the live
// qwen-audio-agent v0.9.1 on 127.0.0.1:3101 (simulated iPhone client,
// real AAC fixtures, real transcode via audiopipe).
//
// Usage: node test/e2e-real.mjs <direct.m4a> [task.m4a]

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

import { execFileSync } from 'node:child_process'
import crypto from 'node:crypto'
import { mkdtempSync, readFileSync } from 'node:fs'
import { writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createBridge } from '../server.mjs'
import { BridgeClient, waitFor } from './client.mjs'

const [directFixture, taskFixture] = process.argv.slice(2)
if (!directFixture) {
  console.error('usage: node test/e2e-real.mjs <direct.m4a> [task.m4a]')
  process.exit(2)
}

const TMP = mkdtempSync(join(tmpdir(), 'bridge-e2e-'))
const CERT = join(TMP, 'bridge.crt')
const KEY = join(TMP, 'bridge.key')
execFileSync('openssl', [
  'req', '-x509', '-newkey', 'rsa:2048', '-keyout', KEY, '-out', CERT,
  '-days', '1', '-nodes', '-subj', '/CN=127.0.0.1',
], { stdio: 'ignore' })

const bridge = createBridge({
  port: 0,
  bind_tailscale_ip: 'none',
  tls_cert: CERT,
  tls_key: KEY,
  state_dir: join(TMP, 'state'),
  gateway_url: 'http://127.0.0.1:3101',
  device_id: 'e2e-real',
})
const [server] = await bridge.start()
const baseUrl = `https://127.0.0.1:${server.address().port}`
const client = new BridgeClient({ baseUrl })
await client.pair(readFileSync(join(TMP, 'state', 'pairing-code.txt'), 'utf8').trim())
const events = client.events()
await waitFor(() => events.received.some(e => e.type === 'snapshot'))

const report = []

async function runTurn(label, fixturePath, { waitMs }) {
  const audio = readFileSync(fixturePath)
  const id = 'req_' + crypto.randomUUID().replaceAll('-', '')
  const t0 = Date.now()
  const created = await client.createTurn(id, audio, {
    codec: 'aac',
    durationMs: 8000,
  })
  const receiptMs = Date.now() - t0
  console.error(`[${label}] create → ${created.status} in ${receiptMs}ms`)
  if (created.status !== 202) {
    report.push({ label, error: created.json })
    return null
  }
  const final = await waitFor(async () => {
    const r = await client.getTurn(id)
    return ['completed', 'failed', 'cancelled'].includes(r.json.status) ? r.json : null
  }, { timeoutMs: waitMs, intervalMs: 1000 })
  const wallMs = Date.now() - t0

  // idempotent retry after completion: must replay, not re-execute
  const replay = await client.createTurn(id, audio, { codec: 'aac', durationMs: 8000 })

  const wsStates = events.received
    .filter(e => e.type === 'turn.state' && e.turn.request_id === id)
    .map(e => `${e.turn.status}${e.turn.detail ? ':' + e.turn.detail : ''}`)

  const entry = {
    label,
    request_id: id,
    receipt_ms: receiptMs,
    wall_ms: wallMs,
    status: final.status,
    path: final.path,
    task_id: final.task_id,
    error: final.error,
    result_text: final.result?.text?.slice(0, 300) ?? null,
    result_audio_bytes: final.result?.audio_base64 ? Buffer.from(final.result.audio_base64, 'base64').length : 0,
    idempotent_replay: replay.json?.idempotent_replay === true,
    replay_status: replay.json?.status,
    ws_states: [...new Set(wsStates)],
  }
  report.push(entry)
  if (final.result?.audio_base64) {
    writeFileSync(join(TMP, `${label}.reply.m4a`), Buffer.from(final.result.audio_base64, 'base64'))
    console.error(`[${label}] reply audio → ${join(TMP, `${label}.reply.m4a`)}`)
  }
  console.error(`[${label}] ${final.status} path=${final.path} wall=${wallMs}ms`)
  return entry
}

try {
  await runTurn('direct', directFixture, { waitMs: 60_000 })
  if (taskFixture) await runTurn('background', taskFixture, { waitMs: 300_000 })
} finally {
  events.ws.close()
  await bridge.stop()
}
console.log(JSON.stringify({ tmp: TMP, report }, null, 2))
