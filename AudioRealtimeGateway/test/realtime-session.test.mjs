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

  it('audio.done with final_sequence=-1 releases after a bounded empty-response window', () => {
    const clock = controlledClock()
    const { session, sent, agent, scope, logs } = harness({
      doneBarrierGapMs: 2_000,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: -1 })
    assert.equal(sent.some(e => e.type === 'audio.done'), false, 'ambiguous empty done is held')
    assert.equal(clock.pendingCount(), 1)
    clock.fireAll()
    const done = sent.find(e => e.type === 'audio.done')
    assert.ok(done, 'done emitted once the empty-response window elapsed')
    assert.equal(done.final_sequence, -1)
    assert.ok(logs.some(l => l.evt === 'empty_done_window_elapsed'))
  })

  it('withdraws premature done(-1) and delivers all later deltas before the real done(N)', () => {
    const clock = controlledClock()
    const { session, sent, agent, scope, logs } = harness({
      doneBarrierGapMs: 2_000,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: -1 })
    for (const sequence of [0, 1, 2]) {
      agent.emit(scope.request_id, {
        type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence, audio: b64('x'),
      })
    }
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 2 })
    assert.deepEqual(sent.filter(e => e.type === 'audio.delta').map(e => e.sequence), [0, 1, 2])
    assert.deepEqual(sent.filter(e => e.type === 'audio.done').map(e => e.final_sequence), [2])
    assert.equal(clock.pendingCount(), 0, 'provisional empty-done timer was cancelled')
    assert.ok(logs.some(l => l.evt === 'premature_empty_done_withdrawn' && l.request_id === 'r-1'))
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
    assert.ok(logs.some(l => l.evt === 'post_done_audio_dropped'
      && l.code === 'ERR_UPSTREAM_AUDIO_AFTER_DONE'
      && l.request_id === 'r-1' && l.dropped_count === 1))
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

