// ESS-26 acceptance tests: auth, idempotency, lifecycle, timeout, permission,
// cancel, WSS events, defensive parsing, restart recovery — against the mock
// gateway (real-gateway E2E lives in test/e2e-real.mjs).

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import crypto from 'node:crypto'
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createBridge } from '../server.mjs'
import { GatewayClient } from '../gateway.mjs'
import { MockGateway } from './mock-gateway.mjs'
import { BridgeClient, waitFor } from './client.mjs'

const TMP = mkdtempSync(join(tmpdir(), 'bridge-test-'))
const CERT = join(TMP, 'bridge.crt')
const KEY = join(TMP, 'bridge.key')
execFileSync('openssl', [
  'req', '-x509', '-newkey', 'rsa:2048', '-keyout', KEY, '-out', CERT,
  '-days', '1', '-nodes', '-subj', '/CN=127.0.0.1',
], { stdio: 'ignore' })

let stateSeq = 0

async function launch({ scenario = 'direct', overrides = {}, stateDir = null } = {}) {
  const mock = new MockGateway({ scenario })
  const gatewayUrl = await mock.start()
  stateDir ??= join(TMP, `state-${stateSeq++}`)
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
  const baseUrl = `https://127.0.0.1:${server.address().port}`
  const client = new BridgeClient({ baseUrl })
  const pairingCode = readFileSync(join(stateDir, 'pairing-code.txt'), 'utf8').trim()
  const paired = await client.pair(pairingCode)
  assert.equal(paired.status, 201)
  return { mock, bridge, client, baseUrl, stateDir }
}

const pcm = (ms = 500) => {
  const buf = Buffer.alloc(Math.round(16000 * ms / 1000) * 2)
  crypto.randomFillSync(buf) // noise, mock does not care
  return buf
}
const rid = () => 'req_' + crypto.randomUUID().replaceAll('-', '')

describe('auth and defensive validation', () => {
  let ctx
  before(async () => { ctx = await launch() })
  after(async () => { await ctx.bridge.stop(); await ctx.mock.stop() })

  it('health endpoint is open, unknown paths are 404 JSON', async () => {
    const health = await ctx.client.raw('GET', '/v1/health')
    assert.equal(health.status, 200)
    assert.equal(health.json.ok, true)
    const missing = await ctx.client.raw('GET', '/v1/definitely-not-here')
    assert.equal(missing.status, 404)
    assert.equal(missing.json.error, 'ERR_NOT_FOUND')
  })

  it('rejects tampered signature / replayed nonce / unknown device with stable codes', async () => {
    const id = rid()
    const audio = pcm(100)
    const tampered = await ctx.client.signed('POST', '/v1/voice/turns', {
      requestId: id,
      json: { protocol_version: 1, request_id: id, audio: {}, audio_base64: '' },
      tamper: h => { h['x-signature'] = h['x-signature'].replace(/^../, 'ff') },
    })
    assert.equal(tampered.json.error, 'ERR_SIGNATURE_INVALID')

    // nonce replay: reuse identical signed headers twice
    const rawBody = Buffer.from(JSON.stringify({ x: 1 }))
    const headers = ctx.client.signHeaders('POST', '/v1/voice/turns', rawBody, id)
    const once = await ctx.client.raw('POST', '/v1/voice/turns', { headers: { ...headers, 'content-type': 'application/json' }, body: rawBody })
    assert.notEqual(once.json.error, 'ERR_NONCE_REPLAYED')
    const twice = await ctx.client.raw('POST', '/v1/voice/turns', { headers: { ...headers, 'content-type': 'application/json' }, body: rawBody })
    assert.equal(twice.json.error, 'ERR_NONCE_REPLAYED')

    const stranger = new BridgeClient({ baseUrl: ctx.baseUrl, deviceId: 'dev_nope', token: 'aa'.repeat(32) })
    const unknown = await stranger.createTurn(rid(), audio)
    assert.equal(unknown.json.error, 'ERR_DEVICE_UNKNOWN')
  })

  it('rejects payload violations with stable codes', async () => {
    const audio = pcm(100)
    const badVersion = await ctx.client.createTurn(rid(), audio, { protocolVersion: 99 })
    assert.equal(badVersion.json.error, 'ERR_PROTOCOL_VERSION')
    const tooLong = await ctx.client.createTurn(rid(), audio, { durationMs: 61_000 })
    assert.equal(tooLong.json.error, 'ERR_DURATION_TOO_LONG')
    const badSha = await ctx.client.createTurn(rid(), audio, { sha256: 'deadbeef' })
    assert.equal(badSha.json.error, 'ERR_AUDIO_HASH_MISMATCH')
    // a rejected create leaves no turn behind
    const after404 = await ctx.client.getTurn('req_never_created')
    assert.equal(after404.status, 404)
  })

  it('refuses unsigned WSS upgrade', async () => {
    const { default: WebSocket } = await import('ws')
    const ws = new WebSocket(ctx.baseUrl.replace('https', 'wss') + '/v1/voice/events', { rejectUnauthorized: false })
    const failed = await new Promise(resolve => {
      ws.on('unexpected-response', (_, res) => resolve(res.statusCode))
      ws.on('error', () => resolve('error'))
      ws.on('open', () => resolve('open'))
    })
    assert.notEqual(failed, 'open')
  })
})

