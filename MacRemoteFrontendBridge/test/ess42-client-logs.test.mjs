// ESS-42：POST /v1/client-logs —— Watch JSONL 日志 chunk 上行落 bridge.log。
// 验证：签名必需、逐行 evt=watch_client_log（按 request_id 可 grep）、字段
// 白名单+截断、坏行留痕、chunk_id 幂等去重、协议/字段校验稳定错误码。

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import crypto from 'node:crypto'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createBridge } from '../server.mjs'
import { MockGateway } from './mock-gateway.mjs'
import { BridgeClient } from './client.mjs'

const TMP = mkdtempSync(join(tmpdir(), 'bridge-ess42-'))
const CERT = join(TMP, 'bridge.crt')
const KEY = join(TMP, 'bridge.key')
execFileSync('openssl', [
  'req', '-x509', '-newkey', 'rsa:2048', '-keyout', KEY, '-out', CERT,
  '-days', '1', '-nodes', '-subj', '/CN=127.0.0.1',
], { stdio: 'ignore' })

// bridge.log 即 Bridge 进程 stdout：拦截 stdout 写入以断言落日志的内容。
function captureStdout() {
  const lines = []
  const original = process.stdout.write.bind(process.stdout)
  process.stdout.write = chunk => {
    for (const line of String(chunk).split('\n')) {
      if (!line.trim()) continue
      try { lines.push(JSON.parse(line)) } catch { /* 非 JSON 行忽略 */ }
    }
    return true
  }
  return { lines, restore: () => { process.stdout.write = original } }
}

const chunkId = () => 'watchlog-' + crypto.randomUUID().replaceAll('-', '') + '.jsonl'

const postLogs = (client, id, jsonl, { protocolVersion = 1, requestId = id } = {}) =>
  client.signed('POST', '/v1/client-logs', {
    requestId,
    json: { protocol_version: protocolVersion, chunk_id: id, source: 'watch', jsonl },
  })

describe('ESS-42 watch client logs', () => {
  let mock, bridge, client

  before(async () => {
    mock = new MockGateway({ scenario: 'direct' })
    const gatewayUrl = await mock.start()
    bridge = createBridge({
      port: 0,
      bind_tailscale_ip: 'none',
      tls_cert: CERT,
      tls_key: KEY,
      state_dir: join(TMP, 'state'),
      gateway_url: gatewayUrl,
    })
    const [server] = await bridge.start()
    client = new BridgeClient({ baseUrl: `https://127.0.0.1:${server.address().port}` })
    const pairingCode = readFileSync(join(TMP, 'state', 'pairing-code.txt'), 'utf8').trim()
    const paired = await client.pair(pairingCode)
    assert.equal(paired.status, 201)
  })

  after(async () => { await bridge.stop(); await mock.stop() })

  it('requires a valid signature', async () => {
    const id = chunkId()
    const r = await postLogs(client, id, '{}', {})
    assert.equal(r.status, 200)
    const stranger = new BridgeClient({
      baseUrl: client.baseUrl, deviceId: 'dev_nope', token: 'aa'.repeat(32),
    })
    const rejected = await postLogs(stranger, chunkId(), '{}')
    assert.equal(rejected.json.error, 'ERR_DEVICE_UNKNOWN')
  })

  it('writes one watch_client_log line per JSONL entry, greppable by request_id', async () => {
    const id = chunkId()
    const requestId = 'req_' + crypto.randomUUID().replaceAll('-', '')
    const jsonl = [
      JSON.stringify({
        ts: '2026-08-01T08:00:00.000Z', request_id: requestId, module: 'welcome',
        event: 'resource_missing', detail: 'WelcomeSpeech.m4a not in bundle',
        error: { code: 'ERR_WELCOME_ASSET_MISSING', description: 'missing' },
      }),
      JSON.stringify({ ts: '2026-08-01T08:00:01.000Z', module: 'lifecycle', event: 'cold_start' }),
      'this is not json',
    ].join('\n')

    const captured = captureStdout()
    let r
    try { r = await postLogs(client, id, jsonl) } finally { captured.restore() }
    assert.equal(r.status, 200)
    assert.equal(r.json.accepted, 3)

    const logged = captured.lines.filter(l => l.evt === 'watch_client_log' && l.chunk_id === id)
    assert.equal(logged.length, 2)
    const byRequest = logged.find(l => l.request_id === requestId)
    assert.ok(byRequest, '必须能按 request_id 查到')
    assert.equal(byRequest.module, 'welcome')
    assert.equal(byRequest.event, 'resource_missing')
    assert.equal(byRequest.error_code, 'ERR_WELCOME_ASSET_MISSING')
    const bad = captured.lines.find(l => l.evt === 'watch_client_log_bad_line' && l.chunk_id === id)
    assert.ok(bad, '坏行要留痕而不是静默丢弃')
  })

  it('truncates oversized client-controlled fields', async () => {
    const id = chunkId()
    const jsonl = JSON.stringify({
      ts: 'x'.repeat(200), module: 'm'.repeat(200), event: 'e', detail: 'd'.repeat(2000),
      error: { code: 'c'.repeat(500), description: 'y'.repeat(2000) },
    })
    const captured = captureStdout()
    try { await postLogs(client, id, jsonl) } finally { captured.restore() }
    const line = captured.lines.find(l => l.evt === 'watch_client_log' && l.chunk_id === id)
    assert.ok(line)
    assert.equal(line.watch_ts.length, 40)
    assert.equal(line.module.length, 64)
    assert.equal(line.detail.length, 500)
    assert.equal(line.error_code.length, 80)
    assert.equal(line.error_description.length, 300)
  })

  it('deduplicates replayed chunk_ids', async () => {
    const id = chunkId()
    const jsonl = JSON.stringify({ ts: 't', module: 'm', event: 'e' })
    const first = await postLogs(client, id, jsonl)
    assert.equal(first.json.accepted, 1)

    const captured = captureStdout()
    let replay
    try { replay = await postLogs(client, id, jsonl) } finally { captured.restore() }
    assert.equal(replay.status, 200)
    assert.equal(replay.json.accepted, 0)
    assert.equal(replay.json.idempotent_replay, true)
    assert.equal(captured.lines.filter(l => l.evt === 'watch_client_log' && l.chunk_id === id).length, 0)
  })

  it('rejects protocol/field violations with stable codes', async () => {
    const badVersion = await postLogs(client, chunkId(), '{}', { protocolVersion: 99 })
    assert.equal(badVersion.json.error, 'ERR_PROTOCOL_VERSION')

    const id = chunkId()
    const mismatched = await postLogs(client, id, '{}', { requestId: chunkId() })
    assert.equal(mismatched.json.error, 'ERR_MISSING_FIELD')

    const noJsonl = await client.signed('POST', '/v1/client-logs', {
      requestId: id,
      json: { protocol_version: 1, chunk_id: id, source: 'watch' },
    })
    assert.equal(noJsonl.json.error, 'ERR_MISSING_FIELD')

    const notJson = await client.signed('POST', '/v1/client-logs', { requestId: id })
    assert.equal(notJson.json.error, 'ERR_BAD_JSON')
  })
})
