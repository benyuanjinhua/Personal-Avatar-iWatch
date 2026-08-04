// ESS-234 方案 B 验收：Bridge 侧 task.completed 后短窗口无 announcement 时，
// 从 realtime 阶段暂存的 24kHz PCM 兜底合成 final result m4a，让 turn 达终态。
//
// 覆盖：
// - 正常 announcement 到达 → 不触发兜底（无 result_synthesized_from_realtime）
// - task.completed 后窗口过期无 announcement → 触发合成 + result 音频落位 +
//   result_synthesized_from_realtime 事件 + l1_audio_ready source=realtime_fallback
// - 合成后 announcement 迟到 → bindAnnouncement 幂等分支跳过，元数据/文件不变
// - 空 audio24k（background-no-ack 场景）→ 不合成，落 realtime_fallback_skipped
//   诊断事件，reason=empty_realtime_audio

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createBridge } from '../server.mjs'
import { MockGateway } from './mock-gateway.mjs'
import { BridgeClient, waitFor } from './client.mjs'

const TMP = mkdtempSync(join(tmpdir(), 'bridge-ess234-'))
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
    // 窗口值：单测里压到 200ms，避免每个用例卡 5s 真等；生产默认仍是 5000ms
    realtime_fallback_delay_ms: 200,
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

const FAKE_PREFIX = Buffer.from('FAKEM4A0')

// bridge.log 即 stdout：拦截并按行解析 JSON，用于断言事件与否
function captureStdout() {
  const lines = []
  const original = process.stdout.write.bind(process.stdout)
  process.stdout.write = chunk => {
    for (const line of String(chunk).split('\n')) {
      if (!line.trim()) continue
      try { lines.push(JSON.parse(line)) } catch { /* 非 JSON 行忽略 */ }
    }
    return original(chunk)
  }
  return { lines, restore: () => { process.stdout.write = original } }
}

const sleep = ms => new Promise(r => setTimeout(r, ms))