describe('direct-answer path', () => {
  let ctx
  before(async () => { ctx = await launch({ scenario: 'direct' }) })
  after(async () => { await ctx.bridge.stop(); await ctx.mock.stop() })

  it('202 receipt is immediate, turn completes with text result, WSS sees the states', async () => {
    const events = ctx.client.events()
    await waitFor(() => events.received.some(e => e.type === 'snapshot'))

    const id = rid()
    const t0 = Date.now()
    const created = await ctx.client.createTurn(id, pcm(500))
    const receiptMs = Date.now() - t0
    assert.equal(created.status, 202)
    assert.equal(created.json.status, 'accepted')
    assert.ok(receiptMs < 3000, `receipt took ${receiptMs}ms`) // acceptance: receipt P95 < 3s

    const done = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'completed' ? r.json : null
    })
    assert.equal(done.path, 'direct')
    assert.equal(done.result.text, '现在是上午九点。')

    await waitFor(() => events.received.some(e =>
      e.type === 'turn.state' && e.turn.request_id === id && e.turn.status === 'completed'))
    const states = events.received.filter(e => e.type === 'turn.state' && e.turn.request_id === id).map(e => e.turn.status)
    assert.ok(states.includes('accepted') || states.includes('processing'))
    events.ws.close()
  })

  it('same request_id + same body replays without a second execution; different body conflicts', async () => {
    const id = rid()
    const audio = pcm(300)
    const first = await ctx.client.createTurn(id, audio)
    assert.equal(first.status, 202)
    await waitFor(async () => (await ctx.client.getTurn(id)).json.status === 'completed')

    const turnsBefore = ctx.mock.realtimeTurns
    const replay = await ctx.client.createTurn(id, audio)
    assert.equal(replay.status, 202)
    assert.equal(replay.json.idempotent_replay, true)
    assert.equal(replay.json.status, 'completed') // replay returns the existing work mapping
    assert.equal(ctx.mock.realtimeTurns, turnsBefore) // no second execution

    const conflict = await ctx.client.createTurn(id, pcm(200))
    assert.equal(conflict.status, 409)
    assert.equal(conflict.json.error, 'ERR_IDEMPOTENCY_CONFLICT')
  })
})

