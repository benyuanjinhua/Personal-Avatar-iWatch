// Unit tests for RealtimeSession (ESS-403 acceptance #2): delta + done
// carry verifiable generation/sequence/final_sequence and clients can
// handle out-of-order / duplicate agent events safely.

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'

function harness(overrides = {}) {
  const sent = []
  const logs = []
  const closes = []
  const agent = new ScriptedAgentTransport()
  const scope = {
    device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-1', generation: 1,
    ...(overrides.scope ?? {}),
  }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: (code, reason) => closes.push({ code, reason }),
    agentTransport: agent,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0,
    idleDisconnectMs: 0,
    ...overrides,
  })
  return { session, sent, logs, closes, agent, scope }
}

// Controllable timer harness: instead of setTimeout, capture the pending
// callback so tests can advance time explicitly. Only one pending timer at
// a time is enough for the barrier — heartbeat/idle are disabled above.
function controlledClock() {
  const pending = []
  return {
    setTimer: (fn, ms) => {
      const t = { fn, ms }
      pending.push(t)
      return t
    },
    clearTimer: t => {
      const i = pending.indexOf(t)
      if (i >= 0) pending.splice(i, 1)
    },
    fireAll: () => {
      while (pending.length) {
        const t = pending.shift()
        t.fn()
      }
    },
    pendingCount: () => pending.length,
  }
}

function b64(str) { return Buffer.from(str, 'utf8').toString('base64') }

function start(session, scope) {
  session.onFrame(JSON.stringify({
    type: 'session.start',
    session_id: scope.session_id, request_id: scope.request_id,
    generation: scope.generation, protocol_version: 1,
  }))
}

describe('RealtimeSession — happy path', () => {
  it('rejects any frame before session.start', () => {
    const { session, sent, closes } = harness()
    session.onFrame(JSON.stringify({
      type: 'audio.append', session_id: 's-1', request_id: 'r-1', generation: 1, sequence: 0, audio: b64('hi'),
    }))
    assert.equal(sent[0]?.type, 'error')
    assert.equal(sent[0]?.code, 'ERR_NOT_STARTED')
    assert.equal(closes[0]?.code, 1008)
  })

  it('emits ready on valid session.start', () => {
    const { session, sent, logs, scope } = harness()
    start(session, scope)
    assert.equal(sent[0].type, 'ready')
    assert.equal(sent[0].session_id, scope.session_id)
    assert.equal(sent[0].generation, scope.generation)
    assert.equal(sent[0].response_id, 'r-1:gen1')
    assert.ok(logs.some(l => l.evt === 'session_ready'))
  })

  it('rejects unknown fields on client frames (strict schema)', () => {
    const { session, sent, scope } = harness()
    start(session, scope)
    session.onFrame(JSON.stringify({
      type: 'audio.append',
      session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
      sequence: 0, audio: b64('hi'), rogue_field: 'nope',
    }))
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_UNKNOWN_FIELD')
  })

  it('enforces monotone dense uplink sequences', () => {
    const { session, sent, scope } = harness()
    start(session, scope)
    for (let seq = 0; seq < 3; seq++) {
      session.onFrame(JSON.stringify({
        type: 'audio.append',
        session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
        sequence: seq, audio: b64('frame'),
      }))
    }
    // Skip 3, jump to 4 — must reject
    session.onFrame(JSON.stringify({
      type: 'audio.append',
      session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
      sequence: 4, audio: b64('frame'),
    }))
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_STREAM_SEQUENCE')
    assert.equal(err.expected, 3)
    assert.equal(err.got, 4)
  })

  it('rejects scope mismatch on any subsequent frame', () => {
    const { session, sent, scope } = harness()
    start(session, scope)
    session.onFrame(JSON.stringify({
      type: 'audio.append',
      session_id: 's-2', request_id: scope.request_id, generation: scope.generation,
      sequence: 0, audio: b64('frame'),
    }))
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_SCOPE_MISMATCH')
  })

  it('audio.commit forwards to the agent transport with correct sequence', () => {
    const { session, sent, agent, scope } = harness()
    start(session, scope)
    session.onFrame(JSON.stringify({
      type: 'audio.append',
      session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
      sequence: 0, audio: b64('one'),
    }))
    session.onFrame(JSON.stringify({
      type: 'audio.append',
      session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
      sequence: 1, audio: b64('two'),
    }))
    session.onFrame(JSON.stringify({
      type: 'audio.commit',
      session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
      sequence: 1,
    }))
    assert.equal(agent.appends.length, 2)
    assert.equal(agent.commits.length, 1)
    // No error emitted
    assert.equal(sent.filter(e => e.type === 'error').length, 0)
  })

  it('rejects commit with a sequence that does not match the last append', () => {
    const { session, sent, scope } = harness()
    start(session, scope)
    session.onFrame(JSON.stringify({
      type: 'audio.append',
      session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
      sequence: 0, audio: b64('one'),
    }))
    session.onFrame(JSON.stringify({
      type: 'audio.commit',
      session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
      sequence: 4,
    }))
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_STREAM_SEQUENCE')
  })
})

