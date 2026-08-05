// ESS-243 tests-only follow-up：PR #85（`realtimeAudioSalvage` /
// `armRealtimeFallbackTimer` / `synthesizeRealtimeFallback` / `realtime_fallback_wait_ms`）
// 已合入 main（`0933fbd`），本文件补覆盖 E2E 用例——PR #85 body 明确该 impl
// 无新 E2E，转子单跟进。
//
// 覆盖：
// - 正常 announcement 到达 → 不触发兜底
// - task.completed 后窗口过期无 announcement → 触发合成、result 音频落位、
//   `result_synthesized_from_realtime` + `l1_audio_ready source=realtime_fallback`
//
// 未覆盖（另有跟进项，见 ESS-243 上的 findings 评论）：
// - 合成后 announcement 迟到：**当前行为是磁盘/元数据被覆盖**，与 PR #85 body
//   的「幂等分支跳过」claim 不一致——`attachPendingResultAudio` 只 gate 了
//   `turn.state !== 'completed'`，没检查 `turn.result?.audio`；也没在
//   `bindAnnouncement` 入口早退。写单前不把 buggy 现状锁进测试。
// - 空 audio24k：当前行为是 salvage 从未入表（`if (result.audio24k?.length)`
//   guard），armRealtimeFallbackTimer 又 gate 了 `!realtimeAudioSalvage.has()`，
//   因此**没有诊断事件**——`realtime_fallback_skipped reason=empty_pcm24k` 实际
//   永远不落。设计层面是可观测性缺口，不是"应有 diag 却漏发"，写单前不把
//   缺口锁进测试。

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
    // 单测里压到 200ms，避免每个用例卡 5s 真等；生产默认仍是 5000ms
    realtime_fallback_wait_ms: 200,
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
    const ctx = await launch({ overrides: { realtime_fallback_wait_ms: 1500 } })
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm16())
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

      // announcement 先到位（真实的"结果语音"，1s @ 24kHz = 48000 bytes）
      const annPcm = Buffer.alloc(48_000, 5)
      ctx.mock.announce({ taskId: 'task_bg', transcript: '正常回复。', pcm: annPcm })
      // Realtime WS + SSE 两条通道都发 task.completed，与真机一致（Gateway
      // 侧完工两个通道会同步）。Realtime 通道触发 armRealtimeFallbackTimer，
      // SSE 通道触发 TaskWatcher.projectTask → ledger.setResult(completed)。
      ctx.mock.pushTaskEvent('task.completed', {
        ...ctx.mock.tasks.get('task_bg'),
        status: 'completed',
        resultMetadata: { presentation: { speech: '任务完成。' } },
      })
      ctx.mock.emitTask('task.completed', {
        ...ctx.mock.tasks.get('task_bg'),
        status: 'completed',
        resultMetadata: { presentation: { speech: '任务完成。' } },
      })

      const done = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.status === 'completed' && r.json.result?.audio ? r.json : null
      })
      assert.equal(
        done.result.audio.duration_ms, 1000,
        'announcement 音频应先到位（1s），非兜底合成的 200ms interim'
      )

      // 兜底窗口再多留一会儿，确保不会在无 announcement 场景之外被触发
      await sleep(400)
      const synthesized = cap.lines.filter(l =>
        l.evt === 'result_synthesized_from_realtime' && l.request_id === id)
      assert.equal(synthesized.length, 0, '正常路径下兜底不得触发')
      // 稳定性：不该出现兜底相关的 skip/encode fail 事件
      const fallbackNoise = cap.lines.filter(l =>
        ['realtime_fallback_skipped', 'realtime_fallback_encode_failed', 'realtime_fallback_error']
          .includes(l.evt) && l.request_id === id)
      assert.equal(fallbackNoise.length, 0)
    } finally {
      await ctx.bridge.stop(); await ctx.mock.stop(); cap.restore()
    }
  })

  it('synthesizes final result from realtime salvage when no announcement arrives', async () => {
    const cap = captureStdout()
    const ctx = await launch()
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm16())
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

      // 关键：Realtime WS 通道下发 task.completed → armRealtimeFallbackTimer
      // 起 5s 窗（本测试压到 200ms）。SSE 通道也同步下发，让 TaskWatcher
      // 把 turn 推到 completed 状态（synthesizeRealtimeFallback 内部会走
      // attachPendingResultAudio，那里要求 turn.state === 'completed'）。
      ctx.mock.pushTaskEvent('task.completed', {
        ...ctx.mock.tasks.get('task_bg'),
        status: 'completed',
        resultMetadata: { presentation: { speech: '文字先到，音频没到。' } },
      })
      ctx.mock.emitTask('task.completed', {
        ...ctx.mock.tasks.get('task_bg'),
        status: 'completed',
        resultMetadata: { presentation: { speech: '文字先到，音频没到。' } },
      })
      // 不发 announce()——就是 ESS-234 现场描述的 Gateway 侧不补发 announcement 的必现路径

      // 先确认文本 completed 已投影，且暂无音频（兜底还没跑）
      const textOnly = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.status === 'completed' ? r.json : null
      })
      assert.equal(textOnly.result.text, '文字先到，音频没到。')

      // 窗口过期 → 兜底合成 → 音频落位
      const done = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.result?.audio ? r.json : null
      })
      assert.equal(done.result.text, '文字先到，音频没到。', 'text 被保留')
      const meta = done.result.audio
      assert.equal(meta.codec, 'm4a')
      // background 场景注入阶段 mock 发了 9600 bytes = 200ms 的 24k PCM
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
      assert.equal(synthesized.cause, 'task.completed', 'cause 是触发 armRealtimeFallbackTimer 的原因')
      assert.equal(synthesized.task_id, 'task_bg')
      assert.equal(synthesized.pcm_bytes, 9600)
      const ready = cap.lines.find(l =>
        l.evt === 'l1_audio_ready' && l.request_id === id && l.source === 'realtime_fallback')
      assert.ok(ready, 'must log l1_audio_ready with realtime_fallback source')
    } finally {
      await ctx.bridge.stop(); await ctx.mock.stop(); cap.restore()
    }
  })
})