describe('background path: task projection, permission, cancel', () => {
  let ctx
  // 权限确认全链路属 post-demo（F1 闭环）；显式打开写动作开关来测它。
  before(async () => { ctx = await launch({ scenario: 'background', overrides: { write_actions_enabled: true } }) })
  after(async () => { await ctx.bridge.stop(); await ctx.mock.stop() })

  it('projects background task through permission_required to completed', async () => {
    const id = rid()
    await ctx.client.createTurn(id, pcm(400))
    await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

    // permission requested upstream
    ctx.mock.emitTask('task.permission.requested', {
      ...ctx.mock.tasks.get('task_bg'),
      authorization: { id: 'perm_1', status: 'pending', title: '允许修改 README.md？' },
    })
    const withPerm = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'permission_required' ? r.json : null
    })
    assert.equal(withPerm.permission.id, 'perm_1')
    assert.equal(withPerm.permission.title, '允许修改 README.md？')

    // wrong permission id is rejected; decision vocabulary is validated
    const wrong = await ctx.client.permission(id, 'perm_999', 'allow')
    assert.equal(wrong.json.error, 'ERR_PERMISSION_UNKNOWN')
    const badDecision = await ctx.client.permission(id, 'perm_1', 'maybe')
    assert.equal(badDecision.json.error, 'ERR_PERMISSION_DECISION_INVALID')

    const allowed = await ctx.client.permission(id, 'perm_1', 'allow')
    assert.equal(allowed.status, 200)
    assert.deepEqual(ctx.mock.permissionDecisions, [{ id: 'perm_1', decision: 'always' }])

    ctx.mock.emitTask('task.completed', {
      ...ctx.mock.tasks.get('task_bg'),
      status: 'completed',
      resultMetadata: { presentation: { speech: '已经修改完成。', inline: { content: '详情……' } } },
    })
    const done = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'completed' ? r.json : null
    })
    assert.equal(done.result.text, '已经修改完成。')
    assert.equal(done.path, 'background')
  })

  it('northbound cancel maps to DELETE /api/tasks/:id and projects cancelled', async () => {
    ctx.mock.tasks.delete('task_bg')
    const id = rid()
    await ctx.client.createTurn(id, pcm(400))
    await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

    const cancelled = await ctx.client.cancelTurn(id)
    assert.equal(cancelled.status, 200)
    assert.ok(ctx.mock.deleteCalls.includes('task_bg'))
    const final = await waitFor(async () => {
      const r = await ctx.client.getTurn(id)
      return r.json.status === 'cancelled' ? r.json : null
    })
    assert.equal(final.status, 'cancelled')
    // cancel of a terminal turn is a stable no-op / error
    const again = await ctx.client.cancelTurn(id)
    assert.equal(again.status, 200)
  })
})

describe('hard timeout (300s rule, shortened for test)', () => {
  it('realtime phase: silent gateway → ERR_WORK_TIMEOUT', async () => {
    const ctx = await launch({ scenario: 'silent', overrides: { max_work_ms: 2500 } })
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm(200))
      const failed = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.status === 'failed' ? r.json : null
      }, { timeoutMs: 10_000 })
      assert.equal(failed.error, 'ERR_WORK_TIMEOUT')
    } finally {
      await ctx.bridge.stop(); await ctx.mock.stop()
    }
  })

  it('background phase: stuck task → upstream cancel + ERR_WORK_TIMEOUT', async () => {
    const ctx = await launch({ scenario: 'background', overrides: { max_work_ms: 3000 } })
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm(200))
      const failed = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return r.json.status === 'failed' ? r.json : null
      }, { timeoutMs: 15_000 })
      assert.equal(failed.error, 'ERR_WORK_TIMEOUT')
      assert.ok(ctx.mock.deleteCalls.includes('task_bg'), 'timeout must cancel the upstream task')
    } finally {
      await ctx.bridge.stop(); await ctx.mock.stop()
    }
  })
})

describe('defensive parsing of gateway responses', () => {
  it('HTML from an /api/* route is never parsed as JSON', async () => {
    const mock = new MockGateway({ scenario: 'html-task' })
    const url = await mock.start()
    try {
      const gw = new GatewayClient({ baseUrl: url })
      await assert.rejects(() => gw.getTask('anything'), e => e.code === 'ERR_UPSTREAM_SCHEMA')
    } finally { await mock.stop() }
  })

  it('non-SSE response on the events endpoint is rejected', async () => {
    const mock = new MockGateway({ scenario: 'sse-html' })
    const url = await mock.start()
    mock.setTask({ id: 't1', status: 'running', authorization: null })
    try {
      const gw = new GatewayClient({ baseUrl: url })
      await assert.rejects(async () => {
        for await (const _ of gw.taskEvents('t1')) void _
      }, e => e.code === 'ERR_UPSTREAM_SCHEMA')
    } finally { await mock.stop() }
  })
})

