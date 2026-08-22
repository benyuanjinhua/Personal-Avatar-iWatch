#!/usr/bin/env node
// Audio Realtime Agent Gateway — server entry (ESS-403).
//
// Composes:
//   • HTTPS listener (TLS by default; dev-only ws:// gated behind an
//     explicit config flag and refuses to bind non-loopback in plain mode)
//   • POST /v1/realtime/session-token       (HMAC device signature → ephemeral token)
//   • POST /v1/realtime/session-token/revoke (HMAC device signature)
//   • GET  /v1/health
//   • WSS  /api/realtime                    (Bearer <token>, single upgrade)
//
// Provider credentials stay in the existing qwen-audio-agent service. The
// production adapter talks only to its loopback WSS; the mock remains for
// deterministic protocol tests.

import http from 'node:http'
import https from 'node:https'
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { WebSocketServer } from 'ws'

import { createLogger } from './logging.mjs'
import { DeviceStore, AuthError } from './device-auth.mjs'
import { TokenIssuer, IssuerError } from './token-issuer.mjs'
import { RealtimeSession } from './realtime-session.mjs'
import { MockAgentTransport } from './agent-transport.mjs'
import { QwenAgentTransport } from './qwen-agent-transport.mjs'
import { FallbackJobQueue } from './fallback-job-queue.mjs'
import { createFallbackExecutor } from './fallback-executor.mjs'
import { verifyServiceRequest } from './service-auth.mjs'

const BASE = dirname(fileURLToPath(import.meta.url))

const DEFAULT_CONFIG_PATH = join(BASE, 'config.json')

