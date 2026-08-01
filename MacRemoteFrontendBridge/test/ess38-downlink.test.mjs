// ESS-38 验收：Qwen Audio Realtime 后台任务播报（origin=announcement）的
// 下行归属、文本+语音聚合、有界转码与北向取回。
//
// 覆盖：
// - announcement 在 task 终态之后到达 → 先文本投影、后补挂语音（二次
//   turn.state 事件），元数据（sha256/codec/duration/size）齐全；
// - announcement 先于 task 终态到达 → completed 投影直接携带语音；
// - taskId 无法归属 → 不绑定、不 crash、无关 turn 不受影响；
// - GET /v1/voice/turns/:id/audio：签名鉴权、设备归属、Range 断点续传、
//   sha256 一致性；
// - 聚合上限截断（max_announcement_pcm_bytes）；
// - direct 路径同样落文件 + 元数据。

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

const TMP = mkdtempSync(join(tmpdir(), 'bridge-ess38-'))
const CERT = join(TMP, 'bridge.crt')
const KEY = join(TMP, 'bridge.key')
execFileSync('openssl', [
  'req', '-x509', '-newkey', 'rsa:2048', '-keyout', KEY, '-out', CERT,
  '-days', '1', '-nodes', '-subj', '/CN=127.0.0.1',
], { stdio: 'ignore' })

let stateSeq = 0

async function launch({ scenario = 'background', overrides = {} } = {}) {
  const mock = new MockGateway({ scenario })
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
    turn_timeout_ms: 60_000,
    sse_backoff_base_ms: 200,
    sse_backoff_max_ms: 1000,
    ...overrides,
  })
  const [server] = await bridge.start()
  const baseUrl = `https://127.0.0.1:${server.address().port}`
  const client = new BridgeClient({ baseUrl })
  const pairingCode = readFileSync(join(stateDir, 'pairing-code.txt'), 'utf8').trim()
  const paired = await client.pair(pairingCode)
  assert.equal(paired.status, 201)
  return { mock, bridge, client, baseUrl, stateDir }
}

const pcm16 = (ms = 400) => {
  const buf = Buffer.alloc(Math.round(16000 * ms / 1000) * 2)
  crypto.randomFillSync(buf)
  return buf
}
const rid = () => 'req_' + crypto.randomUUID().replaceAll('-', '')

// fake-audiopipe 的 encode 输出：8 字节前缀 + PCM 原样
const FAKE_PREFIX = Buffer.from('FAKEM4A0')

