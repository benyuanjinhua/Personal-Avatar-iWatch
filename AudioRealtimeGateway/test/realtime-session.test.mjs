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

// ESS-551 A4: conversation_id/turn_id 端到端 —— meta 子对象承载、关闭后
// 拒绝迟到会话、注册表有界。对应 Watch 侧 ConversationHandle 生命周期。
describe('RealtimeSession — ESS-551 conversation identity', () => {
  const CONV = '0198c001-0000-7000-8000-0000000000c1'

  function startWithMeta(session, scope, meta) {
    session.onFrame(JSON.stringify({
      type: 'session.start',
      session_id: scope.session_id, request_id: scope.request_id,
      generation: scope.generation, protocol_version: 1,
      ...(meta ? { meta } : {}),
    }))
  }

  it('accepts meta on session.start and logs conversation/turn identity', () => {
    const { session, sent, logs, scope } = harness()
    startWithMeta(session, scope, { conversation_id: CONV + '-a', turn_id: 't-1' })
    assert.equal(sent[0]?.type, 'ready')
    const ready = logs.find(l => l.evt === 'session_ready')
    assert.equal(ready?.conversation_id, CONV + '-a')
    assert.equal(ready?.turn_id, 't-1')
  })

  it('session.start without meta still works (fallback to requestId/sessionId baseline)', () => {
    const { session, sent, logs, scope } = harness()
    start(session, scope)
    assert.equal(sent[0]?.type, 'ready')
    const ready = logs.find(l => l.evt === 'session_ready')
    assert.equal(ready?.conversation_id, null)
  })

  it('close frame carrying meta.conversation_id closes the conversation; later start is rejected', () => {
    const first = harness()
    startWithMeta(first.session, first.scope, { conversation_id: CONV + '-b', turn_id: 't-1' })
    first.session.onFrame(JSON.stringify({
      type: 'close', reason: 'conversation_end', meta: { conversation_id: CONV + '-b' },
    }))
    assert.ok(first.logs.some(l => l.evt === 'conversation_close_recorded'
      && l.conversation_id === CONV + '-b'))

    // 同一 conversation 的任何后续 session.start（迟到帧）必须被拒绝。
    const second = harness({ scope: { device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-2', generation: 1 } })
    startWithMeta(second.session, second.scope, { conversation_id: CONV + '-b', turn_id: 't-2' })
    assert.equal(second.sent[0]?.type, 'error')
    assert.equal(second.sent[0]?.code, 'ERR_CONVERSATION_CLOSED')
    assert.ok(second.logs.some(l => l.evt === 'conversation_start_rejected'
      && l.drop_reason === 'conversation_closed'))
  })

  it('plain socket teardown does NOT close the conversation (multi-round reuse)', () => {
    const first = harness()
    startWithMeta(first.session, first.scope, { conversation_id: CONV + '-c', turn_id: 't-1' })
    first.session.onSocketClose(1000, 'peer_closed')

    const second = harness({ scope: { device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-2', generation: 1 } })
    startWithMeta(second.session, second.scope, { conversation_id: CONV + '-c', turn_id: 't-2' })
    assert.equal(second.sent[0]?.type, 'ready')
  })

  it('close frame without meta does NOT close the conversation', () => {
    const first = harness()
    startWithMeta(first.session, first.scope, { conversation_id: CONV + '-d', turn_id: 't-1' })
    first.session.onFrame(JSON.stringify({ type: 'close', reason: 'client_close' }))

    const second = harness({ scope: { device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-2', generation: 1 } })
    startWithMeta(second.session, second.scope, { conversation_id: CONV + '-d', turn_id: 't-2' })
    assert.equal(second.sent[0]?.type, 'ready')
  })

  it('closed registry expires entries after TTL (24h)', () => {
    const clock = controlledClock()
    let now = 1_800_000_000_000
    const first = harness({ now: () => now, ...clock })
    startWithMeta(first.session, first.scope, { conversation_id: CONV + '-e', turn_id: 't-1' })
    first.session.onFrame(JSON.stringify({
      type: 'close', reason: 'conversation_end', meta: { conversation_id: CONV + '-e' },
    }))

    now += 24 * 60 * 60 * 1000 + 1 // 越过 TTL
    const second = harness({ scope: { device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-2', generation: 1 }, now: () => now, ...clock })
    startWithMeta(second.session, second.scope, { conversation_id: CONV + '-e', turn_id: 't-2' })
    assert.equal(second.sent[0]?.type, 'ready')
  })

  it('closed registry is bounded (cap 1000, oldest evicted)', async () => {
    const { _resetClosedConversationsForTests } = await import('../realtime-session.mjs')
    _resetClosedConversationsForTests()
    let now = 1_800_000_000_000
    const clock = controlledClock()
    for (let i = 0; i < 1001; i++) {
      const h = harness({ now: () => now, ...clock })
      const conv = `0198c001-0000-7000-8000-${String(i).padStart(12, '0')}`
      startWithMeta(h.session, h.scope, { conversation_id: conv, turn_id: 't' })
      h.session.onFrame(JSON.stringify({
        type: 'close', reason: 'conversation_end', meta: { conversation_id: conv },
      }))
      now += 1
    }
    // 最早的一条应已被淘汰：重新 start 不再拒绝。
    const oldest = harness({ scope: { device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-oldest', generation: 1 }, now: () => now, ...clock })
    startWithMeta(oldest.session, oldest.scope, {
      conversation_id: '0198c001-0000-7000-8000-000000000000', turn_id: 't',
    })
    assert.equal(oldest.sent[0]?.type, 'ready')
    // 最新的一条仍在册：必须拒绝。
    const newest = harness({ scope: { device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-newest', generation: 1 }, now: () => now, ...clock })
    startWithMeta(newest.session, newest.scope, {
      conversation_id: '0198c001-0000-7000-8000-000000001000', turn_id: 't',
    })
    assert.equal(newest.sent[0]?.code, 'ERR_CONVERSATION_CLOSED')
    _resetClosedConversationsForTests()
  })
})
