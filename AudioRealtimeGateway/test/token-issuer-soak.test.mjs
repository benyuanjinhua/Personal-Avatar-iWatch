// Bounds + soak tests for the ephemeral token issuer (ESS-743, ESS-794).
//
// The defect these cover: `tokens` and `generations` had no production sweeper
// (`prune()` was never called outside tests) and no capacity ceiling, so one
// authenticated device could grow Gateway heap without limit simply by minting
// tokens under fresh `session_id`s.
//
// "Memory is bounded" is asserted structurally — the number of retained
// entries after a high-cardinality soak — because that is the deterministic
// invariant. The heap delta is also checked, but only when the runner exposes
// gc; run it that way for a real measurement:
//
//   node --expose-gc --test test/token-issuer-soak.test.mjs
//
// The second thing every soak here asserts is that bounding the maps did NOT
// weaken replay defence. That is the ESS-794 finding: an LRU ceiling bounds
// memory just as well but resets the evicted session's highest generation to
// 0, so a superseded generation could be re-opened inside the TTL window. The
// ceilings therefore fail closed, and the capacity tests below assert the
// rejection rather than an eviction.

import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, it } from 'node:test'

import { createGateway } from '../server.mjs'
import { IssuerError, TokenIssuer } from '../token-issuer.mjs'

function fakeClock(start = 1_000_000) {
  let t = start
  return { now: () => t, advance: dt => { t += dt } }
}

function body(overrides = {}) {
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

function mint(issuer, overrides) {
  const payload = body(overrides)
  return issuer.issue(payload, { authDeviceId: payload.device_id })
}

// Mint, tolerating the fail-closed capacity codes. Returns the error code so a
// soak can assert WHY a mint was refused instead of ignoring the refusal.
function tryMint(issuer, overrides) {
  try {
    mint(issuer, overrides)
    return null
  } catch (error) {
    if (error instanceof IssuerError) return error.code
    throw error
  }
}

const isBackward = err => err instanceof IssuerError && err.code === 'ERR_GENERATION_BACKWARD'

describe('TokenIssuer — capacity bounds', () => {
  it('stays bounded under 20k accepted mints of sustained session churn', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, generationTtlMs: 3_600_000 })
    const heapBefore = process.memoryUsage().heapUsed

    // One fresh session per minute for ~14 simulated days. Every mint is
    // accepted — entries age out of the TTL as fast as they arrive — so this
    // measures retention under real churn, not under refusal.
    for (let i = 0; i < 20_000; i += 1) {
      mint(issuer, { session_id: 'churn-' + i, request_id: 'r-' + i })
      clock.advance(60_000)
    }

    const stats = issuer.stats()
    assert.equal(stats.devices, 1)
    assert.ok(stats.tokens <= 64, `tokens retained: ${stats.tokens}`)
    assert.ok(stats.sessions <= 256, `sessions retained: ${stats.sessions}`)
    // The device→sha index must shrink with the token map, or it becomes the
    // next leak.
    assert.equal(issuer.tokensByDevice.get('jackson-iphone')?.size ?? 0, stats.tokens)

    if (global.gc) {
      global.gc()
      const grew = process.memoryUsage().heapUsed - heapBefore
      assert.ok(grew < 8 * 1024 * 1024, `heap grew ${(grew / 1024 / 1024).toFixed(1)} MiB`)
    }
  })

  it('stays bounded under a 20k-session burst, refusing the overflow', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, maxSessionsPerDevice: 256 })
    const heapBefore = process.memoryUsage().heapUsed

    let accepted = 0
    const refusals = new Map()
    for (let i = 0; i < 20_000; i += 1) {
      const code = tryMint(issuer, { session_id: 'flood-' + i, request_id: 'r-' + i })
      if (code) refusals.set(code, (refusals.get(code) ?? 0) + 1)
      else accepted += 1
      clock.advance(100)  // 20k × 100 ms ≈ 33 min — inside generation_ttl_ms
    }

    assert.equal(accepted, 256, 'the ceiling, not eviction, is what stops the flood')
    assert.deepEqual([...refusals.keys()], ['ERR_SESSION_CAPACITY'])
    assert.equal(refusals.get('ERR_SESSION_CAPACITY'), 19_744)
    const stats = issuer.stats()
    assert.equal(stats.sessions, 256)
    assert.ok(stats.tokens <= 64, `tokens retained: ${stats.tokens}`)

    if (global.gc) {
      global.gc()
      const grew = process.memoryUsage().heapUsed - heapBefore
      assert.ok(grew < 8 * 1024 * 1024, `heap grew ${(grew / 1024 / 1024).toFixed(1)} MiB`)
    }
  })

  it('bounds device fan-out without dropping a tracked device', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, maxDevices: 8 })
    const codes = new Set()
    for (let i = 0; i < 500; i += 1) {
      const code = tryMint(issuer, { device_id: 'device-' + i, session_id: 's', request_id: 'r-' + i })
      if (code) codes.add(code)
      clock.advance(10)
    }
    assert.equal(issuer.stats().devices, 8)
    assert.deepEqual([...codes], ['ERR_DEVICE_CAPACITY'])
    // The devices admitted first keep their guards — the table does not churn.
    assert.ok(issuer.generations.has('device-0'))
    assert.ok(!issuer.generations.has('device-499'))
  })

  it('caps live tokens globally without letting the index drift', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({
      now: clock.now, maxTokens: 100, maxTokensPerDevice: 50, maxDevices: 64,
    })
    for (let i = 0; i < 2_000; i += 1) {
      mint(issuer, { device_id: 'device-' + (i % 20), session_id: 's-' + i, request_id: 'r-' + i })
      clock.advance(5)
    }
    assert.ok(issuer.stats().tokens <= 100, `tokens retained: ${issuer.stats().tokens}`)
    let indexed = 0
    for (const owned of issuer.tokensByDevice.values()) {
      assert.ok(owned.size <= 50)
      indexed += owned.size
      for (const sha of owned) assert.ok(issuer.tokens.has(sha), 'index points at a live token')
    }
    assert.equal(indexed, issuer.tokens.size)
  })

  it('a flooding device evicts only its own tokens', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({
      now: clock.now, maxTokensPerDevice: 8, maxTokens: 4_096, maxSessionsPerDevice: 1_000,
    })
    const watch = mint(issuer, { device_id: 'watch', session_id: 'live', request_id: 'r-watch' })
    for (let i = 0; i < 500; i += 1) {
      mint(issuer, { device_id: 'flood', session_id: 'f-' + i, request_id: 'rf-' + i })
      clock.advance(1)
    }
    assert.equal(issuer.tokensByDevice.get('flood').size, 8)
    assert.equal(issuer.consume(watch.token, watch.scope).session_id, 'live')
  })
})