describe('RealtimeSession — ESS-551 conversation meta', () => {
  it('accepts meta in session.start and emits session_open_meta log', () => {
    const { session, sent, logs, scope } = harness()
    session.onFrame(JSON.stringify({
      type: 'session.start', session_id: scope.session_id, request_id: scope.request_id,
      generation: scope.generation, protocol_version: 1,
      meta: { conversation_id: 'cid-meta-accept', turn_id: 'turn-3' },
    }))
    const ready = sent.find(e => e.type === 'ready')
    assert.ok(ready, 'ready must be emitted when meta is present')
    const metaLog = logs.find(l => l.evt === 'session_open_meta')
    assert.ok(metaLog, 'session_open_meta log must be emitted')
    assert.equal(metaLog.conversation_id, 'cid-meta-accept')
    assert.equal(metaLog.turn_id, 'turn-3')
  })

  it('accepts session.start without meta (backward compatible)', () => {
    const { session, sent, scope } = harness()
    start(session, scope)
    assert.ok(sent.find(e => e.type === 'ready'), 'ready must be emitted even without meta')
  })

  it('rejects session.start for a closed conversation with ERR_CONVERSATION_CLOSED', () => {
    // First connection — open then close with a conversation_id.
    const h1 = harness()
    start(h1.session, h1.scope)
    h1.session.onFrame(JSON.stringify({
      type: 'close', reason: 'done',
      meta: { conversation_id: 'cid-closed-reject' },
    }))
    assert.ok(h1.logs.some(l => l.evt === 'conversation_closed' && l.conversation_id === 'cid-closed-reject'))

    // Second connection — same conversation_id, must be rejected.
    const h2 = harness({
      scope: { device_id: 'jackson-iphone', session_id: 's-2', request_id: 'r-2', generation: 1 },
    })
    h2.session.onFrame(JSON.stringify({
      type: 'session.start', session_id: 's-2', request_id: 'r-2',
      generation: 1, protocol_version: 1,
      meta: { conversation_id: 'cid-closed-reject', turn_id: 'turn-4' },
    }))
    const dropLog = h2.logs.find(l => l.evt === 'conversation_closed_drop')
    assert.ok(dropLog, 'conversation_closed_drop log must be emitted')
    assert.equal(dropLog.conversation_id, 'cid-closed-reject')
    assert.equal(dropLog.reason, 'conversation already closed')
    const err = h2.sent.find(e => e.type === 'error')
    assert.ok(err, 'error frame must be emitted')
    assert.equal(err.code, 'ERR_CONVERSATION_CLOSED')
    assert.equal(h2.sent.filter(e => e.type === 'ready').length, 0, 'no ready for a closed conversation')
  })

  it('close without meta does not register any conversation', () => {
    const h1 = harness()
    start(h1.session, h1.scope)
    h1.session.onFrame(JSON.stringify({ type: 'close', reason: 'done' }))
    assert.equal(h1.logs.filter(l => l.evt === 'conversation_closed').length, 0)

    const h2 = harness({
      scope: { device_id: 'jackson-iphone', session_id: 's-2', request_id: 'r-2', generation: 1 },
    })
    h2.session.onFrame(JSON.stringify({
      type: 'session.start', session_id: 's-2', request_id: 'r-2',
      generation: 1, protocol_version: 1,
      meta: { conversation_id: 'cid-unrelated-after-plain-close', turn_id: 'turn-1' },
    }))
    assert.ok(h2.sent.find(e => e.type === 'ready'), 'new conversation must succeed after old close w/o meta')
  })

  it('expires closed conversations after the TTL (late frame window is bounded)', () => {
    let nowMs = 1_000_000
    const h1 = harness({ now: () => nowMs })
    start(h1.session, h1.scope)
    h1.session.onFrame(JSON.stringify({
      type: 'close', reason: 'done',
      meta: { conversation_id: 'cid-ttl-expiry' },
    }))
    assert.ok(h1.logs.some(l => l.evt === 'conversation_closed'))

    // Within the TTL the conversation is still rejected…
    const h2 = harness({
      now: () => nowMs,
      scope: { device_id: 'jackson-iphone', session_id: 's-2', request_id: 'r-2', generation: 1 },
    })
    h2.session.onFrame(JSON.stringify({
      type: 'session.start', session_id: 's-2', request_id: 'r-2',
      generation: 1, protocol_version: 1,
      meta: { conversation_id: 'cid-ttl-expiry' },
    }))
    assert.equal(h2.sent.filter(e => e.type === 'ready').length, 0)
    assert.ok(h2.logs.some(l => l.evt === 'conversation_closed_drop'))

    // …and once the TTL has passed the entry is evicted and the id no
    // longer blocks starts (safe because Watch UUIDv7 ids are never reused).
    nowMs += 15 * 60 * 1000 + 1
    const h3 = harness({
      now: () => nowMs,
      scope: { device_id: 'jackson-iphone', session_id: 's-3', request_id: 'r-3', generation: 1 },
    })
    h3.session.onFrame(JSON.stringify({
      type: 'session.start', session_id: 's-3', request_id: 'r-3',
      generation: 1, protocol_version: 1,
      meta: { conversation_id: 'cid-ttl-expiry' },
    }))
    assert.ok(h3.sent.find(e => e.type === 'ready'), 'expired registry entry must not block a start')
  })

  it('evicts the oldest closed conversation beyond the capacity cap', () => {
    // Drive the registry over its 4096-entry cap with real close frames;
    // the first-closed id must fall out while the newest stays registered.
    const nowMs = 2_000_000
    const closeConversation = (cid) => {
      const h = harness({
        now: () => nowMs,
        scope: { device_id: 'jackson-iphone', session_id: `s-${cid}`, request_id: `r-${cid}`, generation: 1 },
      })
      start(h.session, h.scope)
      h.session.onFrame(JSON.stringify({
        type: 'close', reason: 'done', meta: { conversation_id: cid },
      }))
    }
    closeConversation('cid-cap-oldest')
    for (let i = 0; i < 4096; i += 1) closeConversation(`cid-cap-filler-${i}`)

    // Oldest evicted → its start is accepted again.
    const hOld = harness({
      now: () => nowMs,
      scope: { device_id: 'jackson-iphone', session_id: 's-old', request_id: 'r-old', generation: 1 },
    })
    hOld.session.onFrame(JSON.stringify({
      type: 'session.start', session_id: 's-old', request_id: 'r-old',
      generation: 1, protocol_version: 1,
      meta: { conversation_id: 'cid-cap-oldest' },
    }))
    assert.ok(hOld.sent.find(e => e.type === 'ready'), 'evicted oldest entry must not block a start')

    // Newest still registered → still rejected.
    const hNew = harness({
      now: () => nowMs,
      scope: { device_id: 'jackson-iphone', session_id: 's-new', request_id: 'r-new', generation: 1 },
    })
    hNew.session.onFrame(JSON.stringify({
      type: 'session.start', session_id: 's-new', request_id: 'r-new',
      generation: 1, protocol_version: 1,
      meta: { conversation_id: 'cid-cap-filler-4095' },
    }))
    assert.equal(hNew.sent.filter(e => e.type === 'ready').length, 0)
    assert.ok(hNew.logs.some(l => l.evt === 'conversation_closed_drop'))
  })
})
