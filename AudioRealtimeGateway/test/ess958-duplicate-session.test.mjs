// ESS-958 integration: 同 request_id 重复 session.start 无防护。
//
// 真机取证（2026-08-21）：同一个 request_id + 同一个 generation 反复
// session.start 时，Gateway 每次都新建 nextUplinkSequence=0 的全新会话，
// 客户端续发的 sequence 必然 ERR_STREAM_SEQUENCE，形成 255 次 / 47 秒的
// 重连风暴，并打了 256 次上游连接（upstream_connecting × 256）。
//
// 选定策略（服务端）：同 scope（device/session/request/generation）只允许
// 一个活跃会话——重复 upgrade 拒绝为 ERR_SCOPE_ALREADY_ACTIVE (409)；
// 同 device+request 的握手频率设上界——超限拒绝为
// ERR_HANDSHAKE_RATE_LIMITED (429)。两条拒绝都落结构化日志。
//
// 本文件钉住三条验收：
//   1. 同 request_id 连续重连 20 次不产生 20 次上游连接（openTurn 只发生 1 次）
//   2. 重复 scope 返回 ERR_SCOPE_ALREADY_ACTIVE（409）
//   3. 握手超限返回 ERR_HANDSHAKE_RATE_LIMITED（429）且有结构化日志

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
  return {
    lines,
    restore() { process.stdout.write = original },
  }
}