describe('TokenIssuer — capacity fails closed (ESS-794)', () => {
  // The reviewer's minimal repro, verbatim in behaviour: fill a device's
  // session slots, then re-present an already superseded generation for a
  // session that was competing for those slots.
  it('never lets a session-capacity refusal reset a highest generation', () => {
    const issuer = new TokenIssuer({ maxSessionsPerDevice: 2 })
    mint(issuer, { device_id: 'watch', session_id: 'live', generation: 5, request_id: 'r-5' })
    mint(issuer, { device_id: 'watch', session_id: 'f1', generation: 1, request_id: 'r-f1' })

    assert.throws(
      () => mint(issuer, { device_id: 'watch', session_id: 'f2', generation: 1, request_id: 'r-f2' }),
      err => err instanceof IssuerError && err.code === 'ERR_SESSION_CAPACITY' && err.status === 429,
    )
    assert.throws(
      () => mint(issuer, { device_id: 'watch', session_id: 'live', generation: 1, request_id: 'r-1' }),
      isBackward,
    )
    assert.equal(issuer.generations.get('watch').get('live').generation, 5)
  })

  it('never lets a device-capacity refusal reset a highest generation', () => {
    const issuer = new TokenIssuer({ maxDevices: 2 })
    mint(issuer, { device_id: 'watch', session_id: 'live', generation: 9, request_id: 'r-9' })
    mint(issuer, { device_id: 'phone', session_id: 'live', generation: 1, request_id: 'r-p' })

    assert.throws(
      () => mint(issuer, { device_id: 'intruder', session_id: 'live', generation: 1, request_id: 'r-i' }),
      err => err instanceof IssuerError && err.code === 'ERR_DEVICE_CAPACITY' && err.status === 429,
    )
    assert.throws(
      () => mint(issuer, { device_id: 'watch', session_id: 'live', generation: 8, request_id: 'r-8' }),
      isBackward,
    )
  })

  it('keeps serving a device that is at its ceiling on its tracked sessions', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, maxSessionsPerDevice: 2 })
    mint(issuer, { device_id: 'watch', session_id: 'a', generation: 1, request_id: 'r-a' })
    mint(issuer, { device_id: 'watch', session_id: 'b', generation: 1, request_id: 'r-b' })
    assert.throws(() => mint(issuer, { device_id: 'watch', session_id: 'c', request_id: 'r-c' }),
      err => err.code === 'ERR_SESSION_CAPACITY')
    // A full device must still be able to advance the sessions it already owns
    // — refusing those would turn a ceiling into an outage.
    clock.advance(1_000)
    assert.equal(mint(issuer, { device_id: 'watch', session_id: 'a', generation: 2, request_id: 'r-a2' })
      .scope.generation, 2)
  })

  it('releases the ceiling once the held sessions go idle past the TTL', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({
      now: clock.now, maxSessionsPerDevice: 2, generationTtlMs: 3_600_000,
    })
    mint(issuer, { device_id: 'watch', session_id: 'a', generation: 4, request_id: 'r-a' })
    mint(issuer, { device_id: 'watch', session_id: 'b', generation: 1, request_id: 'r-b' })
    assert.throws(() => mint(issuer, { device_id: 'watch', session_id: 'c', request_id: 'r-c' }),
      err => err.code === 'ERR_SESSION_CAPACITY')

    // Not a lockout: the refusal lasts only as long as the held entries do.
    clock.advance(3_600_001)
    assert.equal(mint(issuer, { device_id: 'watch', session_id: 'c', request_id: 'r-c2' })
      .scope.session_id, 'c')
    // ...and the guard it dropped was dropped on TTL, which is the documented
    // trade, so the aged-out session may legitimately restart from 1.
    assert.equal(mint(issuer, { device_id: 'watch', session_id: 'a', generation: 1, request_id: 'r-a3' })
      .scope.generation, 1)
  })
})

