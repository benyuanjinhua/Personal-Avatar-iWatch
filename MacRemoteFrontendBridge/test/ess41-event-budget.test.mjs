// ESS-41 回归：
// B1 — taskwatch 事件预算与 Realtime 观测计数分账。ESS-37 让 Realtime 逐字
//      delta 流喂同一个 event_count，一轮正常语音就烧穿 max_turn_events，
//      后台任务的第一条 SSE 事件即触发 501 熔断、健康任务被误杀
//      （真机取证 5d8a489b：event_budget_exhausted count=501 → ERR_EVENT_LIMIT）。
// B2 — 空/误触音频（真机取证 3411d607：1920 bytes ≈60ms 尾部静音）必须在
//      注入前快速失败 ERR_AUDIO_TOO_SHORT，不进停摆重放/会话重建机器。

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

const TMP = mkdtempSync(join(tmpdir(), 'bridge-ess41-'))
const CERT = join(TMP, 'bridge.crt')
const KEY = join(TMP, 'bridge.key')
execFileSync('openssl', [
  'req', '-x509', '-newkey', 'rsa:2048', '-keyout', KEY, '-out', CERT,
  '-days', '1', '-nodes', '-subj', '/CN=127.0.0.1',
], { stdio: 'ignore' })

let stateSeq = 0

async function launch({ scenario = 'direct', overrides = {} } = {}) {
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
    turn_timeout_ms: 60_000,
    sse_backoff_base_ms: 200,
    sse_backoff_max_ms: 1000,
    ...overrides,
  })
  const [server] = await bridge.start()
  const client = new BridgeClient({ baseUrl: `https://127.0.0.1:${server.address().port}` })
  const pairingCode = readFileSync(join(stateDir, 'pairing-code.txt'), 'utf8').trim()
  await client.pair(pairingCode)
  return { mock, bridge, client }
}

const noisePcm = (ms = 400) => {
  const buf = Buffer.alloc(Math.round(16000 * ms / 1000) * 2)
  crypto.randomFillSync(buf)
  return buf
}
const rid = () => 'req_' + crypto.randomUUID().replaceAll('-', '')

describe('ESS-41 B1: realtime observability must not feed the taskwatch breaker', () => {
  let ctx
  before(async () => { ctx = await launch({ scenario: 'background', overrides: { max_turn_events: 3 } }) })
  after(async () => { await ctx.bridge.stop(); await ctx.mock.stop() })

  it('background task survives a budget already burned by realtime deltas', async () => {
    const id = rid()
    await ctx.client.createTurn(id, noisePcm())
    await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

    // 复刻真机前提：Realtime 阶段的观测计数已超预算（真机是数百条逐字/
    // 音频 delta 烧穿 500，这里 mock 的 4+ 条事件烧穿 3）。
    const turn = ctx.bridge.ledger.get(id)
    assert.ok(turn.event_count > 3, `realtime must have inflated event_count, got ${turn.event_count}`)

    // 修复前：第一条 SSE 事件即 count>budget → 取消任务 + ERR_EVENT_LIMIT。
    // 修复后：SSE/task 事件单独计数，健康任务正常走到 completed。
    ctx.mock.emitTask('task.progress', { ...ctx.mock.tasks.get('task_bg'), status: 'running' })
    ctx.mock.emitTask('task.completed', {
      ...ctx.mock.tasks.get('task_bg'),
      status: 'completed',
      resultMetadata: { presentation: { speech: '日志分析完成。' } },
    })
    const done = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'completed' ? r.json : null
    })
    assert.equal(done.result.text, '日志分析完成。')
    assert.notEqual(done.error, 'ERR_EVENT_LIMIT')
    assert.ok(!ctx.mock.deleteCalls.includes('task_bg'), 'a healthy task must never be cancelled by the breaker')
  })

  it('task-event budget exhaustion degrades projection but never cancels the task', async () => {
    ctx.mock.tasks.delete('task_bg')
    ctx.mock.deleteCalls.length = 0
    const id = rid()
    await ctx.client.createTurn(id, noisePcm())
    await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')
    // SSE 订阅就绪的标志：snapshot 事件已入账
    await waitFor(() => (ctx.bridge.ledger.get(id).task_event_count || 0) >= 1)

    // 喂超预算的 SSE 进度噪声（预算 3），再收终态：降级只丢噪声投影，
    // 终态转折点必须照常投影，任务绝不被取消。
    for (let i = 0; i < 10; i++) {
      ctx.mock.emitTask('task.progress', { ...ctx.mock.tasks.get('task_bg'), status: 'running' })
    }
    ctx.mock.emitTask('task.completed', {
      ...ctx.mock.tasks.get('task_bg'),
      status: 'completed',
      resultMetadata: { presentation: { speech: '超长任务也能交付。' } },
    })
    const done = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'completed' ? r.json : null
    })
    assert.equal(done.result.text, '超长任务也能交付。')
    assert.ok(ctx.bridge.ledger.get(id).task_event_count > 3, 'budget must actually have been exceeded in this test')
    assert.ok(!ctx.mock.deleteCalls.includes('task_bg'), 'budget exhaustion must degrade, not cancel')
  })
})

describe('ESS-41 B2: empty/mis-touch audio fails fast before injection', () => {
  let ctx
  before(async () => { ctx = await launch({ scenario: 'direct' }) }) // 默认 min_audio_ms=300 / min_audio_rms=100
  after(async () => { await ctx.bridge.stop(); await ctx.mock.stop() })

  it('60ms tail-silence (真机 1920 bytes 取证同款) → ERR_AUDIO_TOO_SHORT within 2s, no injection', async () => {
    const id = rid()
    const t0 = Date.now()
    await ctx.client.createTurn(id, Buffer.alloc(1920)) // 60ms @16k, 全静音
    const failed = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'failed' ? r.json : null
    })
    assert.equal(failed.error, 'ERR_AUDIO_TOO_SHORT')
    assert.ok(Date.now() - t0 < 2000, 'must fail fast, not run the stall machine')
    assert.equal(ctx.mock.realtimeTurns, 0, 'short audio must never reach realtime injection')
  })

  it('long-enough but pure-silence audio → ERR_AUDIO_TOO_SHORT (energy floor)', async () => {
    const id = rid()
    await ctx.client.createTurn(id, Buffer.alloc(16000)) // 500ms @16k, RMS=0
    const failed = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'failed' ? r.json : null
    })
    assert.equal(failed.error, 'ERR_AUDIO_TOO_SHORT')
    assert.equal(ctx.mock.realtimeTurns, 0)
  })

  it('normal-length voiced audio still goes through and completes', async () => {
    const id = rid()
    await ctx.client.createTurn(id, noisePcm(400))
    const done = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'completed' ? r.json : null
    })
    assert.equal(done.result.text, '现在是上午九点。')
  })
})