describe('restart recovery', () => {
  it('re-attaches watchers for turns with a task_id; unknown-outcome turns go to manual confirm', async () => {
    const stateDir = join(TMP, `state-${stateSeq++}`)
    const ctxA = await launch({ scenario: 'background', stateDir })
    const id = rid()
    await ctxA.client.createTurn(id, pcm(300))
    await waitFor(async () => (await ctxA.client.getTurn(id)).json.task_id === 'task_bg')
    await ctxA.bridge.stop() // simulated crash mid-background-task (mock keeps running)

    // inject a stuck no-task turn into the persisted ledger (unknown outcome)
    const ledgerPath = join(stateDir, 'turn-ledger.json')
    const persisted = JSON.parse(readFileSync(ledgerPath, 'utf8'))
    persisted.turns.req_unknown_outcome = {
      ...persisted.turns[id],
      request_id: 'req_unknown_outcome',
      task_id: null,
      state: 'processing',
      detail: 'realtime_processing',
    }
    writeFileSync(ledgerPath, JSON.stringify(persisted))

    const bridgeB = createBridge({
      port: 0,
      bind_tailscale_ip: 'none',
      tls_cert: CERT,
      tls_key: KEY,
      state_dir: stateDir,
      gateway_url: `http://127.0.0.1:${ctxA.mock.port}`,
      allow_test_pcm: true,
      sse_backoff_base_ms: 200,
      sse_backoff_max_ms: 1000,
    })
    const [serverB] = await bridgeB.start()
    try {
      // provably-unknown turn is failed for manual confirmation, NOT re-run
      assert.equal(bridgeB.ledger.get('req_unknown_outcome').state, 'failed')
      assert.equal(bridgeB.ledger.get('req_unknown_outcome').error, 'ERR_RESULT_UNKNOWN')

      // watched turn resumes: completing the task upstream completes the turn
      ctxA.mock.emitTask('task.completed', {
        id: 'task_bg', status: 'completed', authorization: null,
        resultMetadata: { presentation: { speech: '重启后交付的结果。' } },
      })
      await waitFor(() => bridgeB.ledger.get(id).state === 'completed')
      assert.equal(bridgeB.ledger.get(id).result.text, '重启后交付的结果。')
      assert.equal(ctxA.mock.realtimeTurns, 1, 'recovery must not re-inject the turn')
    } finally {
      await bridgeB.stop()
      await ctxA.mock.stop()
    }
  })
})