describe('TokenIssuer — sweeping', () => {
  it('releases tokens once past expiry + grace, not before', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now })
    const issued = mint(issuer, { ttl_ms: 30_000 })
    issuer.consume(issued.token, issued.scope)

    // A consumed token is retained through expiry + grace so a replay still
    // gets the diagnostic ERR_TOKEN_CONSUMED rather than ERR_TOKEN_INVALID.
    clock.advance(80_000)
    issuer.prune()
    assert.equal(issuer.stats().tokens, 1)
    assert.throws(() => issuer.consume(issued.token, issued.scope),
      err => err.code === 'ERR_TOKEN_CONSUMED')

    clock.advance(20_000)
    assert.deepEqual(issuer.prune(), { tokens: 1, sessions: 0 })
    assert.equal(issuer.stats().tokens, 0)
    assert.equal(issuer.tokensByDevice.size, 0)
    assert.throws(() => issuer.consume(issued.token, issued.scope),
      err => err.code === 'ERR_TOKEN_INVALID')
  })

  it('releases a generation entry only after the session is idle past the TTL', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, generationTtlMs: 3_600_000 })
    mint(issuer, { generation: 5 })

    clock.advance(3_599_000)
    issuer.prune()
    assert.equal(issuer.stats().sessions, 1, 'still inside the idle window')
    assert.throws(() => mint(issuer, { generation: 4 }), isBackward)

    clock.advance(3_600_000)
    assert.deepEqual(issuer.prune().sessions, 1)
    assert.equal(issuer.stats().devices, 0, 'empty device buckets go too')
  })

  it('runs prune on its own timer and stops cleanly', async () => {
    const issuer = new TokenIssuer({ sweepIntervalMs: 5 })
    let sweeps = 0
    const inner = issuer.prune.bind(issuer)
    issuer.prune = () => { sweeps += 1; return inner() }

    assert.equal(issuer.sweepTimer, null)
    const timer = issuer.startSweeper()
    assert.ok(timer)
    assert.equal(issuer.startSweeper(), timer, 'startSweeper is idempotent')
    await new Promise(resolve => setTimeout(resolve, 60))
    issuer.stopSweeper()
    assert.ok(sweeps >= 2, `expected repeated sweeps, saw ${sweeps}`)

    const settled = sweeps
    await new Promise(resolve => setTimeout(resolve, 40))
    assert.equal(sweeps, settled, 'stopSweeper must stop the timer')
    assert.equal(issuer.sweepTimer, null)
  })

  it('is swept by the running gateway, not left to tests', async () => {
    const stateDir = mkdtempSync(join(tmpdir(), 'gw-sweep-'))
    const gateway = createGateway({
      port: 0, bind: '127.0.0.1', state_dir: stateDir, dev_allow_plain_ws: true,
    })
    // Ceilings come from config.json, so a deploy that forgets them still runs
    // bounded.
    assert.equal(gateway.issuer.sweepIntervalMs, 30_000)
    assert.equal(gateway.issuer.generationTtlMs, 3_600_000)

    assert.equal(gateway.issuer.sweepTimer, null, 'no timer before listen')
    await gateway.start()
    assert.ok(gateway.issuer.sweepTimer, 'the sweeper must run in production')
    await gateway.stop()
    assert.equal(gateway.issuer.sweepTimer, null, 'stop() must clear the timer')
  })
})

