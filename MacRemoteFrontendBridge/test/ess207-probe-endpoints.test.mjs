// ESS-207 契约：Bridge 侧探针注入与播放回执两条端点。
//
// - POST /v1/probe/inject：loopback-only，合成 completed turn（kind=probe），
//   走完 allowDownlinkMessage + resultAudio.put + WSS 出口的生产路径；
// - POST /v1/probe/ack：签名请求，Watch 端播放成功回执，落 evt=probe_acked。
//
// 不用 MockGateway/audio pipeline —— 只关心「注入是否落 l1_audio_ready+WSS
// completed(turn.audio.kind=probe) / ack 是否落 probe_acked」。

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createBridge } from '../server.mjs'
import { sha256hex } from '../auth.mjs'
import { MockGateway } from './mock-gateway.mjs'
import { BridgeClient, waitFor } from './client.mjs'

const TMP = mkdtempSync(join(tmpdir(), 'bridge-ess207-'))
const CERT = join(TMP, 'bridge.crt')
const KEY = join(TMP, 'bridge.key')
execFileSync('openssl', [
  'req', '-x509', '-newkey', 'rsa:2048', '-keyout', KEY, '-out', CERT,
  '-days', '1', '-nodes', '-subj', '/CN=127.0.0.1',
], { stdio: 'ignore' })

let stateSeq = 0

async function launch(overrides = {}) {
  const mock = new MockGateway()
  const gatewayUrl = await mock.start()
  const stateDir = join(TMP, `state-${stateSeq++}`)
  const bridge = createBridge({
    port: 0,
    bind_tailscale_ip: 'none',
    tls_cert: CERT,
    tls_key: KEY,
    state_dir: stateDir,
    gateway_url: gatewayUrl,
    allow_test_pcm: true,
    audiopipe_path: './test/fake-audiopipe',
    device_id: 'jackson-iphone',
    ...overrides,
  })
  const [server] = await bridge.start()
  const baseUrl = `https://127.0.0.1:${server.address().port}`
  const client = new BridgeClient({ baseUrl })
  const pairingCode = readFileSync(join(stateDir, 'pairing-code.txt'), 'utf8').trim()
  const paired = await client.pair(pairingCode)
  assert.equal(paired.status, 201)
  return { mock, bridge, client, baseUrl }
}

const probeAudio = () => {
  // 合成一小段"m4a"—— fake-audiopipe 用 FAKEM4A0 前缀，probe inject 不走 audio
  // pipeline 直接吃字节，所以这里可以是任意非空 buffer。
  const buf = Buffer.alloc(8192)
  crypto.randomFillSync(buf)
  return buf
}

