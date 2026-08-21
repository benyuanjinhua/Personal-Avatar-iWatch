// ESS-958: duplicate-session guard + handshake rate limit (Gateway WSS 升级层).
//
// 事故形状：单个客户端 bug 在 47s 内对同一 request_id 重连 256 次，每次重连
// 都新建一个 RealtimeSession → 新建一次上游 agent 连接，把上游打穿。修复在
// upgrade 阶段加两道闸：
//   1. activeScopes —— 同 scope（device/session/request/generation）只允许一个
//      活跃会话，重复 upgrade 返回 409 ERR_SCOPE_ALREADY_ACTIVE；
//   2. handshakeTimes —— 同 device+request 的握手限速，超限返回 429
//      ERR_HANDSHAKE_RATE_LIMITED 并落结构化 ws_upgrade_rejected 日志。
// 本测试在进程内起真实 Gateway，用 20 次同 request_id 重连验证「不得创建 20
// 次上游连接」。

import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, describe, it } from 'node:test'
import WebSocket from 'ws'

import { createGateway } from '../server.mjs'
import { signRequest } from '../device-auth.mjs'

function collectLogs() {
  const lines = []
  const original = process.stdout.write.bind(process.stdout)
  process.stdout.write = chunk => {
    if (typeof chunk === 'string' && chunk.startsWith('{"ts"')) lines.push(JSON.parse(chunk.trim()))
    return original(chunk)
  }
  return { lines, restore() { process.stdout.write = original } }
}