export function createGateway(overrides = {}) {
  const fileConfig = readConfig(overrides.config_path ?? DEFAULT_CONFIG_PATH)
  const CONFIG = { ...fileConfig, ...overrides }

  // Provider key is NEVER read from config.json. This defends against the
  // easy mistake of committing it to disk.
  const providerKeyEnv = CONFIG.provider_key_env ?? 'AUDIO_REALTIME_PROVIDER_KEY'
  const providerKey = process.env[providerKeyEnv] ?? null

  const log = createLogger()
  const stateDir = resolve(BASE, CONFIG.state_dir)
  const devices = new DeviceStore({
    stateDir, timestampSkewMs: CONFIG.timestamp_skew_ms, log: r => log.raw(r),
  })
  const issuer = new TokenIssuer({
    maxTtlMs: CONFIG.max_token_ttl_ms, defaultTtlMs: CONFIG.default_token_ttl_ms,
    protocolVersion: CONFIG.protocol_version,
    // Bounded issuer state (ESS-743): swept on a timer this server owns, and
    // capped so an authenticated device cannot grow the maps without limit.
    generationTtlMs: CONFIG.generation_ttl_ms,
    maxTokens: CONFIG.max_tokens,
    maxTokensPerDevice: CONFIG.max_tokens_per_device,
    maxDevices: CONFIG.max_generation_devices,
    maxSessionsPerDevice: CONFIG.max_generation_sessions_per_device,
    sweepIntervalMs: CONFIG.token_sweep_interval_ms,
    log: (evt, extra) => log(evt, extra),
  })
  const agentTransport = createAgentTransport(CONFIG, { log, providerKey })
  const realtimeTurns = new Map()
  // ESS-958: 同 scope（device/session/request/generation）只允许一个活跃
  // 会话。重复 upgrade 会导致新会话 nextUplinkSequence 归零，而客户端续发
  // sequence 必然 ERR_STREAM_SEQUENCE，形成重连风暴。value 为 ws 句柄，
  // close 时删除。
  const activeScopes = new Map()
  // ESS-958: 同 device_id + request_id 的握手限速。单个客户端 bug 不应
  // 能把上游连接打 256 次。key=device:request，value=最近一次握手时间。
  const handshakeTimes = new Map()
  const HANDSHAKE_MIN_INTERVAL_MS = CONFIG.handshake_min_interval_ms ?? 1_000
  const fallbackSecret = readServiceSecret(CONFIG)
  const fallbackQueue = new FallbackJobQueue({
    stateDir, execute: createFallbackExecutor({
      agentTransport, timeoutMs: CONFIG.fallback_upstream_timeout_ms ?? 30_000,
    }),
    turnState: requestId => realtimeTurns.get(requestId) ?? null,
    ownerBusy: () => [...realtimeTurns.values()].some(state => state === 'active'),
    maxJobs: CONFIG.fallback_queue_max_jobs ?? 64,
    queueTimeoutMs: CONFIG.fallback_queue_timeout_ms ?? 30_000,
    turnStateMaxEntries: CONFIG.fallback_turn_state_max_entries ?? 2048,
    log: (evt, extra) => log(evt, extra),
  })
  const setRealtimeTurnState = (requestId, state) => {
    if (state === 'active') realtimeTurns.set(requestId, state)
    else realtimeTurns.delete(requestId)
    fallbackQueue.markTurnState(requestId, state)
  }

  const wss = new WebSocketServer({ noServer: true })

  const server = createHttpListener(CONFIG, {
    devices, issuer, log, protocolVersion: CONFIG.protocol_version,
    fallbackQueue, fallbackSecret,
  })
  const fallbackServer = CONFIG.fallback_jobs_enabled === true && CONFIG.dev_allow_plain_ws !== true
    ? createFallbackListener(CONFIG, { fallbackQueue, fallbackSecret, log }) : null

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'https://x')
    if (url.pathname !== '/api/realtime') {
      return refuseUpgrade(socket, 404, 'ERR_NOT_FOUND')
    }
    if (!sourceAllowed(CONFIG, socket)) {
      log('ws_upgrade_rejected', { code: 'ERR_SOURCE_NOT_ALLOWED', ip: peerIp(socket) })
      return refuseUpgrade(socket, 403, 'ERR_SOURCE_NOT_ALLOWED')
    }
    const bearer = extractBearer(req.headers.authorization)
    if (!bearer) {
      log('ws_upgrade_rejected', { code: 'ERR_TOKEN_INVALID', reason: 'missing_bearer' })
      return refuseUpgrade(socket, 401, 'ERR_TOKEN_INVALID')
    }
    const presentedScope = {
      device_id: url.searchParams.get('device_id') ?? '',
      session_id: url.searchParams.get('session_id') ?? '',
      request_id: url.searchParams.get('request_id') ?? '',
      generation: Number(url.searchParams.get('generation')),
    }
    // ESS-843 降级：开发期万能 token。与客户端同字面量直接放行，跳过
    // issuer.consume 的单次消耗/失效/scope 校验——让 token 管理不再影响
    // 实时主链路。上线前必须删除并恢复单次 token 流程。
    const UNIVERSAL_TOKEN = CONFIG.dev_universal_token ?? 'rtk_dev_universal'
    let scope
    if (bearer === UNIVERSAL_TOKEN) {
      scope = {
        ...presentedScope,
        device_id: presentedScope.device_id || 'dev_universal',
      }
      log('ws_upgrade', {
        request_id: scope.request_id, session_id: scope.session_id,
        generation: scope.generation, device_id: scope.device_id,
        token_mode: 'universal',
      })
    } else {
      try { scope = issuer.consume(bearer, presentedScope) }
      catch (error) {
        log('ws_upgrade_rejected', {
          code: error.code ?? 'ERR_TOKEN_INVALID',
          request_id: presentedScope.request_id || null,
          session_id: presentedScope.session_id || null,
        })
        return refuseUpgrade(socket, error.status ?? 401, error.code ?? 'ERR_TOKEN_INVALID')
      }
    }
    // Reserve the process-wide voice lease before handing the socket to ws.
    // A fallback executor already holding it wins; the Watch retries rather
    // than opening a second upstream owner and forcing takeover.
    if (fallbackQueue.isExecuting()) {
      log('ws_upgrade_rejected', { code: 'ERR_VOICE_BUSY', request_id: scope.request_id })
      return refuseUpgrade(socket, 503, 'ERR_VOICE_BUSY')
    }
    // ESS-958: 同 scope 的重复 upgrade 拒绝。一个 request_id 只有一个合法
    // 会话；重复 upgrade 会新建 nextUplinkSequence=0 的会话，客户端续发
    // sequence 必然 ERR_STREAM_SEQUENCE。给可区分的错误码，不「建了就死」。
    const scopeKey = [scope.device_id, scope.session_id, scope.request_id, scope.generation].join(':')
    if (activeScopes.has(scopeKey)) {
      log('ws_upgrade_rejected', {
        code: 'ERR_SCOPE_ALREADY_ACTIVE',
        request_id: scope.request_id, session_id: scope.session_id,
        generation: scope.generation, device_id: scope.device_id,
      })
      return refuseUpgrade(socket, 409, 'ERR_SCOPE_ALREADY_ACTIVE')
    }
    // ESS-958: 同 device+request 的握手限速。单个客户端 bug 不应能把上游
    // 连接打 256 次（真机实测 47s 内 256 次重连）。
    const handshakeKey = `${scope.device_id}:${scope.request_id}`
    const now = Date.now()
    const lastHandshake = handshakeTimes.get(handshakeKey)
    if (lastHandshake !== undefined && now - lastHandshake < HANDSHAKE_MIN_INTERVAL_MS) {
      log('ws_upgrade_rejected', {
        code: 'ERR_HANDSHAKE_RATE_LIMITED',
        request_id: scope.request_id, session_id: scope.session_id,
        retry_after_ms: HANDSHAKE_MIN_INTERVAL_MS - (now - lastHandshake),
      })
      return refuseUpgrade(socket, 429, 'ERR_HANDSHAKE_RATE_LIMITED')
    }
    handshakeTimes.set(handshakeKey, now)
    // 限速表本身要有界：定期清理超过 1 分钟的条目，避免无界增长。
    if (handshakeTimes.size > 4096) {
      const cutoff = now - 60_000
      for (const [k, t] of handshakeTimes) if (t < cutoff) handshakeTimes.delete(k)
    }
    setRealtimeTurnState(scope.request_id, 'active')
    activeScopes.set(scopeKey, socket)
    wss.handleUpgrade(req, socket, head, ws => {
      log('ws_upgrade', {
        request_id: scope.request_id, session_id: scope.session_id,
        generation: scope.generation, device_id: scope.device_id,
      })
      const guarded = createDownlinkGuard({
        ws, scope, log: (evt, extra) => log(evt, extra),
        maxBufferedBytes: CONFIG.max_downlink_buffered_bytes,
        warnBufferedBytes: CONFIG.downlink_backpressure_warn_bytes,
        closeGraceMs: CONFIG.downlink_close_grace_ms,
      })
      const send = text => {
        let stateChanged = false
        try {
          const event = JSON.parse(text)
          if (event.type === 'audio.done') { setRealtimeTurnState(scope.request_id, 'downlink_done'); stateChanged = true }
          if (event.type === 'error') { setRealtimeTurnState(scope.request_id, 'failed'); stateChanged = true }
        } catch { /* RealtimeSession emits JSON only; guard remains authoritative */ }
        guarded.send(text)
        if (stateChanged) void fallbackQueue.drain()
      }
      const session = new RealtimeSession({
        scope,
        send,
        close: (code, reason) => ws.close(code, String(reason).slice(0, 120)),
        agentTransport,
        log: (evt, extra) => log(evt, extra),
        protocolVersion: CONFIG.protocol_version,
        heartbeatIntervalMs: CONFIG.heartbeat_interval_ms,
        idleDisconnectMs: CONFIG.idle_disconnect_ms,
        maxFrameBytes: CONFIG.max_frame_bytes,
        maxEventsPerSecond: CONFIG.max_events_per_second,
        maxUplinkBytesPerSecond: CONFIG.max_uplink_bytes_per_second,
        maxDownlinkFrames: CONFIG.max_downlink_frames,
        maxDownlinkBytes: CONFIG.max_downlink_bytes,
      })
      ws.on('message', (raw, isBinary) => {
        if (isBinary) return session.onBinary()
        try {
          const event = JSON.parse(raw.toString('utf8'))
          if (event.type === 'playback.ended') {
            setRealtimeTurnState(scope.request_id, 'playback_ended'); void fallbackQueue.drain()
          }
        } catch { /* session validates and reports malformed frames */ }
        session.onFrame(raw.toString('utf8'))
      })
      ws.once('close', (code, reason) => {
        guarded.dispose()
        activeScopes.delete(scopeKey)
        if (realtimeTurns.get(scope.request_id) === 'active') setRealtimeTurnState(scope.request_id, 'failed')
        void fallbackQueue.drain()
        session.onSocketClose(code, reason?.toString())
      })
      ws.once('error', error => {
        guarded.dispose()
        activeScopes.delete(scopeKey)
        setRealtimeTurnState(scope.request_id, 'failed'); void fallbackQueue.drain()
        session.onSocketClose(1006, 'socket_error:' + error.message)
      })
    })
  })

  async function start() {
    if (fallbackServer) await new Promise((resolveStart, rejectStart) => {
      fallbackServer.once('error', rejectStart)
      fallbackServer.listen({ host: CONFIG.fallback_bind ?? '127.0.0.1', port: CONFIG.fallback_port ?? 8445 }, resolveStart)
    })
    return new Promise((resolveStart, rejectStart) => {
      server.listen({ host: CONFIG.bind, port: CONFIG.port }, err => {
        if (err) return rejectStart(err)
        issuer.startSweeper()
        log('gateway_ready', {
          bind: CONFIG.bind, port: server.address().port,
          public_host: CONFIG.public_host ?? null,
          tls: !CONFIG.dev_allow_plain_ws,
          protocol_version: CONFIG.protocol_version,
          provider_key_present: Boolean(providerKey),
        })
        resolveStart(server)
      })
    })
  }
  async function stop() {
    issuer.stopSweeper()
    await fallbackQueue.dispose()
    return new Promise(resolveStop => {
      wss.close(() => server.close(() => {
        if (fallbackServer?.listening) fallbackServer.close(() => resolveStop())
        else resolveStop()
      }))
    })
  }

  return { server, fallbackServer, wss, devices, issuer, agentTransport, fallbackQueue, config: CONFIG, log, start, stop }
}

