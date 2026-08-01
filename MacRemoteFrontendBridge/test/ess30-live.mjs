// ESS-30 live acceptance driver against the real qwen-audio-agent gateway.
//
// Usage:
//   node test/ess30-live.mjs latency <f1.m4a> [f2.m4a ...]
//   node test/ess30-live.mjs permission <allow|deny> <fixture.m4a>

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

import { execFileSync } from 'node:child_process'
import crypto from 'node:crypto'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, basename } from 'node:path'
import { createBridge } from '../server.mjs'
import { BridgeClient, waitFor } from './client.mjs'

const [mode, ...rest] = process.argv.slice(2)

const TMP = mkdtempSync(join(tmpdir(), 'ess30-'))
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
  device_id: 'ess30-live',
})
const [server] = await bridge.start()
const baseUrl = `https://127.0.0.1:${server.address().port}`
const client = new BridgeClient({ baseUrl })
await client.pair(readFileSync(join(TMP, 'state', 'pairing-code.txt'), 'utf8').trim())
const events = client.events()
await waitFor(() => events.received.some(e => e.type === 'snapshot'))

const report = []

const terminal = s => ['completed', 'failed', 'cancelled'].includes(s)

async function submit(fixturePath, durationMs) {
  const audio = readFileSync(fixturePath)
  const id = 'req_' + crypto.randomUUID().replaceAll('-', '')
  const t0 = Date.now()
  const created = await client.createTurn(id, audio, { codec: 'aac', durationMs })
  return { id, t0, receiptMs: Date.now() - t0, created }
}

try {
  if (mode === 'latency') {
    for (const fixture of rest) {
      const { id, t0, receiptMs, created } = await submit(fixture, 8000)
      if (created.status !== 202) {
        report.push({ fixture: basename(fixture), error: created.json })
        continue
      }
      let final
      try {
        final = await waitFor(async () => {
          const r = await client.getTurn(id)
          return terminal(r.json.status) ? r.json : null
        }, { timeoutMs: 320_000, intervalMs: 250 })
      } catch (e) {
        report.push({ fixture: basename(fixture), request_id: id, receipt_ms: receiptMs, error: 'no terminal state in 320s' })
        console.error(`[${basename(fixture)}] receipt=${receiptMs}ms TIMED OUT waiting for terminal state`)
        continue
      }
      report.push({
        fixture: basename(fixture),
        request_id: id,
        receipt_ms: receiptMs,
        answer_ms: Date.now() - t0,
        status: final.status,
        path: final.path,
        error: final.error,
        result_text: final.result?.text?.slice(0, 120) ?? null,
        result_audio_bytes: final.result?.audio_base64
          ? Buffer.from(final.result.audio_base64, 'base64').length : 0,
      })
      console.error(`[${basename(fixture)}] receipt=${receiptMs}ms answer=${report.at(-1).answer_ms}ms status=${final.status} path=${final.path}`)
    }
  } else if (mode === 'permission') {
    const [decision, fixture] = rest
    const { id, t0, receiptMs, created } = await submit(fixture, 15_000)
    if (created.status !== 202) throw new Error('create failed: ' + JSON.stringify(created.json))
    console.error(`[perm-${decision}] accepted in ${receiptMs}ms, waiting for permission_required...`)
    const withPerm = await waitFor(async () => {
      const r = await client.getTurn(id)
      if (terminal(r.json.status)) throw new Error('terminal before permission: ' + JSON.stringify(r.json))
      return r.json.status === 'permission_required' ? r.json : null
    }, { timeoutMs: 240_000, intervalMs: 1000 })
    const permMs = Date.now() - t0
    console.error(`[perm-${decision}] permission_required after ${permMs}ms: ${withPerm.permission?.title}`)
    const resp = await client.permission(id, withPerm.permission.id, decision)
    const final = await waitFor(async () => {
      const r = await client.getTurn(id)
      return terminal(r.json.status) ? r.json : null
    }, { timeoutMs: 240_000, intervalMs: 1000 })
    report.push({
      mode: `permission-${decision}`,
      request_id: id,
      receipt_ms: receiptMs,
      permission_required_ms: permMs,
      permission_title: withPerm.permission?.title ?? null,
      permission_response_status: resp.status,
      final_status: final.status,
      task_id: final.task_id,
      error: final.error,
      wall_ms: Date.now() - t0,
      result_text: final.result?.text?.slice(0, 300) ?? null,
      ws_states: [...new Set(events.received
        .filter(e => e.type === 'turn.state' && e.turn.request_id === id)
        .map(e => `${e.turn.status}${e.turn.detail ? ':' + e.turn.detail : ''}`))],
    })
  } else {
    console.error('unknown mode'); process.exit(2)
  }
} finally {
  events.ws.close()
  await bridge.stop()
}
console.log(JSON.stringify({ report }, null, 2))
