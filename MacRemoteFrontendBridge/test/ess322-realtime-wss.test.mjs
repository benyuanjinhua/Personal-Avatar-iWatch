process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, describe, it } from 'node:test'
import WebSocket from 'ws'

import { createBridge } from '../server.mjs'
import { BridgeClient, waitFor } from './client.mjs'
import { MockGateway } from './mock-gateway.mjs'

const TMP = mkdtempSync(join(tmpdir(), 'ess322-'))
const CERT = join(TMP, 'bridge.crt')
const KEY = join(TMP, 'bridge.key')
execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-keyout', KEY, '-out', CERT,
  '-days', '1', '-nodes', '-subj', '/CN=127.0.0.1'], { stdio: 'ignore' })

describe('ESS-322 authenticated realtime media WSS', () => {
  let mock, bridge, client, baseUrl
  before(async () => {
    mock = new MockGateway({ scenario: 'direct' })
    const gatewayUrl = await mock.start()
    const stateDir = join(TMP, 'state')
    bridge = createBridge({
      port: 0, bind_tailscale_ip: 'none', tls_cert: CERT, tls_key: KEY,
      state_dir: stateDir, gateway_url: gatewayUrl, realtime_media_v1: true,
      probe_timeout_ms: 500, events_heartbeat_ms: 60_000,
    })
    const [server] = await bridge.start()
    baseUrl = `https://127.0.0.1:${server.address().port}`
    client = new BridgeClient({ baseUrl })
    const code = readFileSync(join(stateDir, 'pairing-code.txt'), 'utf8').trim()
    assert.equal((await client.pair(code)).status, 201)
  })
  after(async () => { await bridge.stop(); await mock.stop() })

  function connect(requestId, sessionId, { signed = true } = {}) {
    const path = '/v1/voice/realtime'
    const headers = signed ? client.signHeaders('GET', path, Buffer.alloc(0), requestId) : {}
    const ws = new WebSocket(baseUrl.replace(/^http/, 'ws')
      + `${path}?request_id=${encodeURIComponent(requestId)}&session_id=${encodeURIComponent(sessionId)}`,
    { headers, rejectUnauthorized: false })
    const received = []
    ws.on('message', raw => received.push(JSON.parse(raw.toString())))
    return { ws, received }
  }

  it('rejects unsigned upgrades and mismatched request ownership', async () => {
    const unsigned = connect('req_unsigned', 'session-1', { signed: false }).ws
    const status = await new Promise(resolve => {
      unsigned.on('unexpected-response', (_, response) => resolve(response.statusCode))
      unsigned.on('error', () => resolve('error'))
    })
    assert.equal(status, 400)

    const path = '/v1/voice/realtime'
    const headers = client.signHeaders('GET', path, Buffer.alloc(0), 'req_signed')
    const ws = new WebSocket(baseUrl.replace(/^http/, 'ws') + `${path}?request_id=req_other&session_id=s`, { headers, rejectUnauthorized: false })
    const mismatchStatus = await new Promise(resolve => {
      ws.on('unexpected-response', (_, response) => resolve(response.statusCode))
      ws.on('error', () => resolve('error'))
    })
    assert.equal(mismatchStatus, 400)
  })

  it('runs start → frames → immediate delta → real playback ack → commit/close', async () => {
    const requestId = 'req_media_happy'
    const sessionId = 'session-media-1'
    const { ws, received } = connect(requestId, sessionId)
    await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
    ws.send(JSON.stringify({ type: 'start', protocol_version: 1, request_id: requestId, session_id: sessionId }))
    await waitFor(() => received.some(event => event.type === 'ready'))
    ws.send(JSON.stringify({ type: 'audio.append', sequence: 0, audio: 'AQI=' }))
    ws.send(JSON.stringify({ type: 'audio.append', sequence: 1, audio: 'AwQ=' }))
    await waitFor(() => received.find(event => event.type === 'audio.delta'))
    assert.equal(mock.playbackReceipts.length, 0, 'bridge must not synthesize playback receipts')
    ws.send(JSON.stringify({ type: 'playback.started', response_id: 'resp_1' }))
    ws.send(JSON.stringify({ type: 'playback.ended', response_id: 'resp_1' }))
    ws.send(JSON.stringify({ type: 'audio.commit' }))
    await waitFor(() => mock.mediaEvents.some(event => event.type === 'audio.commit'))
    await waitFor(() => bridge.ledger.get(requestId)?.state === 'completed')
    assert.equal(bridge.ledger.get(requestId).result.text, '现在是上午九点。')
    assert.deepEqual(mock.playbackReceipts.map(event => event.type), ['playback.started', 'playback.ended'])
    assert.equal(mock.mediaEvents.filter(event => event.type === 'audio.append').length, 2)
    ws.send(JSON.stringify({ type: 'close' }))
    await new Promise(resolve => ws.once('close', resolve))
  })

  it('rejects duplicate/gapped frames and releases ownership after disconnect', async () => {
    const first = connect('req_bad_sequence', 'session-bad')
    await new Promise((resolve, reject) => { first.ws.once('open', resolve); first.ws.once('error', reject) })
    first.ws.send(JSON.stringify({ type: 'start', protocol_version: 1, request_id: 'req_bad_sequence', session_id: 'session-bad' }))
    await waitFor(() => first.received.some(event => event.type === 'ready'))
    first.ws.send(JSON.stringify({ type: 'audio.append', sequence: 1, audio: 'AQI=' }))
    await waitFor(() => first.received.some(event => event.code === 'ERR_STREAM_SEQUENCE'))
    if (first.ws.readyState !== WebSocket.CLOSED) await new Promise(resolve => first.ws.once('close', resolve))

    await waitFor(() => bridge.supervisor.mediaSession === null)
  })
})
