// ESS-207 门禁：Bridge 侧探针注入 + 回执端点的行为契约。
//
// PR #59 已实现了「Bridge 侧的 kind=probe 白名单 + downlink-probe.mjs 解析器
// + CLI 判定」；ESS-207 补齐把探针**送出去**（POST /v1/probe/inject）与**收
// 回执**（POST /v1/probe/ack）的两条 HTTP 端点。这里做黑盒契约测试：
// - inject：loopback-only（拒非 127.0.0.1）；audio_base64/sha256 校验；成功
//   落 evt=l1_audio_ready(kind=probe) + turn 进 completed 并携带 audio_base64；
// - ack：签名鉴权；四条强校验（turn 存在 / kind=probe / device_id 匹配 /
//   sha 匹配）都过才落 evt=probe_acked（H5）；顺手 ack 探针 turn 停 sweep；
// - 隔离：探针 turn 不污染生产 turn 的账本状态。

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
import { BridgeClient, waitFor } from './client.mjs'
import { parseProbeHops, evaluateProbe, PROBE } from '../downlink-probe.mjs'

const TMP = mkdtempSync(join(tmpdir(), 'bridge-ess207-'))
const CERT = join(TMP, 'bridge.crt')
const KEY = join(TMP, 'bridge.key')
execFileSync('openssl', [
  'req', '-x509', '-newkey', 'rsa:2048', '-keyout', KEY, '-out', CERT,
  '-days', '1', '-nodes', '-subj', '/CN=127.0.0.1',
], { stdio: 'ignore' })

let stateSeq = 0

async function launch({ overrides = {} } = {}) {
  const mock = new MockGateway({ scenario: 'direct' })
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
    result_delivery_sweep_ms: 60_000,
    events_heartbeat_ms: 60_000,
    ...overrides,
  })
  const [server] = await bridge.start()
  const baseUrl = `https://127.0.0.1:${server.address().port}`
  const client = new BridgeClient({ baseUrl })
  const pairingCode = readFileSync(join(stateDir, 'pairing-code.txt'), 'utf8').trim()
  await client.pair(pairingCode)
  return { mock, bridge, client, baseUrl }
}

function fakeProbeAudio(bytes = 2048) {
  const buf = Buffer.alloc(bytes)
  crypto.randomFillSync(buf)
  return buf
}

const probeRid = () => 'probe-' + crypto.randomUUID()

// bridge.log 是闭包内定义的，不能事后 monkey-patch；只能拦 stdout。
async function captureStdout(work) {
  const originalWrite = process.stdout.write.bind(process.stdout)
  const captured = []
  process.stdout.write = (chunk, ...rest) => {
    if (typeof chunk === 'string' && chunk.startsWith('{"ts"')) {
      try { captured.push(JSON.parse(chunk)) } catch { /* ignore non-JSON */ }
    }
    return originalWrite(chunk, ...rest)
  }
  try { await work() } finally { process.stdout.write = originalWrite }
  return captured
}

