// ESS-744：入站缓冲上限。WSS 帧级 maxPayload + 有界待处理队列/背压；
// SSE 单事件与总缓冲上限。全部断言“超限后结构化失败并断链”，而不是静默丢弃。

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

import assert from 'node:assert/strict'
import http from 'node:http'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, describe, it } from 'node:test'
import WebSocket from 'ws'

import { GatewayClient } from '../gateway.mjs'
import { createBridge } from '../server.mjs'
import { BridgeClient, waitFor } from './client.mjs'
import { MockGateway } from './mock-gateway.mjs'

const TMP = mkdtempSync(join(tmpdir(), 'ess744-'))

// ---- SSE ------------------------------------------------------------------

// 精确控制分片边界：真实 socket 的 chunk 切分由内核决定，无法稳定复现
// “单个 chunk 一次性冲垮总缓冲”这类边界。业务解析逻辑与传输无关，
// 用注入的 fetch 造流即可，同时另有一条真 HTTP 用例覆盖端到端行为。
function fakeSseFetch(chunks) {
  const encoder = new TextEncoder()
  return async () => ({
    ok: true,
    status: 200,
    headers: new Headers({ 'content-type': 'text/event-stream' }),
    body: (async function* () {
      for (const chunk of chunks) yield encoder.encode(chunk)
    })(),
  })
}

const sseEvent = payload => `data: ${JSON.stringify(payload)}\n\n`

async function drain(iterator) {
  const events = []
  for await (const event of iterator) events.push(event)
  return events
}

describe('ESS-744 SSE inbound buffer bounds', () => {
  it('accepts normal events and keeps the byte accounting exact across many frames', async () => {
    // 单事件上限 1KiB、总缓冲 2KiB，却要放行 2000 条小事件——
    // 只有消费后正确回收字节计数才可能通过。
    const client = new GatewayClient({
      baseUrl: 'http://example.invalid',
      sseMaxEventBytes: 1024,
      sseMaxBufferBytes: 2048,
      fetchImpl: fakeSseFetch(Array.from({ length: 500 }, (_, i) =>
        sseEvent({ type: 'task.progress', seq: i * 4 })
        + sseEvent({ type: 'task.progress', seq: i * 4 + 1 })
        + sseEvent({ type: 'task.progress', seq: i * 4 + 2 })
        + sseEvent({ type: 'task.progress', seq: i * 4 + 3 }))),
    })
    const events = await drain(client.taskEvents('t1'))
    assert.equal(events.length, 2000)
    assert.equal(events[1999].seq, 1999)
  })

  it('rejects a single oversized event instead of buffering it', async () => {
    const client = new GatewayClient({
      baseUrl: 'http://example.invalid',
      sseMaxEventBytes: 1024,
      sseMaxBufferBytes: 1024 * 1024,
      fetchImpl: fakeSseFetch([
        sseEvent({ type: 'task.progress', seq: 0 }),
        sseEvent({ type: 'task.progress', text: 'x'.repeat(4096) }),
        sseEvent({ type: 'task.completed' }),
      ]),
    })
    const events = []
    await assert.rejects(async () => {
      for await (const event of client.taskEvents('t1')) events.push(event)
    }, e => e.code === 'ERR_UPSTREAM_EVENT_TOO_LARGE')
    assert.deepEqual(events.map(e => e.seq), [0], '超限前已成帧的事件仍然交付')
  })

  it('rejects a delimiter-free stream before it can exhaust the heap', async () => {
    const client = new GatewayClient({
      baseUrl: 'http://example.invalid',
      sseMaxEventBytes: 4096,
      sseMaxBufferBytes: 1024 * 1024,
      // 永远不出现 `\n\n`：旧实现下 buffer 只增不减，直到 OOM。
      fetchImpl: fakeSseFetch(Array.from({ length: 10_000 }, () => 'data: '.padEnd(512, 'x'))),
    })
    await assert.rejects(
      () => drain(client.taskEvents('t1')),
      e => e.code === 'ERR_UPSTREAM_EVENT_TOO_LARGE' && /unterminated/.test(e.detail),
    )
  })

  it('rejects a burst chunk that overshoots the total buffer cap', async () => {
    const client = new GatewayClient({
      baseUrl: 'http://example.invalid',
      sseMaxEventBytes: 1024,
      sseMaxBufferBytes: 4096,
      // 单条事件都合法，但一个 chunk 里塞了 16KiB —— 总缓冲上限兜住它。
      fetchImpl: fakeSseFetch([
        Array.from({ length: 200 }, (_, i) => sseEvent({ type: 'task.progress', seq: i })).join(''),
      ]),
    })
    await assert.rejects(
      () => drain(client.taskEvents('t1')),
      e => e.code === 'ERR_UPSTREAM_STREAM_OVERFLOW',
    )
  })

  it('tears down the real upstream connection when a live stream overflows', async () => {
    let closed = false
    const upstream = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
      res.on('close', () => { closed = true })
      const timer = setInterval(() => res.write('data: '.padEnd(1024, 'x')), 1) // 无分隔符
      res.on('close', () => clearInterval(timer))
    })
    await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve))
    try {
      const client = new GatewayClient({
        baseUrl: `http://127.0.0.1:${upstream.address().port}`,
        sseMaxEventBytes: 8192,
      })
      await assert.rejects(
        () => drain(client.taskEvents('t1')),
        e => e.code === 'ERR_UPSTREAM_EVENT_TOO_LARGE',
      )
      await waitFor(() => closed, { timeoutMs: 5_000 })
    } finally {
      await new Promise(resolve => upstream.close(resolve))
    }
  })
})