// Slow-consumer backpressure (ESS-746). `ws.send` never blocks: on a Watch
// whose radio has stalled the frames pile up in the socket's write buffer and
// the process pays for them, so the buffer depth is the only signal that the
// peer stopped draining. Two thresholds: one observable warning, then an
// explicit disconnect (1013 try-again-later) — the client already reconnects
// per turn, so cutting a wedged socket is cheaper than growing it. `close()`
// itself queues behind the backlog, hence the terminate fallback.
export function createDownlinkGuard({
  ws, scope, log = () => {},
  maxBufferedBytes = 4 * 1024 * 1024,
  warnBufferedBytes = 1 * 1024 * 1024,
  closeGraceMs = 5_000,
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = t => clearTimeout(t),
}) {
  let tripped = false
  let warned = false
  let graceTimer = null
  const base = () => ({
    request_id: scope?.request_id ?? null, session_id: scope?.session_id ?? null,
    generation: scope?.generation ?? null,
  })

  const send = text => {
    if (tripped) return
    const buffered = ws.bufferedAmount ?? 0
    // Charge the frame we are about to queue, not just the backlog already
    // there (ESS-792 review): checking `bufferedAmount` alone would let one
    // more frame cross the cap and only trip on the *next* send, making the
    // ceiling soft by up to one frame. Projecting keeps it a hard cap.
    const projected = buffered + Buffer.byteLength(text)
    if (projected > maxBufferedBytes) {
      tripped = true
      log('downlink_backpressure_disconnect', {
        ...base(), code: 'ERR_SLOW_CONSUMER',
        buffered_bytes: buffered, projected_bytes: projected, cap: maxBufferedBytes,
      })
      try { ws.close(1013, 'ERR_SLOW_CONSUMER') } catch { /* already dead */ }
      if (closeGraceMs > 0) {
        graceTimer = setTimer(() => {
          graceTimer = null
          try { ws.terminate?.() } catch { /* already dead */ }
        }, closeGraceMs)
        graceTimer?.unref?.()
      }
      return
    }
    if (!warned && projected > warnBufferedBytes) {
      warned = true
      log('downlink_backpressure_warning', {
        ...base(), buffered_bytes: buffered, projected_bytes: projected,
        warn_at: warnBufferedBytes, cap: maxBufferedBytes,
      })
    }
    ws.send(text)
  }

  const dispose = () => {
    if (graceTimer !== null) { clearTimer(graceTimer); graceTimer = null }
  }

  return { send, dispose, tripped: () => tripped }
}