describe('ESS-207 /v1/probe/inject', () => {
  let ctx
  before(async () => { ctx = await launch() })
  after(async () => { await ctx.bridge.stop(); await ctx.mock.stop() })

  it('accepts a loopback inject and lands turn in completed with kind=probe', async () => {
    const requestId = probeRid()
    const audio = fakeProbeAudio()
    const r = await ctx.client.probeInject({ requestId, audioBuf: audio, text: '你好Jackson' })
    assert.equal(r.status, 202, `inject failed: ${JSON.stringify(r.json)}`)
    assert.equal(r.json.request_id, requestId)
    assert.equal(r.json.size_bytes, audio.length)

    const turn = await ctx.client.getTurn(requestId)
    assert.equal(turn.status, 200)
    assert.equal(turn.json.status, 'completed', 'probe 直接落成 completed，Watch 端才能进入播放路径')
    assert.equal(turn.json.result?.audio?.kind, 'probe', '结果元数据必须带 kind=probe，Relay/Watch 靠它分流')
    assert.equal(turn.json.result?.audio?.sha256, r.json.sha256)
    // 音频 inline base64 与元数据一起下发，Relay 不必再走 /audio 有界下载。
    assert.equal(typeof turn.json.result?.audio_base64, 'string')
    assert.ok(turn.json.result.audio_base64.length > 0)
  })

  it('is idempotent: same request_id + kind=probe re-inject re-emits without conflict', async () => {
    const requestId = probeRid()
    const audio = fakeProbeAudio()
    const first = await ctx.client.probeInject({ requestId, audioBuf: audio })
    assert.equal(first.status, 202)
    const second = await ctx.client.probeInject({ requestId, audioBuf: audio })
    assert.equal(second.status, 202, '同 request_id 二次注入不应报 idempotency conflict')
  })

  it('rejects request_id belonging to a non-probe turn', async () => {
    // 用生产 create-turn 造一个 direct 结果 turn，再拿它的 request_id 走 probe/inject。
    const requestId = 'req_' + crypto.randomUUID().replaceAll('-', '')
    const created = await ctx.client.createTurn(requestId, fakeProbeAudio(1000))
    assert.equal(created.status, 202)
    const audio = fakeProbeAudio()
    const conflict = await ctx.client.probeInject({ requestId, audioBuf: audio })
    assert.equal(conflict.status, 409)
    assert.equal(conflict.json.error, 'ERR_IDEMPOTENCY_CONFLICT')
  })

  it('rejects sha mismatch with stable code', async () => {
    const requestId = probeRid()
    const audio = fakeProbeAudio()
    const r = await ctx.client.probeInject({
      requestId, audioBuf: audio, shaOverride: 'deadbeef'.repeat(8),
    })
    assert.equal(r.status, 422)
    assert.equal(r.json.error, 'ERR_AUDIO_HASH_MISMATCH')
  })

  it('rejects empty audio with stable code', async () => {
    const emptyRid = probeRid()
    const empty = await ctx.client.probeInject({ requestId: emptyRid, audioBuf: Buffer.alloc(0) })
    assert.equal(empty.status, 422)
    assert.equal(empty.json.error, 'ERR_AUDIO_INVALID')
  })

  it('rejects oversize audio with stable code (fresh bridge with tight caps)', async () => {
    // 独立 launch：把 max_audio_bytes 收紧到 4 KiB，避免用 5+ MiB 音频撞
    // max_body_bytes（默认 8 MiB）——测的是 AUDIO_TOO_LARGE，不是 BODY_TOO_LARGE。
    const local = await launch({
      overrides: { max_audio_bytes: 4096, max_body_bytes: 65_536 },
    })
    try {
      const oversize = await local.client.probeInject({
        requestId: probeRid(),
        audioBuf: fakeProbeAudio(8192), // 8 KiB > 4 KiB cap
      })
      assert.equal(oversize.status, 413)
      assert.equal(oversize.json.error, 'ERR_AUDIO_TOO_LARGE')
    } finally {
      await local.bridge.stop(); await local.mock.stop()
    }
  })

  it('rejects missing required fields with ERR_MISSING_FIELD', async () => {
    const r = await ctx.client.raw('POST', '/v1/probe/inject', {
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ request_id: probeRid() }), // 缺 audio_base64/sha256
    })
    assert.equal(r.status, 400)
    assert.equal(r.json.error, 'ERR_MISSING_FIELD')
  })

  // === ESS-207 复审 §2 修复：接口契约集成测试（毕玄 22:04Z 阻断项） ===
  //
  // 之前的 handler 单测只断言 completed turn 的 `result.audio.kind === 'probe'`，
  // parser 单测则手工造 `kind: 'probe'` 的 fixture。两组各自绿但没有覆盖
  // **真实注入产生的 l1_audio_ready 日志**能否被 parser 认成 H1——本用例把
  // stdout 捕获的真实事件直接喂给 parseProbeHops/evaluateProbe，挡下这类
  // shape 契约漂移。
  it('real inject stdout is recognized as H1 by parseProbeHops (contract regression)', async () => {
    const requestId = probeRid()
    const audio = fakeProbeAudio()

    let injected
    const logs = await captureStdout(async () => {
      injected = await ctx.client.probeInject({ requestId, audioBuf: audio })
    })
    assert.equal(injected.status, 202)

    const l1 = logs.find(l => l.evt === 'l1_audio_ready' && l.request_id === requestId)
    assert.ok(l1, 'inject 必须落 evt=l1_audio_ready（H1 事件）')
    assert.equal(l1.kind, 'probe',
      'H1 日志必须带 kind=probe——parser 严格靠这条字段识别探针 H1，' +
      '缺了会稳定判 ERR_PROBE_STOPPED_AT_H1（毕玄 22:04Z 阻断项）')
    assert.equal(l1.sha256, injected.json.sha256)

    // 把真实日志行喂给 parser：H1 应被识别，缺 H2..H5 时报 MISSING_H2，
    // 而**不是** MISSING_H1——这是本回归测试的关键断言。
    const lines = logs.map(l => JSON.stringify(l))
    const verdict = evaluateProbe(parseProbeHops(lines, requestId))
    assert.equal(verdict.stoppedAt, 'H2',
      `真实 H1 应被识别；实际停在 ${verdict.stoppedAt}（${verdict.code}）`)
    assert.equal(verdict.code, PROBE.MISSING_H2)
  })
})

