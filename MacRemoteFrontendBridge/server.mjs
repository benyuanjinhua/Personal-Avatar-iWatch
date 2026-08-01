#!/usr/bin/env node
// Remote Frontend Bridge — full P1 implementation (ESS-26).
//
// Northbound (iPhone over Tailscale, HTTPS + WSS, HMAC-signed):
//   POST /v1/pair
//   POST /v1/voice/turns              idempotent create; 202 accepted receipt
//   GET  /v1/voice/turns/{id}         stable projection + short result
//   POST /v1/voice/turns/{id}/cancel
//   POST /v1/voice/turns/{id}/permission
//   WSS  /v1/voice/events             state / permission / result events
//   GET  /v1/health
//
// Southbound (loopback gateway only, upstream public protocol — §7):
//   WS   /api/realtime?sessionId=watch-bridge-v1-<device>   (audio inject)
//   SSE  /api/tasks/:id/events, GET/DELETE /api/tasks/:id, POST /api/permissions/:id
//
// Red lines enforced by construction: the bridge never invokes the Codex CLI,
// accepts no command lines / working directories / env vars from clients, and
// exposes no gateway admin API northbound.

import https from 'node:https'
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { WebSocketServer } from 'ws'

import { ApiError, DeviceAuth, ERR, makeSourceGate, normalizeIp, sha256hex } from './auth.mjs'
import { TurnLedger } from './ledger.mjs'
import { GatewayClient } from './gateway.mjs'
import { TaskWatcher } from './taskwatch.mjs'
import { AudioPipeline } from './audio.mjs'
import { QwenRealtimeSessionSupervisor } from './supervisor.mjs'

const BASE = dirname(fileURLToPath(import.meta.url))