describe('ESS-38 announcement downlink (background path)', () => {
  let ctx
  before(async () => { ctx = await launch() })
  after(async () => { await ctx.bridge.stop(); await ctx.mock.stop() })

  it('binds a late announcement to the completed turn: text first, audio patched after', async () => {
    const events = ctx.client.events()
    await waitFor(() => events.received.some(e => e.type === 'snapshot'))

    const id = rid()
    await ctx.client.createTurn(id, pcm16())
    await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

    ctx.mock.emitTask('task.completed', {
      ...ctx.mock.tasks.get('task_bg'),
      status: 'completed',
      resultMetadata: { presentation: { speech: '文件整理完成。' } },
    })
    const textFirst = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'completed' ? r.json : null
    })
    assert.equal(textFirst.result.text, '文件整理完成。')
    assert.ok(!textFirst.result.audio, 'audio must not be fabricated before the announcement arrives')

    // Realtime 播报姗姗来迟（1 秒 24kHz PCM）
    const annPcm = Buffer.alloc(48_000, 5)
    ctx.mock.announce({ taskId: 'task_bg', transcript: '都办妥了，放心。', pcm: annPcm })

    const withAudio = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.result?.audio ? r.json : null
    })
    const meta = withAudio.result.audio
    assert.equal(meta.codec, 'm4a')
    assert.equal(meta.duration_ms, 1000)
    assert.equal(meta.size_bytes, annPcm.length + FAKE_PREFIX.length)
    assert.equal(withAudio.result.speech_text, '都办妥了，放心。')
    assert.equal(withAudio.result.text, '文件整理完成。', 'task presentation text must survive the audio patch')

    // inline base64 在上限内 → 直接可用且 sha 一致
    const inline = Buffer.from(withAudio.result.audio_base64, 'base64')
    assert.equal(sha256hex(inline), meta.sha256)
    assert.ok(inline.subarray(0, 8).equals(FAKE_PREFIX))

    // WSS：第一条 completed 无音频，补挂后出现第二条带音频的 completed
    await waitFor(() => events.received.some(e =>
      e.type === 'turn.state' && e.turn.request_id === id && e.turn.result?.audio))
    const completedEvents = events.received
      .filter(e => e.type === 'turn.state' && e.turn.request_id === id && e.turn.status === 'completed')
    assert.ok(!completedEvents[0].turn.result.audio, 'first completed projection is text-only')
    assert.ok(completedEvents.at(-1).turn.result.audio, 'audio patch re-projects the completed turn')
    events.ws.close()

    // 下载端点：全量 + sha 头
    const full = await ctx.client.downloadAudio(id)
    assert.equal(full.status, 200)
    assert.equal(full.headers['x-audio-sha256'], meta.sha256)
    assert.equal(sha256hex(full.body), meta.sha256)

    // Range 断点续传：前 8 字节 + 其余分两段取回，拼接与全量一致
    const head = await ctx.client.downloadAudio(id, { range: 'bytes=0-7' })
    assert.equal(head.status, 206)
    assert.equal(head.headers['content-range'], `bytes 0-7/${meta.size_bytes}`)
    const rest = await ctx.client.downloadAudio(id, { range: 'bytes=8-' })
    assert.equal(rest.status, 206)
    assert.equal(sha256hex(Buffer.concat([head.body, rest.body])), meta.sha256)

    // 非法 Range → 416
    const bad = await ctx.client.downloadAudio(id, { range: `bytes=${meta.size_bytes + 10}-` })
    assert.equal(bad.status, 416)
  })

  it('emits one text+audio interim before the background state projection', async () => {
    const isolated = await launch()
    try {
      const events = isolated.client.events()
      await waitFor(() => events.received.some(e => e.type === 'snapshot'))
      const id = rid()
      await isolated.client.createTurn(id, pcm16())
      const interim = await waitFor(() => events.received.find(
        e => e.type === 'turn.interim' && e.interim?.request_id === id))
      assert.equal(interim.interim.delivery_sequence, 1)
      assert.equal(interim.interim.text, '收到，正在处理，请稍后')
      assert.equal(interim.interim.audio.codec, 'm4a')
      assert.ok(Buffer.from(interim.interim.audio.base64, 'base64').subarray(0, 8).equals(FAKE_PREFIX))
      assert.equal(events.received.filter(
        e => e.type === 'turn.interim' && e.interim?.request_id === id).length, 1)
    } finally {
      await isolated.bridge.stop()
      await isolated.mock.stop()
    }
  })

  it('uses fixed text and pre-generated speech when realtime delegates without an acknowledgement', async () => {
    const isolated = await launch({ scenario: 'background-no-ack' })
    try {
      const events = isolated.client.events()
      await waitFor(() => events.received.some(e => e.type === 'snapshot'))
      const id = rid()
      await isolated.client.createTurn(id, pcm16())
      const interim = await waitFor(() => events.received.find(
        e => e.type === 'turn.interim' && e.interim?.request_id === id))
      assert.equal(interim.interim.text, '收到，正在处理，请稍后')
      assert.equal(interim.interim.audio.codec, 'm4a')
      assert.ok(Buffer.from(interim.interim.audio.base64, 'base64').length > 1000)
    } finally {
      await isolated.bridge.stop()
      await isolated.mock.stop()
    }
  })

  it('binds an early announcement: completed projection carries the audio immediately', async () => {
    ctx.mock.tasks.delete('task_bg')
    const id = rid()
    await ctx.client.createTurn(id, pcm16())
    await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

    const annPcm = Buffer.alloc(24_000, 9) // 500ms
    ctx.mock.announce({ taskId: 'task_bg', transcript: '搞定啦。', pcm: annPcm })
    // 播报已聚合但 turn 未终态：结果里不得提前出现音频
    await new Promise(r => setTimeout(r, 300))
    assert.notEqual((await ctx.client.getTurn(id)).json.status, 'completed')

    ctx.mock.emitTask('task.completed', {
      ...ctx.mock.tasks.get('task_bg'),
      status: 'completed',
      resultMetadata: { presentation: { speech: '已完成。' } },
    })
    const done = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'completed' && r.json.result?.audio ? r.json : null
    })
    assert.equal(done.result.audio.duration_ms, 500)
    assert.equal(done.result.speech_text, '搞定啦。')
    const full = await ctx.client.downloadAudio(id)
    assert.equal(full.status, 200)
    assert.equal(sha256hex(full.body), done.result.audio.sha256)
  })

  it('leaves unmatched announcements unbound and other turns untouched', async () => {
    ctx.mock.tasks.delete('task_bg')
    const id = rid()
    await ctx.client.createTurn(id, pcm16())
    await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

    ctx.mock.announce({ taskId: 'task_someone_elses', transcript: '别人的任务。', pcm: Buffer.alloc(2400, 1) })
    ctx.mock.emitTask('task.completed', {
      ...ctx.mock.tasks.get('task_bg'),
      status: 'completed',
      resultMetadata: { presentation: { speech: '本任务完成。' } },
    })
    const done = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'completed' ? r.json : null
    })
    await new Promise(r => setTimeout(r, 300))
    const after = (await ctx.client.getTurn(id)).json
    assert.equal(after.result.text, '本任务完成。')
    assert.ok(!after.result.audio, 'someone else\'s announcement must not attach here')
    assert.ok(!after.result.speech_text)
    // 无归属播报也不能把文件写进结果仓
    const download = await ctx.client.downloadAudio(id)
    assert.equal(download.status, 404)
  })

  it('rejects audio download for a foreign device and unknown turns', async () => {
    const stranger = new BridgeClient({
      baseUrl: ctx.baseUrl, deviceId: 'dev_nope', token: 'aa'.repeat(32),
    })
    const foreign = await stranger.downloadAudio('whatever')
    assert.equal(foreign.status, 401)
    const missing = await ctx.client.downloadAudio('req_never_existed')
    assert.equal(missing.status, 404)
  })
})

