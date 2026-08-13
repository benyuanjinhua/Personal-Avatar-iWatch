// Short-lived, single-use, scope-bound WSS session tokens (ESS-388 A1,
// ESS-403). The issuer stores only SHA-256(token) in memory; the raw token is
// returned once to the caller. Consuming a token is atomic and idempotent —
// two concurrent WSS upgrades cannot both pass.
//
// Storage is intentionally in-memory: tokens are ephemeral (<=90 s TTL) and
// a Gateway restart forces clients to mint fresh tokens, which is the right
// behaviour after a fault. Persisting nonces / used tokens across restarts
// would only widen the replay window.
//
// In-memory also means BOUNDED (ESS-743). Both maps are swept on a timer the
// server owns (`startSweeper()` / `stopSweeper()`) and are additionally capped:
// an authenticated device can mint an unlimited number of (session_id,
// generation) pairs, so without caps the generation map would grow for the
// lifetime of the process. See #recordGeneration for why bounding the replay
// guard does not weaken it.

import crypto from 'node:crypto'

import { sha256hex } from './device-auth.mjs'

export const ISSUER_ERR = {
  MISSING_FIELD: ['ERR_MISSING_FIELD', 400],
  SCOPE_MISMATCH: ['ERR_SCOPE_MISMATCH', 400],
  GENERATION_BACKWARD: ['ERR_GENERATION_BACKWARD', 409],
  TOKEN_INVALID: ['ERR_TOKEN_INVALID', 401],
  TOKEN_EXPIRED: ['ERR_TOKEN_EXPIRED', 401],
  TOKEN_CONSUMED: ['ERR_TOKEN_CONSUMED', 401],
  SESSION_CAPACITY: ['ERR_SESSION_CAPACITY', 429],
  DEVICE_CAPACITY: ['ERR_DEVICE_CAPACITY', 429],
}

export class IssuerError extends Error {
  constructor([code, status], detail) {
    super(code)
    this.code = code
    this.status = status
    this.detail = detail
  }
}

// Entries live at most `maxTtlMs + TOKEN_GRACE_MS` past issuance; the grace
// window is what keeps a replayed token answering ERR_TOKEN_CONSUMED /
// ERR_TOKEN_EXPIRED instead of the useless ERR_TOKEN_INVALID.
const TOKEN_GRACE_MS = 60_000

export class TokenIssuer {
  constructor({
    maxTtlMs = 90_000, defaultTtlMs = 30_000, protocolVersion = 1,
    log = () => {}, now = () => Date.now(), randomToken = defaultRandomToken,
    generationTtlMs = 3_600_000,
    maxTokens = 4_096,
    maxTokensPerDevice = 64,
    maxDevices = 64,
    maxSessionsPerDevice = 256,
    sweepIntervalMs = 30_000,
  } = {}) {
    if (maxTtlMs < 1_000 || maxTtlMs > 600_000) throw new Error('max_token_ttl_ms out of range')
    this.maxTtlMs = maxTtlMs
    this.defaultTtlMs = Math.min(defaultTtlMs, maxTtlMs)
    this.protocolVersion = protocolVersion
    this.log = log
    this.now = now
    this.randomToken = randomToken
    // A generation entry may only be dropped once the session it guards is
    // long dead, so the floor is the widest window in which a token minted
    // under that session can still be presented.
    this.generationTtlMs = positiveInt(generationTtlMs, 'generation_ttl_ms', maxTtlMs + TOKEN_GRACE_MS)
    this.maxTokens = positiveInt(maxTokens, 'max_tokens', 1)
    this.maxTokensPerDevice = positiveInt(maxTokensPerDevice, 'max_tokens_per_device', 1)
    this.maxDevices = positiveInt(maxDevices, 'max_devices', 1)
    this.maxSessionsPerDevice = positiveInt(maxSessionsPerDevice, 'max_sessions_per_device', 1)
    this.sweepIntervalMs = Number(sweepIntervalMs) || 0
    this.tokens = new Map()   // sha256 → { scope, expiresAt, consumed, jti }
    this.tokensByDevice = new Map()  // deviceId → Set<sha256>, insertion-ordered
    // deviceId → Map(sessionId → { generation, seenAt }). Both levels are
    // insertion-ordered and re-inserted on touch, so the first key is always
    // the least-recently-used one.
    this.generations = new Map()
    this.sweepTimer = null
    this.lastPrunedAt = 0
  }