export function createBridge(overrides = {}) {
  const CONFIG = { ...JSON.parse(readFileSync(join(BASE, 'config.json'), 'utf8')), ...overrides }
  const log = obj => process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), ...obj }) + '\n')
  const stateDir = resolve(BASE, CONFIG.state_dir)

  const auth = new DeviceAuth({
    stateDir,
    timestampSkewMs: CONFIG.timestamp_skew_ms,
    pairingCodeTtlMs: CONFIG.pairing_code_ttl_ms,
    log,
  })
  const ledger = new TurnLedger({
    stateDir,
    maxResultChars: CONFIG.max_result_chars,
    maxResultAudioBytes: CONFIG.max_result_audio_bytes,
    log,
  })
  const gateway = new GatewayClient({ baseUrl: CONFIG.gateway_url, log })
  const watcher = new TaskWatcher({ gateway, ledger, config: CONFIG, log })
  watcher.startDenySweeper()   // D1：写开关关闭时全局清扫 pending 权限（no-op otherwise）
  const audio = new AudioPipeline({
    audiopipePath: resolve(BASE, CONFIG.audiopipe_path),
    allowTestPcm: CONFIG.allow_test_pcm === true,
  })
  const supervisor = new QwenRealtimeSessionSupervisor({
    gatewayUrl: CONFIG.gateway_url.replace(/^http/, 'ws') + '/api/realtime',
    deviceId: CONFIG.device_id,
    idleDisconnectMs: CONFIG.idle_disconnect_ms,
    turnTimeoutMs: CONFIG.turn_timeout_ms,
    probeTimeoutMs: CONFIG.probe_timeout_ms,
    firstEventTimeoutMs: CONFIG.first_event_timeout_ms,
    maxTurnAttempts: CONFIG.max_turn_attempts,
    log: (...args) => log({ evt: 'supervisor', detail: args.map(String).join(' ').slice(0, 500) }),
  })

  // ESS-37 取证：supervisor journal（ws.connecting/close code/error frame、
  // probe、stall、rebuild、全部网关事件摘要）落 bridge 日志——此前这些只存在
  // 于进程内 journal，真机停摆后无据可查。audio.delta 只计数不落行（高频）。
  const RT_GATEWAY_EVENTS = new Set([
    'gateway.connected', 'voice.ready', 'voice.state', 'voice.deactivated',
    'turn.started', 'audio.delta', 'audio.done', 'response.started', 'response.interrupted',
    'transcript.delta', 'transcript.final', 'transcript.discard', 'timeline.inline',
    'playback.clear', 'error',
    'task.running', 'task.delegated', 'task.finalizing', 'task.cancelling', 'task.progress',
    'task.completed', 'task.failed', 'task.cancelled',
    'task.permission.requested', 'task.permission.resolved',
  ])
  supervisor.listeners.add(entry => {
    const label = supervisor.currentTurn?.label
    if (label && RT_GATEWAY_EVENTS.has(entry.event)) ledger.bumpEvents(label)
    if (entry.event !== 'audio.delta') log({ evt: 'rt', ...entry })
  })
  const sourceAllowed = makeSourceGate(CONFIG.allowed_peer_ips)

  // ---- turn processing ----------------------------------------------------

  const workTimers = new Map() // request_id → deadline timer (realtime phase)

  function armWorkDeadline(requestId) {
    const timer = setTimeout(async () => {
      workTimers.delete(requestId)
      const turn = ledger.get(requestId)
      if (!turn || ['completed', 'failed', 'cancelled'].includes(turn.state)) return
      if (turn.task_id) return // background phase: TaskWatcher owns the deadline
      log({ evt: 'work_timeout_realtime', request_id: requestId })
      if (supervisor.currentTurn?.label === requestId) supervisor.abortCurrentTurn('work timeout')
      ledger.fail(requestId, 'ERR_WORK_TIMEOUT')
    }, CONFIG.max_work_ms)
    timer.unref?.()
    workTimers.set(requestId, timer)
  }

  function disarmWorkDeadline(requestId) {
    clearTimeout(workTimers.get(requestId))
    workTimers.delete(requestId)
  }

  async function processTurn(requestId, audioBuf, audioMeta) {
    armWorkDeadline(requestId)
    try {
      if (ledger.get(requestId)?.state === 'cancelled') return // cancelled while queued

      ledger.update(requestId, { state: 'processing', detail: 'decoding' })
      const { pcm16k } = await audio.decodeTo16k(audioBuf, audioMeta.codec)

      if (ledger.get(requestId)?.state === 'cancelled') return
      ledger.update(requestId, { state: 'processing', detail: 'realtime_processing' })
      const result = await supervisor.injectTurn(pcm16k, { label: requestId })

      if (ledger.get(requestId)?.state === 'cancelled') {
        // Result arrived after a cancel during injection — do not overwrite.
        return
      }

      if (result.taskId) {
        // Background path: only now (task event captured) is it background_accepted (§6).
        ledger.update(requestId, {
          task_id: result.taskId,
          path: 'background',
          state: 'processing',
          detail: 'background_accepted',
        })
        disarmWorkDeadline(requestId) // hand the 300s deadline to the TaskWatcher
        await watcher.watch(requestId)
        return
      }

      // Direct path: transcode the aggregated 24k reply for the Watch.
      let audioBase64 = null
      if (result.audio24k?.length) {
        try {
          audioBase64 = (await audio.encode24kToM4a(result.audio24k)).toString('base64')
        } catch (error) {
          log({ evt: 'encode_failed', request_id: requestId, err: String(error.message) })
        }
      }
      ledger.update(requestId, { path: 'direct' })
      ledger.setResult(requestId, {
        text: result.assistantTranscript,
        audioBase64,
        extra: { source: 'realtime_direct', user_transcript: result.userTranscript },
      }, 'completed')
    } catch (error) {
      const turn = ledger.get(requestId)
      if (!turn || ['completed', 'failed', 'cancelled'].includes(turn.state)) return
      if (error.cancelled) {
        ledger.update(requestId, { state: 'cancelled' })
      } else if (/work timeout/.test(String(error.message))) {
        ledger.fail(requestId, 'ERR_WORK_TIMEOUT')
      } else if (/turn timeout/.test(String(error.message))) {
        ledger.fail(requestId, 'ERR_REALTIME_TIMEOUT')
      } else if (error.stalled || error.sessionDead || error.connectionLost) {
        // 停摆已重放仍失败 / 重建后会话仍无响应：快速终态，禁止头部阻塞
        log({ evt: 'turn_stalled', request_id: requestId, err: String(error.message).slice(0, 300) })
        ledger.fail(requestId, 'ERR_REALTIME_STALLED')
      } else {
        log({ evt: 'turn_failed', request_id: requestId, err: String(error.message).slice(0, 300) })
        ledger.fail(requestId, 'ERR_PROCESSING_FAILED')
      }
    } finally {
      disarmWorkDeadline(requestId)
    }
  }

  // ---- handlers -----------------------------------------------------------

  function handleCreateTurn(rawBody, authInfo) {
    let body
    try { body = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }
    if (body.protocol_version !== CONFIG.protocol_version) throw new ApiError(ERR.PROTOCOL_VERSION)
    const requestId = body.request_id
    if (!requestId || requestId !== authInfo.requestId) {
      throw new ApiError(ERR.MISSING_FIELD, 'request_id (body must match x-request-id)')
    }
    const meta = body.audio
    if (!meta || !meta.codec || !Number.isFinite(meta.duration_ms) || !meta.sha256 || typeof body.audio_base64 !== 'string') {
      throw new ApiError(ERR.MISSING_FIELD, 'audio{codec,duration_ms,sha256}, audio_base64')
    }

    const bodySha = sha256hex(rawBody)

    // Replay/conflict check must precede payload validation so a byte-identical
    // retry of an accepted turn replays even if limits later changed (§6).
    const existing = ledger.get(requestId)
    if (existing) {
      if (existing.body_sha256 !== bodySha) throw new ApiError(ERR.IDEMPOTENCY_CONFLICT)
      log({ evt: 'turn_replayed', request_id: requestId })
      return { status: 202, body: { ...ledger.projection(existing), idempotent_replay: true } }
    }

    // Validate the payload BEFORE the ledger entry exists — a rejected request
    // must leave no persistent state behind.
    if (meta.duration_ms > CONFIG.max_duration_ms) throw new ApiError(ERR.DURATION_TOO_LONG)
    let audioBuf
    try { audioBuf = Buffer.from(body.audio_base64, 'base64') } catch { throw new ApiError(ERR.AUDIO_INVALID) }
    if (audioBuf.length === 0) throw new ApiError(ERR.AUDIO_INVALID)
    if (audioBuf.length > CONFIG.max_audio_bytes) throw new ApiError(ERR.AUDIO_TOO_LARGE)
    if (sha256hex(audioBuf) !== meta.sha256) throw new ApiError(ERR.AUDIO_HASH_MISMATCH)

    const { turn } = ledger.create({
      requestId,
      deviceId: authInfo.deviceId,
      bodySha256: bodySha,
      sessionId: supervisor.sessionId,
    })
    log({ evt: 'turn_accepted', request_id: requestId, device_id: authInfo.deviceId, audio_bytes: audioBuf.length })
    // Snapshot the `accepted` receipt before processing starts mutating state;
    // the 202 returns immediately, execution continues asynchronously.
    const receipt = ledger.projection(turn)
    processTurn(requestId, audioBuf, meta).catch(err =>
      log({ evt: 'process_turn_crashed', request_id: requestId, err: String(err) }))
    return { status: 202, body: receipt }
  }

  function handleGetTurn(requestId, authInfo) {
    const turn = ledger.get(requestId)
    if (!turn || turn.device_id !== authInfo.deviceId) throw new ApiError(ERR.NOT_FOUND)
    return { status: 200, body: ledger.projection(turn) }
  }

  async function handleCancelTurn(requestId, authInfo) {
    const turn = ledger.get(requestId)
    if (!turn || turn.device_id !== authInfo.deviceId) throw new ApiError(ERR.NOT_FOUND)
    if (['completed', 'failed'].includes(turn.state)) throw new ApiError(ERR.TURN_NOT_CANCELLABLE)
    if (turn.state === 'cancelled') return { status: 200, body: ledger.projection(turn) }

    if (turn.task_id) {
      watcher.stop(requestId, 'client-cancel')
      const ok = await watcher.cancel(requestId).catch(() => false)
      if (!ok) ledger.update(requestId, { state: 'cancelled' })
    } else {
      if (supervisor.currentTurn?.label === requestId) supervisor.abortCurrentTurn('cancelled')
      ledger.update(requestId, { state: 'cancelled' })
    }
    log({ evt: 'turn_cancelled', request_id: requestId })
    return { status: 200, body: ledger.projection(ledger.get(requestId)) }
  }

  async function handlePermission(requestId, rawBody, authInfo) {
    const turn = ledger.get(requestId)
    if (!turn || turn.device_id !== authInfo.deviceId) throw new ApiError(ERR.NOT_FOUND)
    let body
    try { body = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }

    const decision = { allow: 'always', always: 'always', deny: 'reject', reject: 'reject' }[body.decision]
    if (!decision) throw new ApiError(ERR.PERMISSION_DECISION_INVALID, 'decision must be allow|deny')
    if (!turn.permission?.id || turn.permission.id !== body.permission_id) {
      throw new ApiError(ERR.PERMISSION_UNKNOWN, 'permission_id does not match the pending permission')
    }

    const result = await gateway.respondPermission(body.permission_id, decision)
      .catch(error => { throw new ApiError(ERR.UPSTREAM_UNAVAILABLE, error.code) })
    if (!result.ok) throw new ApiError(ERR.PERMISSION_UNKNOWN, 'gateway no longer has this permission')

    ledger.update(requestId, { state: 'processing', detail: 'background_processing', permission: null })
    log({ evt: 'permission_forwarded', request_id: requestId, decision })
    return { status: 200, body: ledger.projection(ledger.get(requestId)) }
  }

  // ---- HTTP plumbing ------------------------------------------------------

  function readBody(req) {
    return new Promise((resolvePromise, reject) => {
      const chunks = []
      let size = 0
      req.on('data', c => {
        size += c.length
        if (size > CONFIG.max_body_bytes) {
          reject(new ApiError(ERR.BODY_TOO_LARGE))
          req.destroy()
          return
        }
        chunks.push(c)
      })
      req.on('end', () => resolvePromise(Buffer.concat(chunks)))
      req.on('error', reject)
    })
  }

  async function route(req, res) {
    const ip = normalizeIp(req.socket.remoteAddress || '')
    const pathName = new URL(req.url, 'https://x').pathname
    const reply = (status, body) => {
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end(JSON.stringify(body))
    }
    try {
      if (!sourceAllowed(ip)) throw new ApiError(ERR.SOURCE_NOT_ALLOWED)

      if (req.method === 'GET' && pathName === '/v1/health') {
        return reply(200, { ok: true, service: 'remote-frontend-bridge', protocol_version: CONFIG.protocol_version })
      }
      const rawBody = ['POST', 'PUT'].includes(req.method) ? await readBody(req) : Buffer.alloc(0)
      const verify = () => auth.verify({ headers: req.headers, method: req.method, pathName, rawBody })

      if (pathName === '/v1/pair') {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        let body
        try { body = JSON.parse(rawBody.toString('utf8')) } catch { throw new ApiError(ERR.BAD_JSON) }
        const paired = auth.pair(body)
        return reply(201, { ...paired, protocol_version: CONFIG.protocol_version })
      }

      if (pathName === '/v1/voice/turns') {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = handleCreateTurn(rawBody, verify())
        return reply(r.status, r.body)
      }

      let m = pathName.match(/^\/v1\/voice\/turns\/([A-Za-z0-9_-]+)$/)
      if (m) {
        if (req.method !== 'GET') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = handleGetTurn(m[1], verify())
        return reply(r.status, r.body)
      }

      m = pathName.match(/^\/v1\/voice\/turns\/([A-Za-z0-9_-]+)\/cancel$/)
      if (m) {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = await handleCancelTurn(m[1], verify())
        return reply(r.status, r.body)
      }

      m = pathName.match(/^\/v1\/voice\/turns\/([A-Za-z0-9_-]+)\/permission$/)
      if (m) {
        if (req.method !== 'POST') throw new ApiError(ERR.METHOD_NOT_ALLOWED)
        const r = await handlePermission(m[1], rawBody, verify())
        return reply(r.status, r.body)
      }

      throw new ApiError(ERR.NOT_FOUND)
    } catch (e) {
      if (e instanceof ApiError) {
        log({ evt: 'request_rejected', ip, path: pathName, code: e.code })
        if (!res.headersSent) reply(e.status, { error: e.code, detail: e.detail })
        return
      }
      log({ evt: 'internal_error', ip, path: pathName, err: String(e).slice(0, 300) })
      if (!res.headersSent) reply(500, { error: 'ERR_INTERNAL' })
    }
  }

  // ---- WSS /v1/voice/events ----------------------------------------------

  const wss = new WebSocketServer({ noServer: true })
  const eventClients = new Set() // { ws, deviceId }

  ledger.on('turn', projection => {
    const message = JSON.stringify({ type: 'turn.state', turn: projection })
    for (const client of eventClients) {
      if (client.deviceId === projection.device_id && client.ws.readyState === client.ws.OPEN) {
        client.ws.send(message)
      }
    }
  })

  function handleUpgrade(req, socket, head) {
    const ip = normalizeIp(socket.remoteAddress || '')
    const pathName = new URL(req.url, 'https://x').pathname
    const refuse = (status, code) => {
      socket.write(`HTTP/1.1 ${status} ${code}\r\nContent-Type: application/json\r\n\r\n${JSON.stringify({ error: code })}`)
      socket.destroy()
    }
    try {
      if (!sourceAllowed(ip)) return refuse(403, 'ERR_SOURCE_NOT_ALLOWED')
      if (pathName !== '/v1/voice/events') return refuse(404, 'ERR_NOT_FOUND')
      const { deviceId } = auth.verify({ headers: req.headers, method: 'GET', pathName, rawBody: Buffer.alloc(0) })
      wss.handleUpgrade(req, socket, head, ws => {
        const client = { ws, deviceId }
        eventClients.add(client)
        log({ evt: 'events_client_connected', device_id: deviceId })
        // Reconnect recovery: replay the live (non-terminal) turns for this device.
        ws.send(JSON.stringify({
          type: 'snapshot',
          turns: ledger.nonTerminal().filter(t => t.device_id === deviceId).map(t => ledger.projection(t)),
        }))
        ws.on('close', () => eventClients.delete(client))
        ws.on('error', () => eventClients.delete(client))
      })
    } catch (e) {
      const code = e instanceof ApiError ? e.code : 'ERR_INTERNAL'
      log({ evt: 'events_upgrade_rejected', ip, code })
      refuse(e instanceof ApiError ? e.status : 500, code)
    }
  }

  // ---- restart recovery (§4.1) -------------------------------------------

  function recover() {
    for (const turn of ledger.nonTerminal()) {
      if (turn.task_id) {
        // Provably safe: tasks are queryable and cancel/query are idempotent.
        log({ evt: 'recover_watch', request_id: turn.request_id, task_id: turn.task_id })
        watcher.watch(turn.request_id)
      } else {
        // Injection outcome unknown → never auto-rerun a non-idempotent turn.
        log({ evt: 'recover_unknown_outcome', request_id: turn.request_id })
        ledger.fail(turn.request_id, 'ERR_RESULT_UNKNOWN', 'manual_confirmation_required')
      }
    }
  }

  // ---- startup ------------------------------------------------------------

  function tailscaleIPv4() {
    if (CONFIG.bind_tailscale_ip === 'none') return null
    if (CONFIG.bind_tailscale_ip !== 'auto') return CONFIG.bind_tailscale_ip
    try {
      return execFileSync('tailscale', ['ip', '-4'], { encoding: 'utf8' }).trim().split('\n')[0]
    } catch {
      log({ evt: 'tailscale_ip_unavailable', note: 'binding loopback only' })
      return null
    }
  }

  const servers = []
  function start() {
    recover()
    const tlsOpts = {
      cert: readFileSync(resolve(BASE, CONFIG.tls_cert)),
      key: readFileSync(resolve(BASE, CONFIG.tls_key)),
    }
    const tsIp = tailscaleIPv4()
    const binds = [CONFIG.bind_loopback, ...(tsIp ? [tsIp] : [])] // never 0.0.0.0
    return Promise.all(binds.map(addr => new Promise((resolvePromise, reject) => {
      const server = https.createServer(tlsOpts, route)
      server.on('upgrade', handleUpgrade)
      server.listen(CONFIG.port, addr, () => {
        log({ evt: 'listening', addr, port: CONFIG.port })
        resolvePromise(server)
      })
      server.on('error', reject)
      servers.push(server)
    })))
  }

  function stop() {
    watcher.stopDenySweeper()
    watcher.stopAll()
    supervisor.close('shutdown')
    for (const client of eventClients) client.ws.close()
    for (const timer of workTimers.values()) clearTimeout(timer)
    return Promise.all(servers.map(s => new Promise(r => s.close(r))))
  }

  return { start, stop, config: CONFIG, ledger, supervisor, watcher, gateway, auth, log }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const bridge = createBridge()
  bridge.start().catch(error => {
    bridge.log({ evt: 'startup_failed', err: String(error) })
    process.exit(1)
  })
  const shutdown = () => bridge.stop().then(() => process.exit(0))
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
}
