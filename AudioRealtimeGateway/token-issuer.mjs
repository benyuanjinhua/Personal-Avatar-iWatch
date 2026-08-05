// Short-lived, single-use, scope-bound WSS session tokens (ESS-388 A1,
// ESS-403). The issuer stores only SHA-256(token) in memory; the raw token is
// returned once to the caller. Consuming a token is atomic and idempotent —
// two concurrent WSS upgrades cannot both pass.
//
// Storage is intentionally in-memory: tokens are ephemeral (<=90 s TTL) and
// a Gateway restart forces clients to mint fresh tokens, which is the right
// behaviour after a fault. Persisting nonces / used tokens across restarts
// would only widen the replay window.

import crypto from 'node:crypto'

import { sha256hex } from './device-auth.mjs'

export const ISSUER_ERR = {
  MISSING_FIELD: ['ERR_MISSING_FIELD', 400],
  SCOPE_MISMATCH: ['ERR_SCOPE_MISMATCH', 400],
  GENERATION_BACKWARD: ['ERR_GENERATION_BACKWARD', 409],
  TOKEN_INVALID: ['ERR_TOKEN_INVALID', 401],
  TOKEN_EXPIRED: ['ERR_TOKEN_EXPIRED', 401],
  TOKEN_CONSUMED: ['ERR_TOKEN_CONSUMED', 401],
}

export class IssuerError extends Error {
  constructor([code, status], detail) {
    super(code)
    this.code = code
    this.status = status
    this.detail = detail
  }
}

export class TokenIssuer {
  constructor({
    maxTtlMs = 90_000, defaultTtlMs = 30_000, protocolVersion = 1,
    log = () => {}, now = () => Date.now(), randomToken = defaultRandomToken,
  } = {}) {
    if (maxTtlMs < 1_000 || maxTtlMs > 600_000) throw new Error('max_token_ttl_ms out of range')
    this.maxTtlMs = maxTtlMs
    this.defaultTtlMs = Math.min(defaultTtlMs, maxTtlMs)
    this.protocolVersion = protocolVersion
    this.log = log
    this.now = now
    this.randomToken = randomToken
    this.tokens = new Map()   // sha256 → { scope, expiresAt, consumed, jti }
    this.generations = new Map()  // `${deviceId}\n${sessionId}` → highestGeneration
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

  // Issue an ephemeral token. `authDeviceId` is the device id proven by
  // signature verification — it MUST match `body.device_id`.
  issue(body, { authDeviceId }) {
    this.#assertScope(body)
    if (body.device_id !== authDeviceId) {
      throw new IssuerError(ISSUER_ERR.SCOPE_MISMATCH, 'device_id vs signature')
    }
    const key = body.device_id + '\n' + body.session_id
    const highest = this.generations.get(key) ?? 0
    if (body.generation < highest) {
      throw new IssuerError(ISSUER_ERR.GENERATION_BACKWARD,
        `generation ${body.generation} < highest ${highest}`)
    }
    this.generations.set(key, Math.max(highest, body.generation))

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
    this.tokens.set(sha, { scope, expiresAt, consumed: false, jti })
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
        this.tokens.delete(sha)
        removed += 1
        this.log('token_revoked', {
          jti, request_id: entry.scope.request_id,
        })
      }
    }
    return removed
  }

  // Prune expired / consumed entries. Callers can invoke on a timer; tests
  // call directly to keep the map small.
  prune() {
    const now = this.now()
    for (const [sha, entry] of this.tokens) {
      if (entry.consumed || entry.expiresAt <= now - 60_000) this.tokens.delete(sha)
    }
  }
}

function defaultRandomToken() {
  return 'rtk_' + crypto.randomBytes(32).toString('hex')
}