  // Periodic sweep. The server starts it on listen and stops it on close;
  // the timer is unref'd so it never keeps the process alive on its own.
  startSweeper() {
    if (this.sweepTimer || this.sweepIntervalMs <= 0) return this.sweepTimer
    this.sweepTimer = setInterval(() => this.prune(), this.sweepIntervalMs)
    this.sweepTimer.unref?.()
    return this.sweepTimer
  }

  stopSweeper() {
    if (!this.sweepTimer) return
    clearInterval(this.sweepTimer)
    this.sweepTimer = null
  }

  // Cheap snapshot for tests / diagnostics — never contains token material.
  stats() {
    let sessions = 0
    for (const perDevice of this.generations.values()) sessions += perDevice.size
    return { tokens: this.tokens.size, devices: this.generations.size, sessions }
  }

  #assertScope(body) {
    for (const field of ['device_id', 'session_id', 'request_id', 'generation']) {
      if (!body[field] && body[field] !== 0) {
        throw new IssuerError(ISSUER_ERR.MISSING_FIELD, field)
      }
    }
    if (typeof body.device_id !== 'string' || body.device_id.length > 128) {
      throw new IssuerError(ISSUER_ERR.MISSING_FIELD, 'device_id must be string ≤128')
    }
    if (typeof body.session_id !== 'string' || body.session_id.length > 128) {
      throw new IssuerError(ISSUER_ERR.MISSING_FIELD, 'session_id must be string ≤128')
    }
    if (typeof body.request_id !== 'string' || body.request_id.length > 128) {
      throw new IssuerError(ISSUER_ERR.MISSING_FIELD, 'request_id must be string ≤128')
    }
    if (!Number.isInteger(body.generation) || body.generation < 1 || body.generation > 1e9) {
      throw new IssuerError(ISSUER_ERR.MISSING_FIELD, 'generation must be positive integer')
    }
    if (body.protocol_version !== this.protocolVersion) {
      throw new IssuerError(ISSUER_ERR.MISSING_FIELD, 'protocol_version')
    }
  }

  // Drop this device's generation entries that are idle past the TTL.
  // Returns the bucket, or undefined if the device is not tracked yet.
  #releaseIdleSessions(deviceId) {
    const sessions = this.generations.get(deviceId)
    if (!sessions) return undefined
    const cutoff = this.now() - this.generationTtlMs
    for (const [sessionId, entry] of sessions) {
      if (entry.seenAt <= cutoff) sessions.delete(sessionId)
    }
    return sessions
  }

  // Enforce and record the monotone-generation guard.
  //
  // The guard is a lower bound that must never move backwards while a token
  // minted under it can still be presented, so BOTH ceilings here fail closed:
  // once a device fills its session slots (or the device table is full) we
  // reject the mint instead of dropping a guard entry. Dropping the coldest
  // entry would bound memory just as well but would silently reset that
  // session's highest generation to 0, letting a superseded generation be
  // re-opened inside the TTL window (ESS-794 finding — the LRU version of this
  // function accepted generation 1 again right after a 2-session flood).
  //
  // The rejection is self-limiting rather than a lockout: entries idle past
  // `generationTtlMs` are released first, and only a device that holds
  // `maxSessionsPerDevice` genuinely *fresh* sessions is refused — and only
  // for its own device_id, since the map is partitioned per device.
  #recordGeneration(deviceId, sessionId, generation) {
    let sessions = this.generations.get(deviceId)
    // Only a *new* session_id can push a device over its ceiling; re-minting
    // for a session already tracked is always allowed.
    if (sessions && !sessions.has(sessionId) && sessions.size >= this.maxSessionsPerDevice) {
      sessions = this.#releaseIdleSessions(deviceId)
      if (sessions.size >= this.maxSessionsPerDevice) {
        this.log('issuer_capacity_rejected', {
          device_id: deviceId, session_id: sessionId, reason: 'session_capacity',
          live: sessions.size,
        })
        throw new IssuerError(ISSUER_ERR.SESSION_CAPACITY,
          `device holds ${sessions.size} live sessions`)
      }
    }
    if (!sessions) {
      if (this.generations.size >= this.maxDevices) {
        this.prune()
        if (this.generations.size >= this.maxDevices) {
          this.log('issuer_capacity_rejected', {
            device_id: deviceId, reason: 'device_capacity', live: this.generations.size,
          })
          throw new IssuerError(ISSUER_ERR.DEVICE_CAPACITY,
            `issuer tracks ${this.generations.size} live devices`)
        }
      }
      sessions = new Map()
      this.generations.set(deviceId, sessions)
    }

    const previous = sessions.get(sessionId)
    const highest = previous?.generation ?? 0
    if (generation < highest) {
      throw new IssuerError(ISSUER_ERR.GENERATION_BACKWARD,
        `generation ${generation} < highest ${highest}`)
    }
    sessions.set(sessionId, { generation: Math.max(highest, generation), seenAt: this.now() })
  }

  #storeToken(sha, entry) {
    const deviceId = entry.scope.device_id
    let owned = this.tokensByDevice.get(deviceId)
    if (!owned) {
      owned = new Set()
      this.tokensByDevice.set(deviceId, owned)
    }
    this.tokens.set(sha, entry)
    owned.add(sha)
    // Tokens evict rather than fail closed, unlike the generation guard: a
    // dropped token entry can only ever cause a *rejection* (consume() answers
    // ERR_TOKEN_INVALID for an unknown sha), so eviction cannot resurrect a
    // spent token or weaken single-use. Per-device first so one noisy device
    // evicts only its own tokens; the global cap backstops many-device fan-out.
    while (owned.size > this.maxTokensPerDevice) {
      this.#deleteToken(owned.values().next().value, 'device_capacity')
    }
    while (this.tokens.size > this.maxTokens) {
      this.#deleteToken(this.tokens.keys().next().value, 'global_capacity')
    }
  }

  #deleteToken(sha, reason) {
    const entry = this.tokens.get(sha)
    if (!entry) return
    this.tokens.delete(sha)
    const owned = this.tokensByDevice.get(entry.scope.device_id)
    if (owned) {
      owned.delete(sha)
      if (owned.size === 0) this.tokensByDevice.delete(entry.scope.device_id)
    }
    if (reason) {
      this.log('token_evicted', {
        jti: entry.jti, reason, request_id: entry.scope.request_id,
        session_id: entry.scope.session_id, device_id: entry.scope.device_id,
      })
    }
  }

  // Issue an ephemeral token. `authDeviceId` is the device id proven by
  // signature verification — it MUST match `body.device_id`.
  issue(body, { authDeviceId }) {
    this.#assertScope(body)
    if (body.device_id !== authDeviceId) {
      throw new IssuerError(ISSUER_ERR.SCOPE_MISMATCH, 'device_id vs signature')
    }
    // Amortised sweep so the maps stay bounded even for an embedder that
    // never starts the timer (tests, smoke scripts).
    if (this.now() - this.lastPrunedAt >= 1_000) this.prune()
    this.#recordGeneration(body.device_id, body.session_id, body.generation)

    const ttl = Math.min(this.maxTtlMs,
      Math.max(1_000, Number(body.ttl_ms) || this.defaultTtlMs))
    const raw = this.randomToken()
    const sha = sha256hex(raw)
    const jti = sha.slice(0, 8)
    const expiresAt = this.now() + ttl
    const scope = {
      device_id: body.device_id,
      session_id: body.session_id,
      request_id: body.request_id,
      generation: body.generation,
    }
    this.#storeToken(sha, { scope, expiresAt, consumed: false, jti })
    this.log('token_issued', {
      jti, request_id: scope.request_id, session_id: scope.session_id,
      generation: scope.generation, device_id: scope.device_id, ttl_ms: ttl,
    })
    return { token: raw, expires_at: expiresAt, ttl_ms: ttl, scope, jti }
  }

  // Look up a token WITHOUT consuming it. Used only by tests / diagnostics.
  peek(rawToken) {
    if (typeof rawToken !== 'string' || rawToken.length === 0) return null
    return this.tokens.get(sha256hex(rawToken)) ?? null
  }

  // Consume a token atomically. On success, the entry is marked consumed
  // (still stored so a second attempt yields ERR_TOKEN_CONSUMED, not
  // ERR_TOKEN_INVALID — the distinction matters for client diagnostics).
  //
  // `presentedScope` is the scope proven by the URL / handshake. It MUST
  // exactly match the token's pinned scope; any deviation fails hard.
  consume(rawToken, presentedScope) {
    if (typeof rawToken !== 'string' || !rawToken.startsWith('rtk_')) {
      throw new IssuerError(ISSUER_ERR.TOKEN_INVALID, 'malformed')
    }
    const sha = sha256hex(rawToken)
    const entry = this.tokens.get(sha)
    if (!entry) throw new IssuerError(ISSUER_ERR.TOKEN_INVALID, 'unknown')
    if (entry.consumed) {
      this.log('token_rejected', {
        jti: entry.jti, reason: 'consumed',
        request_id: entry.scope.request_id, session_id: entry.scope.session_id,
      })
      throw new IssuerError(ISSUER_ERR.TOKEN_CONSUMED)
    }
    const now = this.now()
    if (now >= entry.expiresAt) {
      this.log('token_expired', { jti: entry.jti, request_id: entry.scope.request_id })
      throw new IssuerError(ISSUER_ERR.TOKEN_EXPIRED)
    }
    for (const field of ['device_id', 'session_id', 'request_id', 'generation']) {
      if (entry.scope[field] !== presentedScope[field]) {
        this.log('token_rejected', {
          jti: entry.jti, reason: 'scope_mismatch', field,
          request_id: entry.scope.request_id, session_id: entry.scope.session_id,
        })
        throw new IssuerError(ISSUER_ERR.TOKEN_INVALID, 'scope')
      }
    }
    entry.consumed = true
    this.log('token_consumed', {
      jti: entry.jti, request_id: entry.scope.request_id,
      session_id: entry.scope.session_id, generation: entry.scope.generation,
    })
    return entry.scope
  }

  // Revoke by 8-char jti prefix (matches what tokens log as `jti`). Returns
  // the number of matching entries removed.
  revokeByJti(jti) {
    if (typeof jti !== 'string' || jti.length < 6) return 0
    let removed = 0
    for (const [sha, entry] of this.tokens) {
      if (entry.jti === jti && !entry.consumed) {
        this.#deleteToken(sha)
        removed += 1
        this.log('token_revoked', {
          jti, request_id: entry.scope.request_id,
        })
      }
    }
    return removed
  }

  // Release everything that can no longer affect a decision: tokens past
  // expiry + grace (consumed ones included — they are kept until then so a
  // replay still reports ERR_TOKEN_CONSUMED), and generation entries whose
  // session has been idle beyond `generationTtlMs`.
  //
  // Runs on the sweeper timer in production and is safe to call directly.
  prune() {
    const now = this.now()
    this.lastPrunedAt = now
    let tokens = 0
    for (const [sha, entry] of this.tokens) {
      if (entry.expiresAt <= now - TOKEN_GRACE_MS) {
        this.#deleteToken(sha)
        tokens += 1
      }
    }
    let sessions = 0
    for (const [deviceId, perDevice] of this.generations) {
      for (const [sessionId, entry] of perDevice) {
        if (entry.seenAt <= now - this.generationTtlMs) {
          perDevice.delete(sessionId)
          sessions += 1
        }
      }
      if (perDevice.size === 0) this.generations.delete(deviceId)
    }
    if (tokens || sessions) {
      const remaining = this.stats()
      this.log('issuer_pruned', {
        tokens_pruned: tokens, sessions_pruned: sessions,
        tokens_live: remaining.tokens, devices_live: remaining.devices,
        sessions_live: remaining.sessions,
      })
    }
    return { tokens, sessions }
  }
}

function positiveInt(value, name, floor) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed < floor) {
    throw new Error(`${name} must be a number >= ${floor}`)
  }
  return Math.floor(parsed)
}

function defaultRandomToken() {
  return 'rtk_' + crypto.randomBytes(32).toString('hex')
}