describe('D1 read-only switch (write_actions_enabled=false, the default)', () => {
  it('auto-rejects upstream permission requests and never projects permission_required', async () => {
    const ctx = await launch({ scenario: 'background' }) // 默认 write_actions_enabled=false
    try {
      const events = ctx.client.events()
      await waitFor(() => events.received.some(e => e.type === 'snapshot'))

      const id = rid()
      await ctx.client.createTurn(id, pcm(400))
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

      ctx.mock.emitTask('task.permission.requested', {
        ...ctx.mock.tasks.get('task_bg'),
        authorization: { id: 'perm_w', status: 'pending', title: '允许修改 README.md？' },
      })

      // 上游收到 reject（mock 语义：reject → task cancelled）；拒写 turn 以
      // completed + 用户可读文案收尾，Watch 不露裸 cancelled/错误码。
      await waitFor(() => ctx.mock.permissionDecisions.length > 0)
      assert.deepEqual(ctx.mock.permissionDecisions, [{ id: 'perm_w', decision: 'reject' }])
      const done = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return ['completed', 'failed', 'cancelled'].includes(r.json.status) ? r.json : null
      })
      assert.equal(done.status, 'completed')
      assert.match(done.result.text, /只读模式/)
      assert.match(done.result.text, /写操作已被拒绝/)

      // 北向事件流中从未出现 permission_required
      const states = events.received
        .filter(e => e.type === 'turn.state' && e.turn.request_id === id)
        .map(e => e.turn.status)
      assert.ok(!states.includes('permission_required'), `states were ${states}`)
      events.ws.close()
    } finally {
      await ctx.bridge.stop()
      await ctx.mock.stop()
    }
  })

  it('rejects a session-scoped permission event arriving on the bridge realtime WS (in-band path)', async () => {
    const ctx = await launch({ scenario: 'background' }) // 清扫周期保持默认 5s：本用例只可能走 in-band 路径
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm(400))
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

      // 真机第三轮实测形态：权限事件经本会话 Realtime WS 到达（网关按
      // sessionId 过滤后下发，到达即归属证明），宿主 task 错挂且 running
      // ——list 清扫器对 running 非己宿主不动手，in-band 路径必须定向 reject。
      ctx.mock.pushTaskEvent('task.permission.requested', {
        id: 'work_ghost_host', status: 'running',
        authorization: { id: 'perm_inband', status: 'pending', title: '允许写文件？' },
      })

      await waitFor(() => ctx.mock.permissionDecisions.length > 0, { timeoutMs: 3000 })
      assert.deepEqual(ctx.mock.permissionDecisions, [{ id: 'perm_inband', decision: 'reject' }])

      // Codex 收到 reject 后以 cancelled 收尾本 turn 的任务 → completed + 可读文案
      ctx.mock.emitTask('task.cancelled', {
        ...ctx.mock.tasks.get('task_bg'), status: 'cancelled', authorization: null,
      })
      const done = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return ['completed', 'failed', 'cancelled'].includes(r.json.status) ? r.json : null
      })
      assert.equal(done.status, 'completed')
      assert.match(done.result.text, /只读模式/)
    } finally {
      await ctx.bridge.stop()
      await ctx.mock.stop()
    }
  })

  it('sweeper rejects a terminal-orphan authorization and the denied turn ends with readable copy', async () => {
    const ctx = await launch({ scenario: 'background', overrides: { deny_sweep_interval_ms: 200 } })
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm(400))
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

      // 真网关错挂缺陷的实测形态（ESS-34 三轮）：写授权 pending 挂在一个
      // completed 终态任务上，delegation/backendRef 均不可用于归属。终态宿主
      // 不可能有活跃执行在等这份授权 → 终态孤儿规则定向 reject。
      ctx.mock.setTask({
        id: 'task_orphan_host', status: 'completed',
        authorization: { id: 'perm_orphan', status: 'pending', title: '允许写文件？' },
      })

      await waitFor(() => ctx.mock.permissionDecisions.length > 0, { timeoutMs: 5000 })
      assert.deepEqual(ctx.mock.permissionDecisions, [{ id: 'perm_orphan', decision: 'reject' }])

      // Codex 收到 reject 后以 cancelled 收尾本 turn 的任务 → 投影层凭拒写
      // 标记升级为 completed + 用户可读文案，Watch 不露裸 cancelled。
      ctx.mock.emitTask('task.cancelled', {
        ...ctx.mock.tasks.get('task_bg'), status: 'cancelled', authorization: null,
      })
      const done = await waitFor(async () => {
        const r = await ctx.client.getTurn(id)
        return ['completed', 'failed', 'cancelled'].includes(r.json.status) ? r.json : null
      })
      assert.equal(done.status, 'completed')
      assert.match(done.result.text, /只读模式/)
    } finally {
      await ctx.bridge.stop()
      await ctx.mock.stop()
    }
  })

  it('terminal-orphan rule is inert without an in-flight bridge turn', async () => {
    const ctx = await launch({ scenario: 'background', overrides: { deny_sweep_interval_ms: 200 } })
    try {
      // 没有任何在途 turn：即使全局列表里出现终态孤儿 authorization，
      // 本 Bridge 也没有写嫌疑，一概不动。
      ctx.mock.setTask({
        id: 'task_orphan_idle', status: 'failed',
        authorization: { id: 'perm_idle_orphan', status: 'pending', title: '允许写文件？' },
      })

      await new Promise(resolve => setTimeout(resolve, 700))
      assert.deepEqual(ctx.mock.permissionDecisions, [])
      assert.equal(ctx.mock.tasks.get('task_orphan_idle').authorization.status, 'pending')
    } finally {
      await ctx.bridge.stop()
      await ctx.mock.stop()
    }
  })

  it('sweeper leaves unrelated pending authorizations untouched (ESS-34 task isolation)', async () => {
    const ctx = await launch({ scenario: 'background', overrides: { deny_sweep_interval_ms: 200 } })
    try {
      const id = rid()
      await ctx.client.createTurn(id, pcm(400))
      await waitFor(async () => (await ctx.client.getTurn(id)).json.task_id === 'task_bg')

      // 无关任务（其他会话/Agent/人工发起）带着 pending authorization 出现在
      // 全局列表里；宿主 running（真实活任务的 authorization 挂在自己 running
      // 的宿主上）、无 delegation/backendRef（真网关运行期形态）。
      ctx.mock.setTask({
        id: 'task_stranger', status: 'running',
        authorization: { id: 'perm_unrelated', status: 'pending', title: '允许部署到生产？' },
      })

      // 等待超过两个 sweep interval：无关 authorization 必须保持 pending，
      // respondPermission 一次都不能被调用。
      await new Promise(resolve => setTimeout(resolve, 700))
      assert.deepEqual(ctx.mock.permissionDecisions, [])
      assert.equal(ctx.mock.tasks.get('task_stranger').authorization.status, 'pending')
    } finally {
      await ctx.bridge.stop()
      await ctx.mock.stop()
    }
  })
})
