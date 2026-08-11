// Bounds + soak tests for the ephemeral token issuer (ESS-743).
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
// weaken replay defence: single-use tokens stay single-use, and an actively
// used session keeps its monotone-generation guard throughout.

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

const isBackward = err => err instanceof IssuerError && err.code === 'ERR_GENERATION_BACKWARD'

describe('TokenIssuer — capacity bounds', () => {
  it('holds both maps bounded through a 20k-session soak from one device', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({
      now: clock.now, maxTokensPerDevice: 64, maxSessionsPerDevice: 256,
    })
    const heapBefore = process.memoryUsage().heapUsed

    for (let i = 0; i < 20_000; i += 1) {
      mint(issuer, { session_id: 'flood-' + i, request_id: 'r-' + i })
      clock.advance(100)  // 20k × 100 ms ≈ 33 min — inside generation_ttl_ms
    }

    const stats = issuer.stats()
    assert.equal(stats.devices, 1)
    assert.ok(stats.tokens <= 64, `tokens retained: ${stats.tokens}`)
    assert.ok(stats.sessions <= 256, `sessions retained: ${stats.sessions}`)
    // The device→sha index must shrink with the token map, or it becomes the
    // next leak.
    assert.equal(issuer.tokensByDevice.get('jackson-iphone').size, stats.tokens)

    if (global.gc) {
      global.gc()
      const grew = process.memoryUsage().heapUsed - heapBefore
      assert.ok(grew < 8 * 1024 * 1024, `heap grew ${(grew / 1024 / 1024).toFixed(1)} MiB`)
    }
  })

  it('bounds device fan-out with LRU eviction', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, maxDevices: 8 })
    for (let i = 0; i < 500; i += 1) {
      mint(issuer, { device_id: 'device-' + i, session_id: 's', request_id: 'r-' + i })
      clock.advance(10)
    }
    assert.equal(issuer.stats().devices, 8)
    // Eviction takes the coldest device, so the most recent ones survive.
    assert.ok(issuer.generations.has('device-499'))
    assert.ok(!issuer.generations.has('device-0'))
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
    const issuer = new TokenIssuer({ now: clock.now, maxTokensPerDevice: 8, maxTokens: 4_096 })
    const watch = mint(issuer, { device_id: 'watch', session_id: 'live', request_id: 'r-watch' })
    for (let i = 0; i < 500; i += 1) {
      mint(issuer, { device_id: 'flood', session_id: 'f-' + i, request_id: 'rf-' + i })
      clock.advance(1)
    }
    assert.equal(issuer.tokensByDevice.get('flood').size, 8)
    assert.equal(issuer.consume(watch.token, watch.scope).session_id, 'live')
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
        mint(issuer, { device_id: 'flood', session_id: `f-${generation}-${i}`, request_id: 'rf' + i })
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

  it('keeps a single-use token single-use across a high-volume soak', () => {
    const clock = fakeClock()
    const issuer = new TokenIssuer({ now: clock.now, maxTokensPerDevice: 32 })
    const issued = mint(issuer, { device_id: 'watch', session_id: 'live', ttl_ms: 60_000 })
    assert.equal(issuer.consume(issued.token, issued.scope).session_id, 'live')

    for (let i = 0; i < 5_000; i += 1) {
      mint(issuer, { device_id: 'flood', session_id: 'f-' + i, request_id: 'rf-' + i })
      clock.advance(1)
    }
    assert.throws(() => issuer.consume(issued.token, issued.scope),
      err => err.code === 'ERR_TOKEN_CONSUMED')
    // ...and no amount of flooding resurrects it as a fresh token either.
    assert.throws(() => issuer.consume(issued.token, { ...issued.scope, generation: 2 }),
      err => err.code === 'ERR_TOKEN_CONSUMED')
  })
})