describe('ESS-207 POST /v1/probe/inject', () => {
  let ctx
  before(async () => { ctx = await launch() })
  after(async () => { await ctx.bridge.stop(); await ctx.mock.stop() })

  it('injects a probe turn, emits WSS turn.state with audio.kind=probe and reaches downloadable audio', async () => {
    const events = ctx.client.events()
    await waitFor(() => events.received.some(e => e.type === 'snapshot'))

    const requestId = 'probe-' + crypto.randomUUID().replaceAll('-', '')
    const audio = probeAudio()
    const sha = sha256hex(audio)
    // 显式指定 device_id 与 client 配对时拿到的一致，否则 WSS 出口按 device_id
    // 过滤会把这条 turn.state 送到"错误"的收件人（真机上默认 device_id 就是
    // 白梦林那台已配对手机，这里显式传入模拟同样效果）。
    const inject = await fetch(`${ctx.baseUrl}/v1/probe/inject`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        request_id: requestId,
        audio_base64: audio.toString('base64'),
        sha256: sha,
        duration_ms: 3500,
        text: '你好Jackson，我是你的数字分身',
        device_id: ctx.client.deviceId,
      }),
    })
    assert.equal(inject.status, 202)
    const injectBody = await inject.json()
    assert.equal(injectBody.request_id, requestId)
    assert.equal(injectBody.sha256, sha)
    assert.equal(injectBody.device_id, ctx.client.deviceId)

    // WSS 出口收到 completed 投影，audio.kind = probe（通过 allowDownlinkMessage）
    const completed = await waitFor(() => events.received.find(e =>
      e.type === 'turn.state'
      && e.turn?.request_id === requestId
      && e.turn?.status === 'completed'
      && e.turn?.result?.audio?.kind === 'probe'
    ), { timeoutMs: 5_000 })
    assert.equal(completed.turn.result.audio.sha256, sha)
    assert.equal(completed.turn.result.audio.codec, 'm4a')
    // inline base64 也带回来，与元数据 sha 对齐
    const inline = Buffer.from(completed.turn.result.audio_base64, 'base64')
    assert.equal(sha256hex(inline), sha)

    // 下载端点：全量取回后 sha 一致
    const full = await ctx.client.downloadAudio(requestId)
    assert.equal(full.status, 200)
    assert.equal(sha256hex(full.body), sha)

    events.ws.close()
  })

  it('rejects a second inject with the same request_id (idempotency conflict)', async () => {
    const requestId = 'probe-' + crypto.randomUUID().replaceAll('-', '')
    const audio = probeAudio()
    const body = JSON.stringify({
      request_id: requestId, audio_base64: audio.toString('base64'), sha256: sha256hex(audio),
    })
    const first = await fetch(`${ctx.baseUrl}/v1/probe/inject`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body,
    })
    assert.equal(first.status, 202)
    const second = await fetch(`${ctx.baseUrl}/v1/probe/inject`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body,
    })
    assert.equal(second.status, 409)
  })

  it('rejects a sha256 mismatch between body.sha256 and audio_base64 bytes', async () => {
    const audio = probeAudio()
    const body = JSON.stringify({
      request_id: 'probe-' + crypto.randomUUID().replaceAll('-', ''),
      audio_base64: audio.toString('base64'),
      sha256: '0'.repeat(64),
    })
    const r = await fetch(`${ctx.baseUrl}/v1/probe/inject`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body,
    })
    assert.equal(r.status, 422)
    const json = await r.json()
    assert.equal(json.error, 'ERR_AUDIO_HASH_MISMATCH')
  })

  it('rejects missing request_id / audio_base64', async () => {
    const audio = probeAudio()
    for (const body of [
      JSON.stringify({ audio_base64: audio.toString('base64') }),
      JSON.stringify({ request_id: 'probe-x' }),
    ]) {
      const r = await fetch(`${ctx.baseUrl}/v1/probe/inject`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, body,
      })
      assert.equal(r.status, 400)
    }
  })
})

describe('ESS-207 POST /v1/probe/ack', () => {
  let ctx
  before(async () => { ctx = await launch() })
  after(async () => { await ctx.bridge.stop(); await ctx.mock.stop() })

  it('accepts a signed probe ack from a paired device (200)', async () => {
    // 先注入一次探针，让 request_id 存在（ack 端点不严格要求 turn 存在，因为
    // 探针 turn 是合成的；但真机上 iPhone Relay 在收到 Watch ACK 时探针 turn
    // 一定已经过完 WSS）。这里两条都跑一遍以贴近生产流。
    const requestId = 'probe-' + crypto.randomUUID().replaceAll('-', '')
    const audio = probeAudio()
    const sha = sha256hex(audio)
    const inject = await fetch(`${ctx.baseUrl}/v1/probe/inject`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        request_id: requestId, audio_base64: audio.toString('base64'), sha256: sha,
      }),
    })
    assert.equal(inject.status, 202)

    const ackBody = {
      protocol_version: 1,
      request_id: requestId,
      sha256: sha,
      played_at_ms: 1_754_237_400_000,
      duration_ms: 3500,
    }
    const ack = await ctx.client.signed('POST', '/v1/probe/ack', {
      requestId, json: ackBody,
    })
    assert.equal(ack.status, 200)
    assert.equal(ack.json.request_id, requestId)
    assert.equal(ack.json.acknowledged, true)
  })

  it('rejects sha256 or played_at_ms missing (400)', async () => {
    const requestId = 'probe-' + crypto.randomUUID().replaceAll('-', '')
    const noSha = await ctx.client.signed('POST', '/v1/probe/ack', {
      requestId,
      json: { protocol_version: 1, request_id: requestId, played_at_ms: 1 },
    })
    assert.equal(noSha.status, 400)
    const noAt = await ctx.client.signed('POST', '/v1/probe/ack', {
      requestId,
      json: { protocol_version: 1, request_id: requestId, sha256: '0'.repeat(64) },
    })
    assert.equal(noAt.status, 400)
  })

  it('rejects body.request_id ≠ x-request-id (400)', async () => {
    const requestId = 'probe-' + crypto.randomUUID().replaceAll('-', '')
    const r = await ctx.client.signed('POST', '/v1/probe/ack', {
      requestId,
      json: {
        protocol_version: 1,
        request_id: 'probe-other',
        sha256: '0'.repeat(64),
        played_at_ms: 1,
      },
    })
    assert.equal(r.status, 400)
  })
})