describe('TokenIssuer — replay semantics survive the soak', () => {
  it('keeps a live session monotone while another device floods', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, maxSessionsPerDevice: 64, maxDevices: 8 })
    for (let generation = 1; generation <= 50; generation += 1) {
      mint(issuer, { device_id: 'watch', session_id: 'live', generation, request_id: 'r-' + generation })
      for (let i = 0; i < 400; i += 1) {
        tryMint(issuer, { device_id: 'flood', session_id: `f-${generation}-${i}`, request_id: 'rf' + i })
        clock.advance(50)
      }
    }
    // 50 × 400 × 50 ms ≈ 4.6 h of soak, well past generation_ttl_ms — but the
    // guarded session was touched throughout, so it must not have been released.
    assert.throws(
      () => mint(issuer, { device_id: 'watch', session_id: 'live', generation: 1 }),
      isBackward,
    )
    assert.equal(issuer.generations.get('watch').get('live').generation, 50)
  })

  it('keeps every flooded session monotone too, not just the quiet one', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, maxSessionsPerDevice: 32 })
    // Drive 32 sessions to generation 20 each, interleaved, then confirm not
    // one of them lost its lower bound while the device sat at its ceiling.
    for (let generation = 1; generation <= 20; generation += 1) {
      for (let s = 0; s < 32; s += 1) {
        mint(issuer, { device_id: 'watch', session_id: 's-' + s, generation, request_id: `r-${s}-${generation}` })
        clock.advance(100)
      }
      tryMint(issuer, { device_id: 'watch', session_id: 'overflow-' + generation, request_id: 'ro' + generation })
    }
    assert.equal(issuer.stats().sessions, 32)
    for (let s = 0; s < 32; s += 1) {
      assert.throws(
        () => mint(issuer, { device_id: 'watch', session_id: 's-' + s, generation: 19, request_id: 'x-' + s }),
        isBackward,
        `session s-${s} lost its lower bound`,
      )
    }
  })

  it('keeps a single-use token single-use across a high-volume soak', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, maxTokensPerDevice: 32 })
    const issued = mint(issuer, { device_id: 'watch', session_id: 'live', ttl_ms: 60_000 })
    assert.equal(issuer.consume(issued.token, issued.scope).session_id, 'live')

    for (let i = 0; i < 5_000; i += 1) {
      tryMint(issuer, { device_id: 'flood', session_id: 'f-' + i, request_id: 'rf-' + i })
      clock.advance(1)
    }
    assert.throws(() => issuer.consume(issued.token, issued.scope),
      err => err.code === 'ERR_TOKEN_CONSUMED')
    // ...and no amount of flooding resurrects it as a fresh token either.
    assert.throws(() => issuer.consume(issued.token, { ...issued.scope, generation: 2 }),
      err => err.code === 'ERR_TOKEN_CONSUMED')
  })
})