function readConfig(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return {} }
}

function readServiceSecret(CONFIG) {
  const envValue = process.env[CONFIG.fallback_hmac_secret_env ?? 'FALLBACK_JOB_HMAC_SECRET']
  if (envValue) return envValue
  if (!CONFIG.fallback_hmac_secret_file) return ''
  try { return readFileSync(resolve(BASE, CONFIG.fallback_hmac_secret_file), 'utf8').trim() } catch { return '' }
}

function createFallbackListener(CONFIG, { fallbackQueue, fallbackSecret, log }) {
  const bind = CONFIG.fallback_bind ?? '127.0.0.1'
  if (!['127.0.0.1', '::1', 'localhost'].includes(bind)) throw new Error('fallback_bind must be loopback')
  return http.createServer((req, res) => {
    const url = new URL(req.url, 'http://loopback')
    const match = /^\/v1\/fallback-jobs\/([^/]+)$/.exec(url.pathname)
    if (!match || !['POST', 'GET', 'DELETE'].includes(req.method)) return writeJson(res, 404, { error: 'ERR_NOT_FOUND' })
    if (!['127.0.0.1', '::1'].includes(peerIp(req.socket))) return writeJson(res, 403, { error: 'ERR_SOURCE_NOT_ALLOWED' })
    return handleFallbackJob(req, res, {
      queue: fallbackQueue, secret: fallbackSecret, log, pathName: url.pathname,
      requestId: decodeURIComponent(match[1]), method: req.method,
      maxBytes: CONFIG.fallback_max_audio_bytes ?? 5 * 1024 * 1024,
    })
  })
}