describe('ESS-958 duplicate session guard + handshake rate limit', () => {
  let gateway, baseUrl, deviceId, tokenRaw
  let openTurnCalls = 0

  before(async () => {
    gateway = createGateway({
      port: 0, bind: '127.0.0.1',
      state_dir: mkdtempSync(join(tmpdir(), 'gw-958-')),
      dev_allow_plain_ws: true,
      agent_transport: 'mock',
      handshake_min_interval_ms: 60_000,
      heartbeat_interval_ms: 0, idle_disconnect_ms: 0,
    })
    deviceId = 'jackson-iphone'
    tokenRaw = crypto.randomBytes(32).toString('hex')
    gateway.devices.register(deviceId, tokenRaw)
    const server = await gateway.start()
    baseUrl = `http://127.0.0.1:${server.address().port}`

    // Count upstream agent connections (openTurn calls) to prove the guard
    // stops a reconnect storm from creating one upstream socket per attempt.
    const realOpenTurn = gateway.agentTransport.openTurn.bind(gateway.agentTransport)
    gateway.agentTransport.openTurn = (...args) => { openTurnCalls += 1; return realOpenTurn(...args) }
  })
  after(async () => { await gateway.stop() })

  function scope(overrides = {}) {
    return {
      protocol_version: 1, device_id: deviceId,
      session_id: 's-958-' + crypto.randomBytes(3).toString('hex'),
      request_id: 'r-958-' + crypto.randomBytes(3).toString('hex'),
      generation: 1, ttl_ms: 30_000,
      ...overrides,
    }
  }

  async function mintToken(body) {
    const nonce = crypto.randomBytes(8).toString('hex')
    const { rawBody, headers } = signRequest({
      tokenRaw, deviceId, method: 'POST', pathName: '/v1/realtime/session-token',
      requestId: body.request_id, body, nonce, timestamp: Date.now(),
    })
    const response = await fetch(baseUrl + '/v1/realtime/session-token', {
      method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: rawBody,
    })
    return { status: response.status, body: await response.json().catch(() => ({})) }
  }

  function connect(body, token) {
    const query = new URLSearchParams({
      device_id: body.device_id, session_id: body.session_id,
      request_id: body.request_id, generation: String(body.generation),
    })
    return new Promise(resolve => {
      const ws = new WebSocket(`${baseUrl.replace('http', 'ws')}/api/realtime?${query}`, {
        headers: { authorization: 'Bearer ' + token },
      })
      ws.on('unexpected-response', (_, res) => { res.resume(); resolve({ status: res.statusCode, ws: null }) })
      ws.on('open', () => resolve({ status: 101, ws }))
      ws.on('error', () => resolve({ status: null, ws: null }))
    })
  }

  async function startSession(ws, body) {
    ws.send(JSON.stringify({
      type: 'session.start', session_id: body.session_id,
      request_id: body.request_id, generation: body.generation, protocol_version: 1,
    }))
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('timeout waiting for ready')), 1000)
      ws.on('message', raw => {
        const msg = JSON.parse(raw.toString())
        if (msg.type === 'ready') { clearTimeout(timer); resolve(msg) }
      })
    })
  }

  it('same request_id reconnecting 20× creates exactly one upstream connection', async () => {
    const body = scope()
    const before = openTurnCalls
    const firstToken = await mintToken(body)
    assert.equal(firstToken.status, 201, 'token mint must succeed')
    const first = await connect(body, firstToken.body.token)
    assert.equal(first.status, 101, 'first upgrade must be accepted')
    await startSession(first.ws, body)

    const statuses = []
    for (let i = 0; i < 19; i++) {
      const minted = await mintToken(body)
      const attempt = await connect(body, minted.body.token)
      statuses.push(attempt.status)
      if (attempt.ws) attempt.ws.terminate()
    }
    assert.equal(openTurnCalls - before, 1, 'only the first session reaches the upstream transport')
    assert.ok(statuses.every(s => s === 409),
      `every duplicate upgrade must be 409 ERR_SCOPE_ALREADY_ACTIVE, got: ${statuses.join(', ')}`)
    first.ws.close()
  })

  it('duplicate scope returns 409 ERR_SCOPE_ALREADY_ACTIVE with a structured log', async () => {
    const body = scope()
    const firstToken = await mintToken(body)
    const first = await connect(body, firstToken.body.token)
    assert.equal(first.status, 101)
    await startSession(first.ws, body)

    const captured = collectLogs()
    let status
    try {
      const secondToken = await mintToken(body)
      const second = await connect(body, secondToken.body.token)
      status = second.status
      if (second.ws) second.ws.terminate()
    } finally {
      captured.restore()
    }
    assert.equal(status, 409)
    const rejected = captured.lines.find(l => l.evt === 'ws_upgrade_rejected' && l.code === 'ERR_SCOPE_ALREADY_ACTIVE')
    assert.ok(rejected, 'duplicate scope must log ws_upgrade_rejected ERR_SCOPE_ALREADY_ACTIVE')
    assert.equal(rejected.request_id, body.request_id)
    assert.equal(rejected.session_id, body.session_id)
    first.ws.close()
  })

  it('rapid reconnect after close returns 429 ERR_HANDSHAKE_RATE_LIMITED with a structured log', async () => {
    const body = scope()
    const firstToken = await mintToken(body)
    const first = await connect(body, firstToken.body.token)
    assert.equal(first.status, 101)
    await startSession(first.ws, body)
    // Close the first socket so activeScopes frees the scope; the handshake
    // rate limiter (keyed device+request) is what must now reject the retry.
    first.ws.close()
    await new Promise(resolve => first.ws.once('close', resolve))
    await new Promise(resolve => setTimeout(resolve, 50)) // let server-side close handlers run

    const captured = collectLogs()
    let status
    try {
      const retryToken = await mintToken(body)
      const retry = await connect(body, retryToken.body.token)
      status = retry.status
      if (retry.ws) retry.ws.terminate()
    } finally {
      captured.restore()
    }
    assert.equal(status, 429)
    const rejected = captured.lines.find(l => l.evt === 'ws_upgrade_rejected' && l.code === 'ERR_HANDSHAKE_RATE_LIMITED')
    assert.ok(rejected, 'handshake over-limit must log ws_upgrade_rejected ERR_HANDSHAKE_RATE_LIMITED')
    assert.equal(rejected.request_id, body.request_id)
    assert.equal(typeof rejected.retry_after_ms, 'number')
  })
})
