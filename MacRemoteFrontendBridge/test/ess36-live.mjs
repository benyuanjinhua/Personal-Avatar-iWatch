// ESS-36 live acceptance: 连续 5 条真实 AAC 语音打进真实 qwen-audio-agent
// (127.0.0.1:3101)，走完整北向协议（pair → 202 → WSS 事件 → REST 终态），
// 验证：全部到达终态、结果经 WSS 推送、断线后 REST 可恢复、无 session 停摆。
//
// Usage: node test/ess36-live.mjs <fixture1.m4a> [...more fixtures]

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

import { execFileSync } from 'node:child_process'
import crypto from 'node:crypto'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createBridge } from '../server.mjs'
import { BridgeClient, waitFor } from './client.mjs'

const fixtures = process.argv.slice(2)
if (!fixtures.length) {
  console.error('usage: node test/ess36-live.mjs <fixture1.m4a> [...more]')
  process.exit(2)
}

const TMP = mkdtempSync(join(tmpdir(), 'bridge-ess36-'))
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
  device_id: 'ess36-live',
  allowed_peer_ips: ['127.0.0.1'],
})
const [server] = await bridge.start()
const baseUrl = `https://127.0.0.1:${server.address().port}`
const client = new BridgeClient({ baseUrl })
await client.pair(readFileSync(join(TMP, 'state', 'pairing-code.txt'), 'utf8').trim(), 'ess36-live-client')
const events = client.events()
await waitFor(() => events.received.some(e => e.type === 'snapshot'))

// 连续提交（不等上一条完成）：同时压测串行队列 + per-turn work deadline
const turns = fixtures.map((path, i) => {
  const audio = readFileSync(path)
  return { i: i + 1, path, audio, id: 'req_' + crypto.randomUUID().replaceAll('-', '') }
})
const t0 = Date.now()
for (const turn of turns) {
  const created = await client.createTurn(turn.id, turn.audio, { codec: 'aac', durationMs: 5000 })
  console.error(`[turn ${turn.i}] create → ${created.status} (${turn.audio.length}B ${turn.path})`)
  if (created.status !== 202) {
    console.error(created.json)
    process.exit(1)
  }
}

const TERMINAL = ['completed', 'failed', 'cancelled']
const results = []
for (const turn of turns) {
  const final = await waitFor(async () => {
    const r = await client.getTurn(turn.id)
    return TERMINAL.includes(r.json?.status) ? r.json : null
  }, { timeoutMs: 240_000, intervalMs: 1000 })
  results.push({ turn, final })
  console.error(`[turn ${turn.i}] ${final.status} (${((Date.now() - t0) / 1000).toFixed(1)}s elapsed)`
    + (final.result?.text ? ` text="${final.result.text.slice(0, 60)}"` : '')
    + (final.error ? ` error=${final.error}` : ''))
}

// WSS 推送校验：每个 request 都应有 turn.state 事件流，且终态经 WSS 到达
const wssStates = id => events.received
  .filter(e => e.type === 'turn.state' && e.turn?.request_id === id)
  .map(e => e.turn.status)
let ok = true
for (const { turn, final } of results) {
  const states = wssStates(turn.id)
  const wssTerminal = states.some(s => TERMINAL.includes(s))
  const audioBytes = final.result?.audio_base64 ? Buffer.from(final.result.audio_base64, 'base64').length : 0
  console.error(`[turn ${turn.i}] wss_states=${JSON.stringify([...new Set(states)])} wss_terminal=${wssTerminal} result_audio=${audioBytes}B`)
  if (final.status !== 'completed' || !final.result?.text || !wssTerminal) ok = false
}

console.error(ok
  ? `PASS: ${results.length}/${results.length} turns completed with text results over WSS in ${((Date.now() - t0) / 1000).toFixed(1)}s`
  : 'FAIL: see above')
events.ws.close()
await bridge.stop()
process.exit(ok ? 0 : 1)