function createHttpListener(CONFIG, { devices, issuer, log, protocolVersion, fallbackQueue, fallbackSecret }) {
  const requestHandler = (req, res) => {
    const ip = peerIp(req.socket)
    if (!sourceAllowed(CONFIG, req.socket)) {
      log('http_rejected', { code: 'ERR_SOURCE_NOT_ALLOWED', ip, path: req.url })
      return writeJson(res, 403, { error: 'ERR_SOURCE_NOT_ALLOWED' })
    }
    const url = new URL(req.url, 'https://x')
    if (req.method === 'GET' && url.pathname === '/v1/health') {
      return writeJson(res, 200, { ok: true, service: 'audio-realtime-gateway', protocol_version: protocolVersion })
    }
    const fallbackMatch = /^\/v1\/fallback-jobs\/([^/]+)$/.exec(url.pathname)
    // The public TLS listener exposes this route only in loopback dev tests.
    // Production uses the dedicated loopback listener above, so widening WSS
    // CIDRs can never widen the fallback control plane by accident.
    if (CONFIG.dev_allow_plain_ws === true && CONFIG.fallback_jobs_enabled === true &&
      fallbackMatch && ['POST', 'GET', 'DELETE'].includes(req.method)) {
      return handleFallbackJob(req, res, {
        queue: fallbackQueue, secret: fallbackSecret, log, pathName: url.pathname,
        requestId: decodeURIComponent(fallbackMatch[1]), method: req.method,
        maxBytes: CONFIG.fallback_max_audio_bytes ?? 5 * 1024 * 1024,
      })
    }
    if (req.method === 'POST' && url.pathname === '/v1/realtime/session-token') {
      return handleSignedJson(req, res, ({ body, deviceId }) => {
        const scope = issuer.issue(body, { authDeviceId: deviceId })
        writeJson(res, 201, {
          token: scope.token, expires_at: scope.expires_at, ttl_ms: scope.ttl_ms,
          scope: scope.scope, jti: scope.jti,
        })
      }, { devices, log, pathName: url.pathname })
    }
    if (req.method === 'POST' && url.pathname === '/v1/realtime/session-token/revoke') {
      return handleSignedJson(req, res, ({ body }) => {
        if (typeof body.jti !== 'string') throw new IssuerError(['ERR_MISSING_FIELD', 400], 'jti')
        const removed = issuer.revokeByJti(body.jti)
        writeJson(res, 200, { revoked: removed })
      }, { devices, log, pathName: url.pathname })
    }
    return writeJson(res, 404, { error: 'ERR_NOT_FOUND' })
  }

  if (CONFIG.dev_allow_plain_ws) {
    if (CONFIG.bind !== '127.0.0.1' && CONFIG.bind !== '::1' && CONFIG.bind !== 'localhost') {
      throw new Error('dev_allow_plain_ws=true requires binding to loopback only')
    }
    return http.createServer(requestHandler)
  }
  // Resolve against the module directory, NOT process.cwd() — same base as
  // `state_dir` above. A deployment script that launches `node <abs>/server.mjs`
  // from another cwd must find the same cert files as `npm start` (ESS-428).
  const cert = readFileSync(resolve(BASE, CONFIG.tls_cert))
  const key = readFileSync(resolve(BASE, CONFIG.tls_key))
  return https.createServer({ cert, key }, requestHandler)
}

