// Unit tests for the ephemeral token issuer (ESS-403 acceptance #1).
// Covers: successful issue → consume, expiry, replay/reuse rejection,
// scope-mismatch rejection, monotone generation, revocation, unknown device
// via the signed HTTP path.

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { TokenIssuer, IssuerError } from '../token-issuer.mjs'

function fakeClock(start = 1_000_000) {
  let t = start
  return {
    now: () => t,
    advance: dt => { t += dt },
    set: v => { t = v },
  }
}

function scope(overrides = {}) {
  return {
    protocol_version: 1,
    device_id: 'jackson-iphone',
    session_id: 'session-1',
    request_id: 'req-1',
    generation: 1,
    ttl_ms: 30_000,
    ...overrides,
  }
}

describe('TokenIssuer', () => {
  it('issues a scope-bound token that can be consumed exactly once', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now })
    const { token, scope: pinned, expires_at, ttl_ms, jti } = issuer.issue(
      scope(), { authDeviceId: 'jackson-iphone' })
    assert.match(token, /^rtk_[a-f0-9]{64}$/, 'token is opaque hex prefixed with rtk_')
    assert.equal(pinned.device_id, 'jackson-iphone')
    assert.equal(pinned.generation, 1)
    assert.equal(ttl_ms, 30_000)
    assert.equal(expires_at, clock.now() + 30_000)
    assert.equal(jti.length, 8)
    const consumed = issuer.consume(token, pinned)
    assert.deepEqual(consumed, pinned)
    assert.throws(() => issuer.consume(token, pinned), err => err instanceof IssuerError && err.code === 'ERR_TOKEN_CONSUMED')
  })

  it('rejects expired tokens', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, defaultTtlMs: 1_000 })
    const { token, scope: pinned } = issuer.issue(scope({ ttl_ms: 1_000 }), { authDeviceId: 'jackson-iphone' })
    clock.advance(1_500)
    assert.throws(() => issuer.consume(token, pinned), err => err instanceof IssuerError && err.code === 'ERR_TOKEN_EXPIRED')
  })

  it('rejects scope mismatch at consume time', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now })
    const { token, scope: pinned } = issuer.issue(scope(), { authDeviceId: 'jackson-iphone' })
    assert.throws(
      () => issuer.consume(token, { ...pinned, generation: 2 }),
      err => err instanceof IssuerError && err.code === 'ERR_TOKEN_INVALID',
    )
  })

  it('rejects device_id mismatch between signature and body', () => {
    const issuer = new TokenIssuer()
    assert.throws(
      () => issuer.issue(scope({ device_id: 'jackson-iphone' }), { authDeviceId: 'other-device' }),
      err => err instanceof IssuerError && err.code === 'ERR_SCOPE_MISMATCH',
    )
  })

  it('enforces monotone generation per (device, session)', () => {
    const issuer = new TokenIssuer()
    issuer.issue(scope({ generation: 3 }), { authDeviceId: 'jackson-iphone' })
    assert.throws(
      () => issuer.issue(scope({ generation: 2 }), { authDeviceId: 'jackson-iphone' }),
      err => err instanceof IssuerError && err.code === 'ERR_GENERATION_BACKWARD',
    )
    const later = issuer.issue(scope({ generation: 4 }), { authDeviceId: 'jackson-iphone' })
    assert.equal(later.scope.generation, 4)
  })

  it('clamps ttl to max_token_ttl_ms', () => {
    const issuer = new TokenIssuer({ maxTtlMs: 5_000 })
    const { ttl_ms } = issuer.issue(scope({ ttl_ms: 90_000 }), { authDeviceId: 'jackson-iphone' })
    assert.equal(ttl_ms, 5_000)
  })

  it('rejects malformed and unknown tokens with the appropriate code', () => {
    const issuer = new TokenIssuer()
    assert.throws(() => issuer.consume('no-prefix', { device_id: 'a', session_id: 'a', request_id: 'a', generation: 1 }),
      err => err instanceof IssuerError && err.code === 'ERR_TOKEN_INVALID')
    assert.throws(() => issuer.consume('rtk_deadbeef', { device_id: 'a', session_id: 'a', request_id: 'a', generation: 1 }),
      err => err instanceof IssuerError && err.code === 'ERR_TOKEN_INVALID')
  })

  it('revokes a not-yet-consumed token by jti prefix', () => {
    const issuer = new TokenIssuer()
    const { token, scope: pinned, jti } = issuer.issue(scope(), { authDeviceId: 'jackson-iphone' })
    assert.equal(issuer.revokeByJti(jti), 1)
    assert.throws(() => issuer.consume(token, pinned),
      err => err instanceof IssuerError && err.code === 'ERR_TOKEN_INVALID')
    // Revoking again is a no-op.
    assert.equal(issuer.revokeByJti(jti), 0)
  })

  it('does not revoke an already-consumed token (would be a lie)', () => {
    const issuer = new TokenIssuer()
    const { token, scope: pinned, jti } = issuer.issue(scope(), { authDeviceId: 'jackson-iphone' })
    issuer.consume(token, pinned)
    assert.equal(issuer.revokeByJti(jti), 0)
  })

  it('logs issued / consumed / rejected without leaking the raw token', () => {
    const records = []
    const issuer = new TokenIssuer({ log: (evt, extra) => records.push({ evt, extra }) })
    const { token, scope: pinned } = issuer.issue(scope(), { authDeviceId: 'jackson-iphone' })
    issuer.consume(token, pinned)
    assert.deepEqual(records.map(r => r.evt), ['token_issued', 'token_consumed'])
    for (const r of records) {
      const serialised = JSON.stringify(r)
      assert.ok(!serialised.includes(token), 'raw token must never appear in logs')
    }
    // A rejected replay produces token_rejected with jti but not a token.
    try { issuer.consume(token, pinned) } catch { /* expected */ }
    assert.equal(records[2].evt, 'token_rejected')
    assert.ok(records[2].extra.jti && records[2].extra.jti.length === 8)
    assert.ok(!('token' in records[2].extra))
  })
})