describe('ESS-38 announcement aggregation cap', () => {
  it('truncates oversized announcements instead of dropping them', async () => {
    const ctx = await launch({ overrides: { max_announcement_pcm_bytes: 9600 } })
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm16())
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')
      ctx.mock.emitTask('task.completed', {
        ...ctx.mock.tasks.get('task_bg'),
        status: 'completed',
        resultMetadata: { presentation: { speech: '完成。' } },
      })
      await waitFor(async () => (await ctx.client.getTurn(id)).json.status === 'completed')

      ctx.mock.announce({ taskId: 'task_bg', transcript: '很长的播报。', pcm: Buffer.alloc(48_000, 2) })
      const done = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.result?.audio ? r.json : null
      })
      assert.equal(done.result.audio.truncated, true)
      assert.equal(done.result.audio.duration_ms, 200) // 9600 bytes @ 48 bytes/ms
      assert.equal(done.result.audio.size_bytes, 9600 + FAKE_PREFIX.length)
    } finally {
      await ctx.bridge.stop(); await ctx.mock.stop()
    }
  })
})

describe('ESS-38 direct path stores file + metadata too', () => {
  it('direct answer exposes audio metadata and the download endpoint', async () => {
    const ctx = await launch({ scenario: 'direct' })
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm16())
      const done = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.status === 'completed' ? r.json : null
      })
      assert.equal(done.path, 'direct')
      assert.ok(done.result.audio, 'direct path must carry audio metadata')
      assert.equal(done.result.audio.codec, 'm4a')
      const full = await ctx.client.downloadAudio(id)
      assert.equal(full.status, 200)
      assert.equal(sha256hex(full.body), done.result.audio.sha256)
      const inline = Buffer.from(done.result.audio_base64, 'base64')
      assert.equal(sha256hex(inline), done.result.audio.sha256)
    } finally {
      await ctx.bridge.stop(); await ctx.mock.stop()
    }
  })
})