function handleSignedJson(req, res, act, { devices, log, pathName }) {
  const chunks = []
  let bytes = 0
  const cap = 1 * 1024 * 1024
  req.on('data', chunk => {
    bytes += chunk.length
    if (bytes > cap) {
      log('http_rejected', { code: 'ERR_BODY_TOO_LARGE', path: pathName })
      writeJson(res, 413, { error: 'ERR_BODY_TOO_LARGE' })
      req.destroy()
      return
    }
    chunks.push(chunk)
  })
  req.on('end', () => {
    const rawBody = Buffer.concat(chunks)
    let body = {}
    if (rawBody.length) {
      try { body = JSON.parse(rawBody.toString('utf8')) }
      catch { return writeJson(res, 400, { error: 'ERR_BAD_JSON' }) }
    }
    let auth
    try {
      auth = devices.verify({
        headers: req.headers, method: req.method, pathName, rawBody,
      })
    } catch (error) {
      if (error instanceof AuthError) {
        log('http_rejected', { code: error.code, path: pathName })
        return writeJson(res, error.status, { error: error.code })
      }
      throw error
    }
    try { act({ body, deviceId: auth.deviceId }) }
    catch (error) {
      if (error instanceof IssuerError) {
        return writeJson(res, error.status, {
          error: error.code, ...(error.detail ? { detail: String(error.detail).slice(0, 256) } : {}),
        })
      }
      log('http_error', { path: pathName, detail: String(error?.message ?? error).slice(0, 256) })
      return writeJson(res, 500, { error: 'ERR_INTERNAL' })
    }
  })
}