describe('ESS-234 realtime fallback', () => {
  it('does not synthesize when the announcement arrives in the normal path', async () => {
    const cap = captureStdout()
    // announcement 编码是异步 subprocess，会跟兜底定时器抢；给出充裕的窗口
    // 确保正常路径下 announcement 稳定先到位（生产默认 5s 更宽松）。
    const ctx = await launch({ overrides: { realtime_fallback_delay_ms: 1500 } })
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm16())
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

      // announcement 先到位（真实的\"结果语音\"）
      const annPcm = Buffer.alloc(48_000, 5) // 1s @ 24kHz
      ctx.mock.announce({ taskId: 'task_bg', transcript: '正常回复。', pcm: annPcm })
      ctx.mock.emitTask('task.completed', {
        ...ctx.mock.tasks.get('task_bg'),
        status: 'completed',
        resultMetadata: { presentation: { speech: '任务完成。' } },
      })

      const done = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.status === 'completed' && r.json.result?.audio ? r.json : null
      })
      assert.equal(done.result.audio.duration_ms, 1000, 'announcement audio should be attached, not the realtime 200ms')

      // 兜底窗口再多留一会儿，确保不会在无 announcement 场景之外被触发
      await sleep(400)
      const synthesized = cap.lines.filter(l =>
        l.evt === 'result_synthesized_from_realtime' && l.request_id === id)
      assert.equal(synthesized.length, 0, 'fallback must not fire when announcement bound normally')
      // 稳定性：不该出现兜底相关的 skip/encode fail 事件
      const fallbackNoise = cap.lines.filter(l =>
        ['realtime_fallback_skipped', 'realtime_fallback_encode_failed', 'realtime_fallback_crashed']
          .includes(l.evt) && l.request_id === id)
      assert.equal(fallbackNoise.length, 0)
    } finally {
      await ctx.bridge.stop(); await ctx.mock.stop(); cap.restore()
    }
  })

  it('synthesizes final result from realtime audio when no announcement arrives', async () => {
    const cap = captureStdout()
    const ctx = await launch()
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm16())
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

      ctx.mock.emitTask('task.completed', {
        ...ctx.mock.tasks.get('task_bg'),
        status: 'completed',
        resultMetadata: { presentation: { speech: '文字先到，音频没到。' } },
      })
      // 先确认文本 completed 已投影，且无音频（announcement 从未发）
      const textOnly = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.status === 'completed' ? r.json : null
      })
      assert.equal(textOnly.result.text, '文字先到，音频没到。')
      assert.ok(!textOnly.result.audio, 'no audio before fallback fires')

      // 窗口过期 → 兜底合成
      const done = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.result?.audio ? r.json : null
      })
      assert.equal(done.result.text, '文字先到，音频没到。', 'text is preserved')
      const meta = done.result.audio
      assert.equal(meta.codec, 'm4a')
      // background 场景的注入阶段 mock 发了 9600 bytes = 200ms 的 24k PCM
      assert.equal(meta.duration_ms, 200)
      assert.equal(meta.size_bytes, 9600 + FAKE_PREFIX.length)
      // inline base64 应可用，sha256 一致
      const inline = Buffer.from(done.result.audio_base64, 'base64')
      assert.equal(crypto.createHash('sha256').update(inline).digest('hex'), meta.sha256)

      // 下载端点：磁盘文件与元数据 sha256 一致
      const full = await ctx.client.downloadAudio(id)
      assert.equal(full.status, 200)
      assert.equal(crypto.createHash('sha256').update(full.body).digest('hex'), meta.sha256)

      // 关键取证事件（R-02.1 运行时证据口径）
      const synthesized = cap.lines.find(l =>
        l.evt === 'result_synthesized_from_realtime' && l.request_id === id)
      assert.ok(synthesized, 'must log result_synthesized_from_realtime')
      assert.equal(synthesized.cause, 'announcement_missing_after_task_completed')
      assert.equal(synthesized.task_id, 'task_bg')
      assert.equal(synthesized.pcm_bytes, 9600)
      const ready = cap.lines.find(l =>
        l.evt === 'l1_audio_ready' && l.request_id === id && l.source === 'realtime_fallback')
      assert.ok(ready, 'must log l1_audio_ready with realtime_fallback source')
    } finally {
      await ctx.bridge.stop(); await ctx.mock.stop(); cap.restore()
    }
  })

  it('idempotently skips a late announcement after fallback already attached audio', async () => {
    const cap = captureStdout()
    const ctx = await launch()
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm16())
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

      ctx.mock.emitTask('task.completed', {
        ...ctx.mock.tasks.get('task_bg'),
        status: 'completed',
        resultMetadata: { presentation: { speech: '完成。' } },
      })
      const withFallback = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.result?.audio ? r.json : null
      })
      const fallbackMeta = withFallback.result.audio
      const fallbackBody = (await ctx.client.downloadAudio(id)).body

      // 迟到的 announcement 到达（真实结果音频，1 秒长）——按幂等规则必须
      // 被跳过，磁盘文件与元数据不变。
      const latePcm = Buffer.alloc(48_000, 8)
      ctx.mock.announce({ taskId: 'task_bg', transcript: '迟到的正版回复。', pcm: latePcm })
      await sleep(200) // 让 announcement.finished 走完聚合与 bindAnnouncement

      const after = (await ctx.client.getTurn(id)).json
      assert.equal(after.result.audio.sha256, fallbackMeta.sha256, 'metadata sha256 unchanged')
      assert.equal(after.result.audio.duration_ms, fallbackMeta.duration_ms, 'duration unchanged')
      assert.ok(!after.result.speech_text, 'late transcript must not be grafted on')
      const afterBody = (await ctx.client.downloadAudio(id)).body
      assert.deepEqual(afterBody, fallbackBody, 'on-disk m4a untouched by late announcement')

      // 取证事件
      const skipped = cap.lines.find(l =>
        l.evt === 'announcement_skipped_idempotent' && l.request_id === id)
      assert.ok(skipped, 'must log announcement_skipped_idempotent')
      assert.equal(skipped.reason, 'result_audio_already_attached')
      // 迟到的 announcement 不能触发第二条 result_audio_attached
      const attached = cap.lines.filter(l =>
        l.evt === 'result_audio_attached' && l.request_id === id)
      assert.equal(attached.length, 0, 'attach path must be short-circuited before the second re-projection')
    } finally {
      await ctx.bridge.stop(); await ctx.mock.stop(); cap.restore()
    }
  })

  it('falls back with a diagnostic event and does not fabricate audio when audio24k is empty', async () => {
    const cap = captureStdout()
    const ctx = await launch({ scenario: 'background-no-ack' })
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm16())
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

      ctx.mock.emitTask('task.completed', {
        ...ctx.mock.tasks.get('task_bg'),
        status: 'completed',
        resultMetadata: { presentation: { speech: '完成但无音源。' } },
      })

      // 窗口过期
      await sleep(400)
      const after = (await ctx.client.getTurn(id)).json
      assert.equal(after.status, 'completed')
      assert.equal(after.result.text, '完成但无音源。')
      assert.ok(!after.result.audio, 'must not fabricate audio when there is no realtime PCM to synthesize from')

      const skipped = cap.lines.find(l =>
        l.evt === 'realtime_fallback_skipped' && l.request_id === id)
      assert.ok(skipped, 'must log realtime_fallback_skipped diagnostic')
      assert.equal(skipped.reason, 'empty_realtime_audio')
      assert.equal(skipped.task_id, 'task_bg')
    } finally {
      await ctx.bridge.stop(); await ctx.mock.stop(); cap.restore()
    }
  })
})