describe('Gateway ESS-958 duplicate-session guard', () => {
  let gateway, baseUrl, deviceId, tokenRaw
  let upstreamOpens = 0

  before(async () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'gw-ess958-'))
    gateway = createGateway({
      port: 0, bind: '127.0.0.1', state_dir: stateDir,
      dev_allow_plain_ws: true,
      heartbeat_interval_ms: 0, idle_disconnect_ms: 0,
      max_token_ttl_ms: 60_000, default_token_ttl_ms: 30_000,
      agent_transport: 'mock',
      handshake_min_interval_ms: 1_000,
    })
    deviceId = 'ess958-watch'
    tokenRaw = crypto.randomBytes(32).toString('hex')
    gateway.devices.register(deviceId, tokenRaw)
    const server = await gateway.start()
    baseUrl = `http://127.0.0.1:${server.address().port}`

    // 上游连接计数：mock transport 的 openTurn 即「上游会话建立」。
    // 20 次重连里它只该被调用一次。
    const original = gateway.agentTransport.openTurn.bind(gateway.agentTransport)
    gateway.agentTransport.openTurn = (...args) => { upstreamOpens += 1; return original(...args) }
  })

  after(async () => { await gateway.stop() })

  async function mintToken(body, opts = {}) {
    const timestamp = opts.timestamp ?? Date.now()
    const nonce = opts.nonce ?? crypto.randomBytes(8).toString('hex')
    const requestId = opts.requestId ?? body.request_id ?? ''
    const { rawBody, headers } = signRequest({
      tokenRaw: opts.tokenRaw ?? tokenRaw, deviceId: opts.deviceId ?? deviceId,
      method: 'POST', pathName: '/v1/realtime/session-token',
      requestId, body, nonce, timestamp,
    })
    const response = await fetch(baseUrl + '/v1/realtime/session-token', {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body: rawBody,
    })
    const json = await response.json().catch(() => ({}))
    return { status: response.status, body: json }
  }

  function scopeBody(overrides = {}) {
    return {
      protocol_version: 1,
      device_id: deviceId,
      session_id: 's-ess958-' + crypto.randomBytes(2).toString('hex'),
      request_id: 'r-ess958-' + crypto.randomBytes(2).toString('hex'),
      generation: 1, ttl_ms: 30_000,
      ...overrides,
    }
  }

  function upgradeUrl(body) {
    return `ws://127.0.0.1:${gateway.server.address().port}/api/realtime`
      + `?device_id=${body.device_id}&session_id=${body.session_id}`
      + `&request_id=${body.request_id}&generation=${body.generation}`
  }

  function openSocket(body, token) {
    return new WebSocket(upgradeUrl(body), { headers: { authorization: 'Bearer ' + token } })
  }

  function waitOpen(ws) {
    return new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
  }

  function waitClose(ws) {
    return new Promise(resolve => ws.once('close', resolve))
  }

  // 只取拒绝态的状态码；成功（101）时由调用方保留 socket 继续会话。
  function upgradeStatus(body, token) {
    const ws = openSocket(body, token)
    return new Promise(resolve => {
      ws.on('unexpected-response', (_, response) => resolve(response.statusCode))
      ws.on('error', () => resolve(null))
    })
  }

  function sessionStart(body) {
    return JSON.stringify({
      type: 'session.start',
      session_id: body.session_id, request_id: body.request_id,
      generation: body.generation, protocol_version: 1,
    })
  }

  function waitReady(ws) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('timeout waiting for ready')), 2000)
      ws.on('message', raw => {
        const msg = JSON.parse(raw.toString())
        if (msg.type === 'ready') { clearTimeout(timer); resolve(msg) }
      })
    })
  }

  it('same request_id reconnecting 20× does not open 20 upstream connections', async () => {
    const body = scopeBody()
    const first = await mintToken(body)
    assert.equal(first.status, 201)
    const ws1 = openSocket(body, first.body.token)
    await waitOpen(ws1)
    ws1.send(sessionStart(body))
    await waitReady(ws1)
    assert.equal(upstreamOpens, 1, 'first session.start opens exactly one upstream turn')

    for (let i = 0; i < 19; i++) {
      // 每次重连都需要一枚新 token（token 单次消耗），但 scope 完全一致。
      const mint = await mintToken(body)
      assert.equal(mint.status, 201, `reconnect #${i + 2} token mint should succeed`)
      const status = await upgradeStatus(body, mint.body.token)
      assert.equal(status, 409, `reconnect #${i + 2} must be refused with 409 ERR_SCOPE_ALREADY_ACTIVE`)
    }
    assert.equal(upstreamOpens, 1, '20 reconnects with the same request_id must open exactly 1 upstream connection')
    ws1.close()
    await waitClose(ws1)
  })

  it('rejects a duplicate scope upgrade with 409 ERR_SCOPE_ALREADY_ACTIVE + structured log', async () => {
    const body = scopeBody()
    const first = await mintToken(body)
    const ws1 = openSocket(body, first.body.token)
    await waitOpen(ws1)
    ws1.send(sessionStart(body))
    await waitReady(ws1)

    const second = await mintToken(body)
    assert.equal(second.status, 201, 'a second token for the same scope is mintable')

    const captured = collectLogs()
    let status
    try {
      status = await upgradeStatus(body, second.body.token)
    } finally {
      captured.restore()
    }
    assert.equal(status, 409, 'duplicate scope upgrade must be refused with 409')

    const rejected = captured.lines.find(l => l.evt === 'ws_upgrade_rejected' && l.code === 'ERR_SCOPE_ALREADY_ACTIVE')
    assert.ok(rejected, 'expected a ws_upgrade_rejected(ERR_SCOPE_ALREADY_ACTIVE) structured log')
    assert.equal(rejected.request_id, body.request_id)
    assert.equal(rejected.session_id, body.session_id)
    assert.equal(rejected.generation, body.generation)
    ws1.close()
    await waitClose(ws1)
  })

  it('rate-limits a second handshake for the same device+request with 429 + structured log', async () => {
    // 第一次握手用 session S1 记录 device:request 的握手时间。
    const s1 = scopeBody()
    const mint1 = await mintToken(s1)
    const ws1 = openSocket(s1, mint1.body.token)
    await waitOpen(ws1)

    // 第二次握手换新 session（scope 不同 → 不命中「重复 scope」），但
    // device+request 相同 → 命中握手限速。
    const s2 = scopeBody({ session_id: 's-ess958-ratelimit-b', request_id: s1.request_id })
    const mint2 = await mintToken(s2)
    assert.equal(mint2.status, 201)

    const captured = collectLogs()
    let status
    try {
      status = await upgradeStatus(s2, mint2.body.token)
    } finally {
      captured.restore()
    }
    assert.equal(status, 429, 'rapid second handshake for the same device+request must be 429')

    const rejected = captured.lines.find(l => l.evt === 'ws_upgrade_rejected' && l.code === 'ERR_HANDSHAKE_RATE_LIMITED')
    assert.ok(rejected, 'expected a ws_upgrade_rejected(ERR_HANDSHAKE_RATE_LIMITED) structured log')
    assert.equal(rejected.request_id, s1.request_id)
    assert.equal(rejected.session_id, s2.session_id)
    assert.equal(typeof rejected.retry_after_ms, 'number', 'rate-limit log must carry retry_after_ms')
    assert.ok(rejected.retry_after_ms > 0, 'retry_after_ms must be positive')
    ws1.close()
    await waitClose(ws1)
  })
})
