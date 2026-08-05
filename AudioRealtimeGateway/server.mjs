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
// Provider key never leaves the server side — it's read from an env var and
// held only by the (out-of-scope for ESS-403) real Agent transport. Only the
// mock transport ships in this module.

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
    log: (evt, extra) => log(evt, extra),
  })
  const agentTransport = createAgentTransport(CONFIG, { log, providerKey })

  const wss = new WebSocketServer({ noServer: true })

  const server = createHttpListener(CONFIG, {
    devices, issuer, log, protocolVersion: CONFIG.protocol_version,
  })

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
    let scope
    try { scope = issuer.consume(bearer, presentedScope) }
    catch (error) {
      log('ws_upgrade_rejected', {
        code: error.code ?? 'ERR_TOKEN_INVALID',
        request_id: presentedScope.request_id || null,
      })
      return refuseUpgrade(socket, error.status ?? 401, error.code ?? 'ERR_TOKEN_INVALID')
    }
    wss.handleUpgrade(req, socket, head, ws => {
      log('ws_upgrade', {
        request_id: scope.request_id, session_id: scope.session_id,
        generation: scope.generation, device_id: scope.device_id,
      })
      const session = new RealtimeSession({
        scope,
        send: text => ws.send(text),
        close: (code, reason) => ws.close(code, String(reason).slice(0, 120)),
        agentTransport,
        log: (evt, extra) => log(evt, extra),
        protocolVersion: CONFIG.protocol_version,
        heartbeatIntervalMs: CONFIG.heartbeat_interval_ms,
        idleDisconnectMs: CONFIG.idle_disconnect_ms,
        maxFrameBytes: CONFIG.max_frame_bytes,
        maxEventsPerSecond: CONFIG.max_events_per_second,
        maxUplinkBytesPerSecond: CONFIG.max_uplink_bytes_per_second,
      })
      ws.on('message', (raw, isBinary) => {
        if (isBinary) return session.onBinary()
        session.onFrame(raw.toString('utf8'))
      })
      ws.once('close', (code, reason) => session.onSocketClose(code, reason?.toString()))
      ws.once('error', error => session.onSocketClose(1006, 'socket_error:' + error.message))
    })
  })

  async function start() {
    return new Promise((resolveStart, rejectStart) => {
      server.listen({ host: CONFIG.bind, port: CONFIG.port }, err => {
        if (err) return rejectStart(err)
        log('gateway_ready', {
          bind: CONFIG.bind, port: server.address().port,
          tls: !CONFIG.dev_allow_plain_ws,
          protocol_version: CONFIG.protocol_version,
          provider_key_present: Boolean(providerKey),
        })
        resolveStart(server)
      })
    })
  }
  async function stop() {
    return new Promise(resolveStop => {
      wss.close(() => server.close(() => resolveStop()))
    })
  }

  return { server, wss, devices, issuer, agentTransport, config: CONFIG, log, start, stop }
}

function readConfig(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return {} }
}

function createHttpListener(CONFIG, { devices, issuer, log, protocolVersion }) {
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
  const cert = readFileSync(resolve(CONFIG.tls_cert))
  const key = readFileSync(resolve(CONFIG.tls_key))
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

function writeJson(res, status, obj) {
  if (res.writableEnded) return
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(JSON.stringify(obj))
}

function extractBearer(header) {
  if (!header || typeof header !== 'string') return null
  const match = /^Bearer\s+(rtk_[A-Za-z0-9]+)$/.exec(header.trim())
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

function createAgentTransport(CONFIG, { log, providerKey }) {
  const kind = CONFIG.agent_transport ?? 'mock'
  if (kind === 'mock') return new MockAgentTransport({ log: (...args) => log('mock_agent', { detail: args.map(String).join(' ') }) })
  // Real Agent transport wiring lives in ESS-401 integration; refuse to
  // silently downgrade in production. This branch fails loud so nobody ships
  // the mock by accident.
  if (kind === 'agent') {
    if (!providerKey) throw new Error('provider key missing for agent_transport=agent (set env: ' + (CONFIG.provider_key_env ?? 'AUDIO_REALTIME_PROVIDER_KEY') + ')')
    throw new Error('agent_transport=agent is not wired in this module — implement in ESS-401 integration')
  }
  throw new Error('unknown agent_transport: ' + kind)
}

// Allow running as a standalone process.
if (import.meta.url === `file://${process.argv[1]}`) {
  const gateway = createGateway()
  gateway.start().catch(err => {
    process.stderr.write(JSON.stringify({ ts: new Date().toISOString(), evt: 'startup_failed', detail: String(err?.message ?? err) }) + '\n')
    process.exit(1)
  })
}