describe('RealtimeSession — downlink ordering', () => {
  it('drops duplicate delta sequences and preserves the ordered set', () => {
    const { session, sent, agent, scope, logs } = harness()
    start(session, scope)
    // Simulate the agent emitting 0,1,1,2 — the duplicate must be dropped.
    for (const seq of [0, 1, 1, 2]) {
      agent.emit(scope.request_id, {
        type: 'agent.audio.delta', response_id: 'r-1:gen1',
        sequence: seq, audio: b64('x'), sample_rate: 24_000, codec: 'pcm_s16le',
      })
    }
    const deltas = sent.filter(e => e.type === 'audio.delta')
    assert.equal(deltas.length, 3, 'exactly three deltas forwarded (dup dropped)')
    assert.deepEqual(deltas.map(d => d.sequence), [0, 1, 2])
    assert.ok(logs.some(l => l.evt === 'duplicate_sequence' && l.sequence === 1))
    assert.ok(logs.some(l => l.evt === 'downlink_first_frame' && l.sequence === 0))
  })

  it('honours audio.done as the barrier with final_sequence', () => {
    const { session, sent, agent, scope } = harness()
    start(session, scope)
    for (const seq of [0, 1, 2]) {
      agent.emit(scope.request_id, {
        type: 'agent.audio.delta', response_id: 'r-1:gen1',
        sequence: seq, audio: b64('x'),
      })
    }
    agent.emit(scope.request_id, {
      type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 2,
    })
    const done = sent.find(e => e.type === 'audio.done')
    assert.ok(done, 'done emitted')
    assert.equal(done.final_sequence, 2)
    assert.equal(done.response_id, 'r-1:gen1')
    assert.equal(done.generation, scope.generation)
  })

  it('holds audio.done until a late-arriving interior delta backfills the gap (毕玄 regression)', () => {
    // 反例来自 PR #159 复审：agent 发 0, 2, done(final_sequence=2)，
    // 缺 seq=1。旧 clamp 实现会立即发 done(0) 让客户端"完成"，seq=1
    // 迟到后被当作 post_done 丢弃 —— 违反 ESS-388 契约。
    // 新的 pending barrier 语义：done 到达时不发送，等 seq=1 到达后
    // 恰好发一次 done(2)，使用原始 final_sequence。
    const { session, sent, agent, scope, logs } = harness()
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 0, audio: b64('x') })
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 2, audio: b64('x') })
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 2 })
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'done must not be released while seq=1 is missing')
    assert.ok(logs.some(l => l.evt === 'done_barrier_pending' && l.pending_final_sequence === 2))
    // Backfill the missing delta — barrier releases with the ORIGINAL final_sequence.
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 1, audio: b64('x') })
    const dones = sent.filter(e => e.type === 'audio.done')
    assert.equal(dones.length, 1, 'exactly one done after the gap closes')
    assert.equal(dones[0].final_sequence, 2, 'the original final_sequence, not a clamped value')
  })

  it('waits for tail deltas when final_sequence exceeds the current high-watermark', () => {
    // `0, 1, done(3), 2, 3` — done arrives before the tail. Barrier must
    // wait, then release exactly one done(3) when seq=3 arrives.
    const { session, sent, agent, scope } = harness()
    start(session, scope)
    for (const seq of [0, 1]) {
      agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: seq, audio: b64('x') })
    }
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 3 })
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'no done while 2,3 missing')
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 2, audio: b64('x') })
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'still no done — seq=3 missing')
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 3, audio: b64('x') })
    const dones = sent.filter(e => e.type === 'audio.done')
    assert.equal(dones.length, 1, 'exactly one done after the full tail arrives')
    assert.equal(dones[0].final_sequence, 3)
  })

  it('audio.done with a fully dense 0..final_sequence releases immediately with the claimed final_sequence', () => {
    const { session, sent, agent, scope, logs } = harness()
    start(session, scope)
    for (const seq of [0, 1, 2]) {
      agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: seq, audio: b64('x') })
    }
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 2 })
    const done = sent.find(e => e.type === 'audio.done')
    assert.equal(done.final_sequence, 2)
    assert.equal(logs.filter(l => l.evt === 'done_barrier_gap_timeout').length, 0)
  })

  it('audio.done with final_sequence=-1 (empty response) releases once the empty-done deferral elapses', () => {
    // ESS-516: an empty done is held for `emptyDoneDeferMs` in case
    // upstream is jumping the gun. When the window elapses with no
    // deltas, it commits exactly as before — final_sequence stays -1.
    const clock = controlledClock()
    const { session, sent, agent, scope, logs } = harness({
      emptyDoneDeferMs: 1_500,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: -1 })
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'done deferred, not yet emitted')
    assert.ok(logs.some(l => l.evt === 'done_barrier_empty_deferred' && l.claimed_final_sequence === -1))
    assert.equal(clock.pendingCount(), 1, 'empty-done deferral timer armed')
    clock.fireAll()
    const done = sent.find(e => e.type === 'audio.done')
    assert.ok(done, 'done emitted after deferral elapses')
    assert.equal(done.final_sequence, -1)
    assert.ok(logs.some(l => l.evt === 'done_barrier_empty_committed'))
  })

  it('ESS-516 regression: audio.done(-1) followed by real deltas does NOT drop them as post_done', () => {
    // Real-device timeline (ESS-516 §一): upstream sent
    // audio_done(final_sequence=-1) at T+0, then 55 real deltas starting
    // 862ms later. The pre-fix fast path fired downlink_done(-1)
    // immediately and every delta was dropped as `post_done`, so the
    // watch received zero audio. With the empty-done deferral in place
    // the first delta invalidates the pending -1 and normal flow resumes.
    const clock = controlledClock()
    const { session, sent, agent, scope, logs } = harness({
      emptyDoneDeferMs: 1_500,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    // Upstream jumps the gun.
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: -1 })
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'done deferred, not yet emitted')
    assert.equal(clock.pendingCount(), 1, 'empty-done timer armed')
    // Real audio arrives before the deferral elapses.
    for (let seq = 0; seq < 3; seq++) {
      agent.emit(scope.request_id, {
        type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: seq, audio: b64('x'),
      })
    }
    assert.equal(clock.pendingCount(), 0, 'first delta cleared the empty-done timer')
    assert.ok(
      logs.some(l => l.evt === 'done_barrier_empty_invalidated' && l.reason === 'delta_arrived'),
      'invalidation was logged'
    )
    const deltas = sent.filter(e => e.type === 'audio.delta')
    assert.equal(deltas.length, 3, 'every real delta was forwarded (none dropped as post_done)')
    assert.equal(
      logs.filter(l => l.evt === 'stale_generation_dropped' && l.reason === 'post_done').length,
      0,
      'no post_done drops — the whole point of the fix'
    )
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'no done was sent while deltas were flowing')
    // Upstream then sends the real done — normal barrier flow releases it
    // with the true final_sequence, not the stale -1.
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 2 })
    const dones = sent.filter(e => e.type === 'audio.done')
    assert.equal(dones.length, 1)
    assert.equal(dones[0].final_sequence, 2, 'the corrected final_sequence, not the stale -1')
  })

  it('ESS-516: audio.done(-1) followed by a later audio.done(N) uses the corrected N', () => {
    // Same generation, two dones from upstream: -1 first, then a real
    // value once upstream realises there was audio. The deferral treats
    // the later done as authoritative.
    const clock = controlledClock()
    const { session, sent, agent, scope, logs } = harness({
      emptyDoneDeferMs: 1_500,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: -1 })
    assert.equal(clock.pendingCount(), 1, 'empty-done timer armed')
    // Real deltas + a corrected done arrive within the deferral window.
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 0, audio: b64('x') })
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 0 })
    const dones = sent.filter(e => e.type === 'audio.done')
    assert.equal(dones.length, 1)
    assert.equal(dones[0].final_sequence, 0, 'later done takes over the stale -1')
    // If a stray -1 done arrives even after commit, it must not double-emit.
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: -1 })
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 1, 'idempotent — no double emit')
    assert.ok(
      logs.some(l => l.evt === 'done_barrier_empty_invalidated' && l.reason === 'delta_arrived'),
      'delta invalidated the deferral'
    )
  })

  it('ESS-516 regression: duplicate audio_done(-1) during deferral stays idempotent (Jackson Bai review on PR #206)', () => {
    // Reviewer minimal repro: two identical `audio_done(-1)` back-to-back
    // inside the 1500ms deferral. The buggy version collapsed the second
    // one into an immediate `downlink_done(-1)` — any real delta after
    // that then hit `doneEmitted` and got dropped as `post_done`. The
    // duplicate must leave the deferral armed instead.
    const clock = controlledClock()
    const { session, sent, agent, scope, logs } = harness({
      emptyDoneDeferMs: 1_500,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: -1 })
    assert.equal(clock.pendingCount(), 1, 'empty-done timer armed on first -1')
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0)
    // Second identical -1 — must NOT commit or clear the timer.
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: -1 })
    assert.equal(clock.pendingCount(), 1, 'duplicate -1 kept the timer armed')
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'duplicate -1 did NOT commit an empty done')
    assert.ok(logs.some(l => l.evt === 'done_barrier_empty_duplicate'),
      'duplicate empty-done was logged as such')
    // Real audio then arrives — none of it should be dropped as post_done.
    for (let seq = 0; seq < 3; seq++) {
      agent.emit(scope.request_id, {
        type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: seq, audio: b64('x'),
      })
    }
    assert.equal(sent.filter(e => e.type === 'audio.delta').length, 3,
      'every delta forwarded — the whole point of keeping the deferral idempotent')
    assert.equal(
      logs.filter(l => l.evt === 'stale_generation_dropped' && l.reason === 'post_done').length,
      0, 'no post_done drops',
    )
    // Real done arrives — barrier releases with the true final_sequence.
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 2 })
    const dones = sent.filter(e => e.type === 'audio.done')
    assert.equal(dones.length, 1)
    assert.equal(dones[0].final_sequence, 2, 'corrected final_sequence, not the stale -1')
  })

  it('ESS-516: cancel while empty-done is deferred clears the timer without fail-closed', () => {
    const clock = controlledClock()
    const { session, sent, agent, scope, closes } = harness({
      emptyDoneDeferMs: 1_500,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: -1 })
    assert.equal(clock.pendingCount(), 1, 'empty-done timer armed')
    session.onFrame(JSON.stringify({
      type: 'cancel', session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
    }))
    assert.equal(clock.pendingCount(), 0, 'cancel cleared the empty-done timer')
    clock.fireAll()  // firing nothing — timer already cleared
    assert.equal(sent.filter(e => e.type === 'error').length, 0, 'no fail-closed — cancel is authoritative')
    assert.equal(closes.length, 0, 'socket stays open')
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'no done ever released after cancel')
  })

  it('ESS-516: emptyDoneDeferMs=0 preserves the historical immediate-release fast path', () => {
    // Escape hatch — deployments that don't want the deferral (e.g. test
    // rigs) can set it to 0 and get the original behaviour back.
    const { session, sent, agent, scope, logs } = harness({ emptyDoneDeferMs: 0 })
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: -1 })
    const done = sent.find(e => e.type === 'audio.done')
    assert.ok(done, 'done emitted immediately when deferral is disabled')
    assert.equal(done.final_sequence, -1)
    assert.equal(logs.filter(l => l.evt === 'done_barrier_empty_deferred').length, 0)
  })

  it('gap timeout fires exactly one structured fail-closed and drops late deltas', () => {
    // Reviewer requirement: gap timeout triggers a single structured
    // fail-closed/fallback; must NOT forge a smaller endpoint, must NOT
    // let the same turn double-execute.
    const clock = controlledClock()
    const { session, sent, agent, scope, closes, logs } = harness({
      doneBarrierGapMs: 2_000,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 0, audio: b64('x') })
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 2, audio: b64('x') })
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 2 })
    assert.equal(clock.pendingCount(), 1, 'barrier timer armed once')
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0)
    clock.fireAll()  // advance past doneBarrierGapMs
    const errs = sent.filter(e => e.type === 'error')
    assert.equal(errs.length, 1, 'exactly one structured fail-closed')
    assert.equal(errs[0].code, 'ERR_STREAM_GAP_TIMEOUT')
    assert.equal(errs[0].pending_final_sequence, 2, 'no forged smaller endpoint — pending stays 2')
    assert.equal(errs[0].dense_prefix, 0)
    assert.equal(closes[0]?.code, 1008, 'socket closed once')
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'no done was ever released')
    // Late delta after the fail-closed must not resurrect this generation.
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 1, audio: b64('x') })
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'still no done — turn is dead')
    assert.equal(sent.filter(e => e.type === 'audio.delta' && e.sequence === 1).length, 0, 'late delta not forwarded')
    assert.ok(logs.some(l => l.evt === 'done_barrier_gap_timeout' && l.pending_final_sequence === 2))
  })

  it('cancel while barrier is pending stops the gap timer without a fail-closed', () => {
    const clock = controlledClock()
    const { session, sent, agent, scope, closes } = harness({
      doneBarrierGapMs: 2_000,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 0, audio: b64('x') })
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 2 })
    assert.equal(clock.pendingCount(), 1, 'barrier timer armed')
    session.onFrame(JSON.stringify({
      type: 'cancel', session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
    }))
    assert.equal(clock.pendingCount(), 0, 'cancel cleared the barrier timer')
    clock.fireAll()  // firing nothing — timer already cleared
    assert.equal(sent.filter(e => e.type === 'error').length, 0, 'cancel is authoritative — no fail-closed')
    assert.equal(closes.length, 0, 'socket stays open under cancel')
  })

  it('a second audio.done is idempotent (does not double-emit)', () => {
    const { session, sent, agent, scope } = harness()
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 0, audio: b64('x') })
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 0 })
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 0 })
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 1)
  })

  it('deltas arriving after audio.done are dropped as stale (post_done)', () => {
    const { session, sent, agent, scope, logs } = harness()
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 0, audio: b64('x') })
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 0 })
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 1, audio: b64('x') })
    assert.equal(sent.filter(e => e.type === 'audio.delta').length, 1)
    assert.ok(logs.some(l => l.evt === 'stale_generation_dropped' && l.reason === 'post_done'))
  })
})

describe('RealtimeSession — heartbeat', () => {
  it('replies to client ping with pong containing the original nonce', () => {
    const { session, sent, scope } = harness()
    start(session, scope)
    session.onFrame(JSON.stringify({ type: 'ping', nonce: 'abc' }))
    const pong = sent.find(e => e.type === 'pong')
    assert.equal(pong?.nonce, 'abc')
  })
})