describe('ESS-207 /v1/probe/ack', () => {
  let ctx
  before(async () => { ctx = await launch() })
  after(async () => { await ctx.bridge.stop(); await ctx.mock.stop() })

  it('requires signed auth (unsigned request rejected)', async () => {
    const requestId = probeRid()
    const r = await ctx.client.raw('POST', '/v1/probe/ack', {
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ protocol_version: 1, request_id: requestId, played_ok: true }),
    })
    assert.equal(r.status, 400) // MISSING_FIELD on x-device-id
    assert.equal(r.json.error, 'ERR_MISSING_FIELD')
  })

  it('emits evt=probe_acked with sha/played_ok/error_code fields when strong checks pass', async () => {
    const requestId = probeRid()
    const audio = fakeProbeAudio()
    const injected = await ctx.client.probeInject({ requestId, audioBuf: audio })
    assert.equal(injected.status, 202)

    let ack
    const logs = await captureStdout(async () => {
      ack = await ctx.client.probeAck({
        requestId, playedOk: true, playedAtMs: 1_770_000_000_000,
        durationMs: 3500, sha256: injected.json.sha256,
      })
    })
    assert.equal(ack.status, 200, `ack failed: ${JSON.stringify(ack.json)}`)
    assert.equal(ack.json.acknowledged, true)

    const probeLog = logs.find(l => l.evt === 'probe_acked' && l.request_id === requestId)
    assert.ok(probeLog, 'evt=probe_acked 必须落 bridge.log（stdout JSONL）')
    assert.equal(probeLog.played_ok, true)
    assert.equal(probeLog.duration_ms, 3500)
    assert.equal(probeLog.sha256, injected.json.sha256)
  })

  it('carries played_ok=false and error_code through to bridge.log for failure paths', async () => {
    // played_ok=false 是合法的（Watch 侧播放失败也需要通报）——parser 只是不把
    // played_ok=false 计入 H5 PASS。sha 仍必须匹配。
    const requestId = probeRid()
    const audio = fakeProbeAudio()
    const injected = await ctx.client.probeInject({ requestId, audioBuf: audio })

    let ack
    const logs = await captureStdout(async () => {
      ack = await ctx.client.probeAck({
        requestId, playedOk: false, playedAtMs: 1_770_000_000_000,
        errorCode: 'ERR_PROBE_PLAYBACK_TRUNCATED',
        sha256: injected.json.sha256,
      })
    })
    assert.equal(ack.status, 200)

    const probeLog = logs.find(l => l.evt === 'probe_acked' && l.request_id === requestId)
    assert.ok(probeLog)
    assert.equal(probeLog.played_ok, false)
    assert.equal(probeLog.error_code, 'ERR_PROBE_PLAYBACK_TRUNCATED')
  })

  // === ESS-207 复审 §2：强校验负例（伪造 H5 的四条路径） ===

  it('rejects ack for unknown request_id (H5 forging: attacker guesses a rid)', async () => {
    const logs = await captureStdout(async () => {
      const r = await ctx.client.probeAck({
        requestId: probeRid(), playedOk: true, playedAtMs: 0,
        sha256: 'ab'.repeat(32),
      })
      assert.equal(r.status, 404)
      assert.equal(r.json.error, 'ERR_NOT_FOUND')
    })
    assert.equal(
      logs.filter(l => l.evt === 'probe_acked').length, 0,
      '拒收的 ack 绝不能落 probe_acked——落了就等于伪造攻击得逞'
    )
  })

  it('rejects ack for a non-probe (production) turn — cross-chain confusion blocked', async () => {
    const requestId = 'req_' + crypto.randomUUID().replaceAll('-', '')
    await ctx.client.createTurn(requestId, fakeProbeAudio(1000))
    const logs = await captureStdout(async () => {
      const r = await ctx.client.probeAck({
        requestId, playedOk: true, playedAtMs: 0, sha256: 'cd'.repeat(32),
      })
      assert.equal(r.status, 404)
      assert.equal(r.json.error, 'ERR_NOT_FOUND')
    })
    assert.equal(logs.filter(l => l.evt === 'probe_acked').length, 0)
  })

  it('rejects ack when device does not own the probe turn', async () => {
    // 同 bridge 上「另一台设备」用未知/伪造 device_id 走 signed HMAC，会被
    // 更上层的 auth.verify 直接以 DEVICE_UNKNOWN 挡下——这是设备归属校验的
    // 最外层防线；true multi-device 归属（同 bridge 两台已配对设备）留待
    // 复合场景 e2e 覆盖。
    const requestId = probeRid()
    const audio = fakeProbeAudio()
    const injected = await ctx.client.probeInject({ requestId, audioBuf: audio })
    assert.equal(injected.status, 202)

    const logs = await captureStdout(async () => {
      const stranger = new BridgeClient({
        baseUrl: ctx.baseUrl, deviceId: 'dev_alien', token: 'aa'.repeat(32),
      })
      const r = await stranger.probeAck({
        requestId, playedOk: true, playedAtMs: 0, sha256: injected.json.sha256,
      })
      assert.equal(r.status, 401, `expected DEVICE_UNKNOWN, got: ${JSON.stringify(r.json)}`)
      assert.equal(r.json.error, 'ERR_DEVICE_UNKNOWN')
    })
    assert.equal(logs.filter(l => l.evt === 'probe_acked').length, 0)
  })

  it('rejects ack whose sha does not match the injected audio (bit-for-bit playback contract)', async () => {
    const requestId = probeRid()
    const audio = fakeProbeAudio()
    await ctx.client.probeInject({ requestId, audioBuf: audio })

    const logs = await captureStdout(async () => {
      const r = await ctx.client.probeAck({
        requestId, playedOk: true, playedAtMs: 0,
        sha256: 'de'.repeat(32),   // 与注入不同
      })
      assert.equal(r.status, 422)
      assert.equal(r.json.error, 'ERR_AUDIO_HASH_MISMATCH')
    })
    assert.equal(logs.filter(l => l.evt === 'probe_acked').length, 0)
  })

  it('rejects ack missing sha256 field entirely', async () => {
    const requestId = probeRid()
    await ctx.client.probeInject({ requestId, audioBuf: fakeProbeAudio() })

    const r = await ctx.client.signed('POST', '/v1/probe/ack', {
      requestId,
      json: { protocol_version: 1, request_id: requestId, played_ok: true, played_at_ms: 0 },
    })
    assert.equal(r.status, 422)
    assert.equal(r.json.error, 'ERR_AUDIO_HASH_MISMATCH')
  })
})
