// End-to-end tests for the composed Gateway: HTTP `/v1/realtime/session-token`
// → `WSS /api/realtime` upgrade → RealtimeSession. Runs an in-process
// server on 127.0.0.1 with dev_allow_plain_ws to avoid TLS setup.
//
// Covers ESS-403 acceptance #1 (auth success / expiry / replay / unauthorized)
// and #4 (structured logs correlated by request_id).

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

describe('Gateway end-to-end', () => {
  let gateway, baseUrl, deviceId, tokenRaw

  before(async () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'gw-e2e-'))
    gateway = createGateway({
      port: 0, bind: '127.0.0.1', state_dir: stateDir,
      dev_allow_plain_ws: true,
      dev_universal_token: 'rtk_dev_universal',
      heartbeat_interval_ms: 0, idle_disconnect_ms: 0,
      max_token_ttl_ms: 60_000, default_token_ttl_ms: 30_000,
    })
    // Register a device with a known secret (bootstrap flow).
    deviceId = 'jackson-iphone'
    tokenRaw = crypto.randomBytes(32).toString('hex')
    gateway.devices.register(deviceId, tokenRaw)
    const server = await gateway.start()
    const port = server.address().port
    baseUrl = `http://127.0.0.1:${port}`
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
      device_id: deviceId, session_id: 's-e2e-' + crypto.randomBytes(2).toString('hex'),
      request_id: 'r-e2e-' + crypto.randomBytes(2).toString('hex'),
      generation: 1, ttl_ms: 30_000,
      ...overrides,
    }
  }

  it('health endpoint is unauthenticated and returns service metadata', async () => {
    const r = await fetch(baseUrl + '/v1/health')
    assert.equal(r.status, 200)
    const body = await r.json()
    assert.equal(body.ok, true)
    assert.equal(body.service, 'audio-realtime-gateway')
  })

  it('mints an ephemeral token and lets a valid WSS upgrade through', async () => {
    const body = scopeBody()
    const mint = await mintToken(body)
    assert.equal(mint.status, 201)
    assert.match(mint.body.token, /^rtk_[a-f0-9]+$/)
    assert.equal(mint.body.scope.generation, 1)

    const captured = collectLogs()
    try {
      const url = `ws://127.0.0.1:${gateway.server.address().port}/api/realtime`
        + `?device_id=${body.device_id}&session_id=${body.session_id}`
        + `&request_id=${body.request_id}&generation=${body.generation}`
      const ws = new WebSocket(url, { headers: { authorization: 'Bearer ' + mint.body.token } })
      await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
      const received = []
      ws.on('message', raw => received.push(JSON.parse(raw.toString())))
      ws.send(JSON.stringify({
        type: 'session.start',
        session_id: body.session_id, request_id: body.request_id,
        generation: body.generation, protocol_version: 1,
      }))
      // Wait for ready
      const ready = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timeout waiting for ready')), 1000)
        ws.on('message', raw => {
          const msg = JSON.parse(raw.toString())
          if (msg.type === 'ready') { clearTimeout(timer); resolve(msg) }
        })
      })
      assert.equal(ready.type, 'ready')
      assert.equal(ready.request_id, body.request_id)
      ws.send(JSON.stringify({ type: 'close', reason: 'test_done' }))
      await new Promise(resolve => ws.once('close', resolve))
      // Server-side onSocketClose fires on the next tick — give it a moment.
      await new Promise(resolve => setTimeout(resolve, 50))
    } finally {
      captured.restore()
    }
    // Log correlation: ws_upgrade + session_ready + session_ended tagged
    // with the same request_id.
    const forThisReq = captured.lines.filter(l => l.request_id === body.request_id)
    const names = forThisReq.map(l => l.evt)
    for (const expected of ['ws_upgrade', 'session_ready', 'session_ended']) {
      assert.ok(names.includes(expected), `expected event ${expected} for req ${body.request_id}, saw: ${names.join(', ')}`)
    }
  })

  it('admits the development universal token (Bearer with underscores) without minting', async () => {
    const body = scopeBody()
    const captured = collectLogs()
    try {
      const url = `ws://127.0.0.1:${gateway.server.address().port}/api/realtime`
        + `?device_id=${body.device_id}&session_id=${body.session_id}`
        + `&request_id=${body.request_id}&generation=${body.generation}`
      const ws = new WebSocket(url, {
        headers: { authorization: 'Bearer ' + gateway.config.dev_universal_token },
      })
      await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
      ws.close()
      await new Promise(resolve => ws.once('close', resolve))
      await new Promise(resolve => setTimeout(resolve, 50))
    } finally {
      captured.restore()
    }
    const upgrades = captured.lines.filter(
      line => line.evt === 'ws_upgrade' && line.request_id === body.request_id,
    )
    assert.equal(upgrades.length, 1)
    assert.equal(upgrades[0].token_mode, 'universal')
    assert.equal(captured.lines.some(line => line.evt === 'token_consumed'
      && line.request_id === body.request_id), false)
  })

  it('rejects a WSS upgrade without a bearer token (401 ERR_TOKEN_INVALID)', async () => {
    const body = scopeBody()
    const url = `ws://127.0.0.1:${gateway.server.address().port}/api/realtime`
      + `?device_id=${body.device_id}&session_id=${body.session_id}`
      + `&request_id=${body.request_id}&generation=${body.generation}`
    const ws = new WebSocket(url)
    const status = await new Promise(resolve => {
      ws.on('unexpected-response', (_, response) => resolve(response.statusCode))
      ws.on('error', () => resolve(null))
    })
    assert.equal(status, 401)
  })

  it('rejects a WSS upgrade whose token has already been consumed (replay)', async () => {
    const body = scopeBody()
    const mint = await mintToken(body)
    const upgrade = () => {
      const url = `ws://127.0.0.1:${gateway.server.address().port}/api/realtime`
        + `?device_id=${body.device_id}&session_id=${body.session_id}`
        + `&request_id=${body.request_id}&generation=${body.generation}`
      return new WebSocket(url, { headers: { authorization: 'Bearer ' + mint.body.token } })
    }
    const first = upgrade()
    await new Promise((resolve, reject) => { first.once('open', resolve); first.once('error', reject) })
    first.close()
    await new Promise(resolve => first.once('close', resolve))
    const captured = collectLogs()
    let status
    try {
      const second = upgrade()
      status = await new Promise(resolve => {
        second.on('unexpected-response', (_, response) => resolve(response.statusCode))
        second.on('error', () => resolve(null))
      })
    } finally {
      captured.restore()
    }
    assert.equal(status, 401, 'replay of a consumed token must be rejected')
    // ESS-427: rejection logs must carry request_id + session_id so a
    // session-scoped grep reconstructs the failed turn (smoke S9f).
    const rejected = captured.lines.find(l => l.evt === 'token_rejected' && l.reason === 'consumed')
    assert.ok(rejected, 'expected a token_rejected(reason=consumed) log')
    assert.equal(rejected.request_id, body.request_id)
    assert.equal(rejected.session_id, body.session_id)
    assert.ok(rejected.jti, 'token_rejected must keep jti')
    const upgradeRejected = captured.lines.find(l => l.evt === 'ws_upgrade_rejected')
    assert.ok(upgradeRejected, 'expected a ws_upgrade_rejected log')
    assert.equal(upgradeRejected.code, 'ERR_TOKEN_CONSUMED')
    assert.equal(upgradeRejected.request_id, body.request_id)
    assert.equal(upgradeRejected.session_id, body.session_id)
  })

  it('rejects a WSS upgrade whose URL scope disagrees with the token', async () => {
    const body = scopeBody({ generation: 3 })
    const mint = await mintToken(body)
    const url = `ws://127.0.0.1:${gateway.server.address().port}/api/realtime`
      + `?device_id=${body.device_id}&session_id=${body.session_id}`
      + `&request_id=${body.request_id}&generation=99`
    const ws = new WebSocket(url, { headers: { authorization: 'Bearer ' + mint.body.token } })
    const status = await new Promise(resolve => {
      ws.on('unexpected-response', (_, response) => resolve(response.statusCode))
      ws.on('error', () => resolve(null))
    })
    assert.equal(status, 401)
  })

  it('rejects a token-mint call from an unknown device (signature check)', async () => {
    const bogusToken = crypto.randomBytes(32).toString('hex')
    const r = await mintToken(scopeBody(), { tokenRaw: bogusToken })
    assert.equal(r.status, 401)
    assert.equal(r.body.error, 'ERR_SIGNATURE_INVALID')
  })

  it('rejects a token-mint call with an expired timestamp', async () => {
    const oldTimestamp = Date.now() - 10 * 60 * 1000
    const r = await mintToken(scopeBody(), { timestamp: oldTimestamp })
    assert.equal(r.status, 401)
    assert.equal(r.body.error, 'ERR_TIMESTAMP_SKEW')
  })

  it('rejects a replayed nonce', async () => {
    const nonce = crypto.randomBytes(8).toString('hex')
    const first = await mintToken(scopeBody(), { nonce })
    assert.equal(first.status, 201)
    const second = await mintToken(scopeBody({ session_id: 'session-nonce-b' }), { nonce })
    assert.equal(second.status, 401)
    assert.equal(second.body.error, 'ERR_NONCE_REPLAYED')
  })

  it('refuses to accept binary WSS frames', async () => {
    const body = scopeBody()
    const mint = await mintToken(body)
    const url = `ws://127.0.0.1:${gateway.server.address().port}/api/realtime`
      + `?device_id=${body.device_id}&session_id=${body.session_id}`
      + `&request_id=${body.request_id}&generation=${body.generation}`
    const ws = new WebSocket(url, { headers: { authorization: 'Bearer ' + mint.body.token } })
    await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
    // Send a start first so the session exists.
    ws.send(JSON.stringify({
      type: 'session.start', session_id: body.session_id, request_id: body.request_id,
      generation: body.generation, protocol_version: 1,
    }))
    await new Promise(resolve => setTimeout(resolve, 30))
    ws.send(Buffer.from([0, 1, 2, 3]))
    const closed = await new Promise(resolve => ws.once('close', (code, reason) => resolve({ code, reason: reason.toString() })))
    assert.equal(closed.code, 1008)
    assert.equal(closed.reason, 'ERR_UNSUPPORTED_BINARY')
  })
})