// ---- WSS ------------------------------------------------------------------

const CERT = join(TMP, 'bridge.crt')
const KEY = join(TMP, 'bridge.key')
execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-keyout', KEY, '-out', CERT,
  '-days', '1', '-nodes', '-subj', '/CN=127.0.0.1'], { stdio: 'ignore' })

describe('ESS-744 WSS inbound frame and queue bounds', () => {
  let mock, bridge, client, baseUrl
  const MAX_QUEUED = 4

  before(async () => {
    // requireAudioCommit=false：本组用例故意不走到 audio.commit（超限即断链），
    // 而 mock 的等待 commit 分支会 10ms 自重排到永远，拖住测试进程不退出。
    mock = new MockGateway({ scenario: 'direct' })
    const gatewayUrl = await mock.start()
    const stateDir = join(TMP, 'state')
    bridge = createBridge({
      port: 0, bind_tailscale_ip: 'none', tls_cert: CERT, tls_key: KEY,
      state_dir: stateDir, gateway_url: gatewayUrl, realtime_media_v1: true,
      probe_timeout_ms: 500, events_heartbeat_ms: 60_000,
      realtime_media_max_queued_messages: MAX_QUEUED,
    })
    const [server] = await bridge.start()
    baseUrl = `https://127.0.0.1:${server.address().port}`
    client = new BridgeClient({ baseUrl })
    const code = readFileSync(join(stateDir, 'pairing-code.txt'), 'utf8').trim()
    assert.equal((await client.pair(code)).status, 201)
  })
  after(async () => { await bridge.stop(); await mock.stop() })

  function connectMedia(requestId, sessionId) {
    const path = '/v1/voice/realtime'
    const headers = client.signHeaders('GET', path, Buffer.alloc(0), requestId)
    const ws = new WebSocket(baseUrl.replace(/^http/, 'ws')
      + `${path}?request_id=${encodeURIComponent(requestId)}&session_id=${encodeURIComponent(sessionId)}`,
    { headers, rejectUnauthorized: false })
    const received = []
    ws.on('message', raw => received.push(JSON.parse(raw.toString())))
    return { ws, received }
  }

  const opened = ws => new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
  const closeCode = ws => new Promise(resolve => ws.once('close', code => resolve(code)))

  it('closes the events socket with 1009 on an oversized frame', async () => {
    const { ws } = client.events()
    await opened(ws)
    ws.send(JSON.stringify({ type: 'voice.stream.fallback', pad: 'x'.repeat(1024 * 1024) }))
    assert.equal(await closeCode(ws), 1009)
  })

  it('closes the media socket with 1009 on an oversized frame', async () => {
    const requestId = 'req_oversized_frame'
    const { ws } = connectMedia(requestId, 'session-oversized')
    await opened(ws)
    ws.send(JSON.stringify({ type: 'start', protocol_version: 1, request_id: requestId, pad: 'x'.repeat(1024 * 1024) }))
    assert.equal(await closeCode(ws), 1009)
    await waitFor(() => bridge.supervisor.mediaSession === null)
  })

  it('still accepts a legitimate max-size audio frame (base64 inflation is budgeted)', async () => {
    const requestId = 'req_max_frame'
    const sessionId = 'session-max-frame'
    const { ws, received } = connectMedia(requestId, sessionId)
    await opened(ws)
    ws.send(JSON.stringify({ type: 'start', protocol_version: 1, request_id: requestId, session_id: sessionId }))
    await waitFor(() => received.some(event => event.type === 'ready'))
    // 解码后正好 64KiB（realtime_media_max_frame_bytes），base64 后 ~87KiB：
    // maxPayload 若按未膨胀的帧长设定，这里就会被误杀。
    const frame = Buffer.alloc(65_536, 7).toString('base64')
    ws.send(JSON.stringify({ type: 'audio.append', sequence: 0, audio: frame }))
    await waitFor(() => mock.mediaEvents.some(event => event.type === 'audio.append'))
    assert.equal(received.some(event => event.type === 'error'), false)
    ws.send(JSON.stringify({ type: 'close' }))
    await closeCode(ws)
    await waitFor(() => bridge.supervisor.mediaSession === null)
  })

  it('fails the media socket with ERR_STREAM_OVERLOAD on an inbound burst', async () => {
    const requestId = 'req_inbound_burst'
    const sessionId = 'session-burst'
    const { ws, received } = connectMedia(requestId, sessionId)
    await opened(ws)
    // start 之后立刻灌帧：chain 还阻塞在 openMediaSession 的上游往返上，
    // 所有帧都堆在待处理队列里 —— 正是旧实现无界增长的窗口。
    ws.send(JSON.stringify({ type: 'start', protocol_version: 1, request_id: requestId, session_id: sessionId }))
    const audio = Buffer.alloc(128, 3).toString('base64')
    for (let i = 0; i < 500; i += 1) {
      ws.send(JSON.stringify({ type: 'audio.append', sequence: i, audio }))
    }
    await waitFor(() => received.some(event => event.code === 'ERR_STREAM_OVERLOAD'))
    if (ws.readyState !== WebSocket.CLOSED) await closeCode(ws)
    await waitFor(() => bridge.supervisor.mediaSession === null)
  })
})