function handleFallbackJob(req, res, { queue, secret, log, pathName, requestId, method, maxBytes }) {
  const chunks = []; let bytes = 0
  req.on('data', chunk => {
    bytes += chunk.length
    if (bytes > Math.ceil(maxBytes * 1.4) + 4096) {
      writeJson(res, 413, { error: 'ERR_BODY_TOO_LARGE' }); req.destroy(); return
    }
    chunks.push(chunk)
  })
  req.on('end', () => {
    const rawBody = Buffer.concat(chunks)
    if (!verifyServiceRequest({ secret, headers: req.headers, method, path: pathName, body: rawBody })) {
      log('fallback_job_rejected', { request_id: requestId, reason: 'auth_failed' })
      return writeJson(res, 401, { status: 'rejected', reason: 'auth_failed' })
    }
    if (req.headers['x-request-id'] !== requestId) {
      return writeJson(res, 400, { status: 'rejected', reason: 'request_id_mismatch' })
    }
    if (method === 'GET') {
      const job = queue.get(requestId)
      return job ? writeJson(res, 200, job) : writeJson(res, 404, { error: 'ERR_NOT_FOUND' })
    }
    if (method === 'DELETE') {
      const result = queue.cancel(requestId)
      return result.status === 'not_found' ? writeJson(res, 404, { error: 'ERR_NOT_FOUND' })
        : writeJson(res, 200, { request_id: requestId, ...result })
    }
    let body
    try { body = JSON.parse(rawBody.toString('utf8')) }
    catch { return writeJson(res, 400, { status: 'rejected', reason: 'bad_json' }) }
    if (body.request_id !== requestId || body.codec !== 'pcm_s16le_16k') {
      return writeJson(res, 400, { status: 'rejected', reason: 'invalid_job' })
    }
    let audio
    try { audio = Buffer.from(body.audio_base64, 'base64') } catch { audio = Buffer.alloc(0) }
    if (!audio.length || audio.length > maxBytes) return writeJson(res, 413, { status: 'rejected', reason: 'audio_too_large' })
    const parentRequestId = typeof body.parent_request_id === 'string' && body.parent_request_id.length <= 128
      ? body.parent_request_id : null
    const contextSummary = typeof body.context_summary === 'string' && body.context_summary.length <= 4000
      ? body.context_summary : null
    const result = queue.submit({ requestId, audio, audioSha256: body.audio_sha256,
      parentRequestId, contextSummary })
    const status = result.status === 'accepted' || result.status === 'duplicate' ? 202 : 409
    writeJson(res, status, { request_id: requestId, ...result })
  })
}

function writeJson(res, status, obj) {
  if (res.writableEnded) return
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(JSON.stringify(obj))
}

// ESS-886: the character class must include `_`. Minted tokens are
// `rtk_<hex>`, but the ESS-843 dev universal token is `rtk_dev_universal` —
// with `[A-Za-z0-9]` only, the first underscore after `rtk_` made the regex
// fail and every universal-token upgrade died at the `missing_bearer` gate
// (server.mjs:80) before ever reaching the allow branch (server.mjs:94).
export function extractBearer(header) {
  if (!header || typeof header !== 'string') return null
  const match = /^Bearer\s+(rtk_[A-Za-z0-9_]+)$/.exec(header.trim())
  return match ? match[1] : null
}

function peerIp(socket) {
  const raw = socket?.remoteAddress ?? ''
  return raw.startsWith('::ffff:') ? raw.slice(7) : raw
}

function sourceAllowed(CONFIG, socket) {
  const ip = peerIp(socket)
  if (!ip) return false
  if (ip === '127.0.0.1' || ip === '::1') return true
  const entries = Array.isArray(CONFIG.allowed_peer_ips) ? CONFIG.allowed_peer_ips : []
  return entries.some(entry => ipMatches(ip, entry))
}

