// Tests for heartbeat, idle disconnect, event rate limit, uplink byte rate
// limit, and per-frame size cap. Timers are injected so the tests run
// deterministically in milliseconds of wall clock.

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'

function b64(len) { return Buffer.alloc(len, 0x41).toString('base64') }

function fakeClock(start = 100_000) {
  const timers = []
  let now = start
  return {
    now: () => now,
    setTimer: (fn, ms) => {
      const t = { fireAt: now + ms, fn }
      timers.push(t)
      return t
    },
    clearTimer: t => {
      const idx = timers.indexOf(t)
      if (idx >= 0) timers.splice(idx, 1)
    },
    advance(ms) {
      now += ms
      // Fire due timers (single pass — sufficient for our tests).
      const due = timers.filter(t => t.fireAt <= now).sort((a, b) => a.fireAt - b.fireAt)
      for (const t of due) {
        const idx = timers.indexOf(t)
        if (idx >= 0) timers.splice(idx, 1)
        t.fn()
      }
    },
  }
}

function harness(overrides = {}) {
  const sent = []
  const logs = []
  const closes = []
  const clock = fakeClock()
  const agent = new ScriptedAgentTransport()
  const scope = { device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-1', generation: 1 }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: (code, reason) => closes.push({ code, reason }),
    agentTransport: agent,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 5_000,
    idleDisconnectMs: 30_000,
    uplinkCommitTimeoutMs: 0,
    maxEventsPerSecond: 5,
    maxUplinkBytesPerSecond: 512,
    maxFrameBytes: 128,
    now: clock.now, setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    ...overrides,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start', session_id: scope.session_id,
    request_id: scope.request_id, generation: scope.generation, protocol_version: 1,
  }))
  return { session, sent, logs, closes, clock, agent, scope }
}

describe('heartbeat + idle timeout', () => {
  it('closes the socket with ERR_IDLE_TIMEOUT after idle_ms of silence', () => {
    const { session, sent, closes, clock, scope } = harness({ heartbeatIntervalMs: 0 })
    void session
    void scope
    clock.advance(30_000)
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_IDLE_TIMEOUT')
    assert.equal(closes[0]?.code, 1008)
  })

  it('emits periodic server_ping while idle timer is not tripped', () => {
    const { sent, clock } = harness()
    clock.advance(5_000)
    clock.advance(5_000)
    const pings = sent.filter(e => e.type === 'server_ping')
    assert.ok(pings.length >= 2, `expected ≥2 server_pings, got ${pings.length}`)
  })

  it('client ping resets the idle window', () => {
    const { session, sent, clock, scope } = harness({ heartbeatIntervalMs: 0 })
    clock.advance(20_000)
    session.onFrame(JSON.stringify({ type: 'ping', nonce: 'x' }))
    clock.advance(20_000)
    // 40s total but only 20s since ping — should NOT have fired idle timeout.
    assert.equal(sent.filter(e => e.type === 'error').length, 0)
  })
})

describe('rate limiting', () => {
  it('closes with ERR_RATE_LIMIT when events/sec cap tripped', () => {
    const { session, sent, scope } = harness({ maxEventsPerSecond: 3 })
    // session.start counted 1. Ping counts 2, 3 → allowed. 4th → cap tripped.
    for (let i = 0; i < 4; i++) session.onFrame(JSON.stringify({ type: 'ping', nonce: 'n' + i }))
    void scope
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_RATE_LIMIT')
  })

  it('closes with ERR_RATE_LIMIT when uplink bytes/sec cap tripped', () => {
    const { session, sent, scope } = harness({ maxUplinkBytesPerSecond: 256, maxFrameBytes: 1024 })
    // Each append is ~128 base64 chars → ~96 bytes decoded. Three of them
    // easily exceed 256/s.
    const payload = b64(128)
    for (let i = 0; i < 3; i++) {
      session.onFrame(JSON.stringify({
        type: 'audio.append', session_id: scope.session_id, request_id: scope.request_id,
        generation: scope.generation, sequence: i, audio: payload,
      }))
    }
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_RATE_LIMIT')
  })

  it('rejects oversize frames with ERR_STREAM_FRAME_SIZE', () => {
    const { session, sent, scope } = harness({ maxFrameBytes: 64 })
    const huge = JSON.stringify({
      type: 'audio.append', session_id: scope.session_id, request_id: scope.request_id,
      generation: scope.generation, sequence: 0, audio: b64(200),
    })
    // The JSON envelope alone exceeds 64 bytes → server rejects on size.
    session.onFrame(huge)
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_STREAM_FRAME_SIZE')
  })
})

describe('unsupported frames', () => {
  it('rejects binary frames', () => {
    const { session, sent } = harness()
    session.onBinary()
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_UNSUPPORTED_BINARY')
  })
})