function ipMatches(ip, entry) {
  if (!entry) return false
  if (!entry.includes('/')) return ip === entry
  const [prefix, bitsStr] = entry.split('/')
  const bits = Number(bitsStr)
  if (!Number.isInteger(bits) || bits < 0 || bits > 32) return false
  const ipInt = ipv4ToInt(ip); const prefixInt = ipv4ToInt(prefix)
  if (ipInt === null || prefixInt === null) return false
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0
  return (ipInt & mask) === (prefixInt & mask)
}

function ipv4ToInt(ip) {
  const parts = ip.split('.').map(Number)
  if (parts.length !== 4 || parts.some(p => !Number.isInteger(p) || p < 0 || p > 255)) return null
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0
}

function refuseUpgrade(socket, status, code) {
  socket.write(
    `HTTP/1.1 ${status} ${code}\r\n` +
    'Content-Type: application/json\r\n' +
    'Connection: close\r\n\r\n' +
    JSON.stringify({ error: code }),
  )
  socket.destroy()
}

function createAgentTransport(CONFIG, { log }) {
  const kind = CONFIG.agent_transport ?? 'mock'
  if (kind === 'mock') return new MockAgentTransport({ log: (...args) => log('mock_agent', { detail: args.map(String).join(' ') }) })
  // Production uses the already deployed qwen-audio-agent as the provider
  // owner instead of duplicating DashScope protocol and credential handling.
  if (kind === 'agent') {
    return new QwenAgentTransport({
      gatewayUrl: CONFIG.agent_gateway_url ?? 'ws://127.0.0.1:3101/api/realtime',
      connectTimeoutMs: CONFIG.agent_connect_timeout_ms ?? 10_000,
      maxPendingBytes: CONFIG.agent_max_pending_bytes ?? 2 * 1024 * 1024,
      maxDownlinkFrameBytes: CONFIG.max_downlink_frame_bytes ?? 128 * 1024,
      maxDownlinkFrames: CONFIG.max_downlink_frames ?? 4096,
      maxDownlinkBytes: CONFIG.max_downlink_bytes ?? 32 * 1024 * 1024,
      responseTimeoutMs: CONFIG.agent_response_timeout_ms ?? 8_000,
      // ESS-969: 'auto' | 'always' | 'off'. `auto` only takes the
      // multi-segment path for a turn whose upstream proved it emits
      // `voice.state`; anything else keeps the pre-ESS-969 behaviour.
      multiSegmentMode: CONFIG.agent_multi_segment_mode ?? 'auto',
      turnIdleBackstopMs: CONFIG.agent_turn_idle_backstop_ms ?? 45_000,
      takeover: CONFIG.agent_takeover_voice !== false,
      log: (evt, extra) => log(evt, extra),
    })
  }
  throw new Error('unknown agent_transport: ' + kind)
}

// Allow running as a standalone process.
if (import.meta.url === `file://${process.argv[1]}`) {
  // Every startup failure — thrown synchronously by createGateway() (cert
  // load, dev_allow_plain_ws / agent_transport validation) or rejected by
  // start() (bind errors) — surfaces as ONE structured startup_failed line,
  // never a bare stack. The line goes to stdout (the JSONL stream the log
  // collector consumes, same as every other gateway log) and is mirrored to
  // stderr (fatal diagnostics). `detail` carries only err.message; the
  // provider key / tokens never appear in these startup error messages —
  // same redaction stance as logging.mjs.
  const failStartup = err => {
    const line = JSON.stringify({
      ts: new Date().toISOString(),
      evt: 'startup_failed',
      detail: String(err?.message ?? err).slice(0, 512),
    })
    process.stdout.write(line + '\n')
    process.stderr.write(line + '\n')
    process.exit(1)
  }
  try {
    const overrides = process.env.GATEWAY_CONFIG_PATH
      ? { config_path: process.env.GATEWAY_CONFIG_PATH }
      : {}
    const gateway = createGateway(overrides)
    gateway.start().catch(failStartup)
  } catch (err) {
    failStartup(err)
  }
}
