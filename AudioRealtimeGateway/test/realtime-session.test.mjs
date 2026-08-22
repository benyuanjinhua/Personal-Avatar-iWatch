// Unit tests for RealtimeSession (ESS-403 acceptance #2): delta + done
// carry verifiable generation/sequence/final_sequence and clients can
// handle out-of-order / duplicate agent events safely.

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { RealtimeSession, pcm16Level } from '../realtime-session.mjs'
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
    // ESS-959: commit deadline watchdog disabled by default in the harness —
    // the controlledClock asserts an exact pending-timer count, and the
    // watchdog arms a timer on session.start. The dedicated commit-deadline
    // tests re-enable it with an explicit value.
    commitDeadlineMs: 0,
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
    // ESS-958: error frame carries expected/got sequence so the client can
    // self-heal or diagnose instead of blindly reconnecting.
    assert.equal(err.expected_sequence, 3)
    assert.equal(err.got_sequence, 4)
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

describe('pcm16Level (ESS-891)', () => {
  function pcm(samples) {
    const buf = Buffer.alloc(samples.length * 2)
    samples.forEach((s, i) => buf.writeInt16LE(s, i * 2))
    return buf
  }

  it('measures silence as zero rms/peak', () => {
    const level = pcm16Level(pcm([0, 0, 0, 0]))
    assert.equal(level.rms, 0)
    assert.equal(level.peak, 0)
    assert.equal(level.frames, 4)
  })

  it('measures a full-scale sample as 32767 peak', () => {
    const level = pcm16Level(pcm([32767, -32767]))
    assert.equal(level.peak, 32767)
    assert.equal(level.rms, 32767)
  })

  it('reports the -6.02 dBFS reference for a half-scale constant signal', () => {
    const level = pcm16Level(pcm([16384, 16384, 16384, 16384]))
    assert.ok(Math.abs(level.peak_dbfs - (-6.02)) < 0.05, `peak_dbfs=${level.peak_dbfs}`)
  })

  // ESS-959: 建连后迟迟不 commit 的看门狗。
  it('fails closed when no audio.commit arrives within the commit deadline', () => {
    const clock = controlledClock()
    const { session, sent, scope, closes, logs } = harness({
      commitDeadlineMs: 30_000,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    // 只发一帧，从不 commit。
    session.onFrame(JSON.stringify({
      type: 'audio.append',
      session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
      sequence: 0, audio: b64('frame'),
    }))
    assert.equal(clock.pendingCount(), 1, 'commit deadline armed on session.start')
    clock.fireAll()
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_COMMIT_DEADLINE_TIMEOUT')
    assert.ok(logs.some(l => l.evt === 'commit_deadline_timeout' && l.frames_seen === 1))
    assert.ok(closes.some(c => c.code === 1008))
  })

  it('commit clears the deadline so a healthy turn is not killed', () => {
    const clock = controlledClock()
    const { session, scope } = harness({
      commitDeadlineMs: 30_000,
      setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    })
    start(session, scope)
    session.onFrame(JSON.stringify({
      type: 'audio.append',
      session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
      sequence: 0, audio: b64('frame'),
    }))
    session.onFrame(JSON.stringify({
      type: 'audio.commit',
      session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
      sequence: 0,
    }))
    assert.equal(clock.pendingCount(), 0, 'commit cleared the deadline timer')
  })
})


// ESS-969：一个回合承载多段回答（工具调用：先「我正在查询」，再给真答案）。
//
// 这是 ESS-957 一直欠的那条确定性用例。修复前的实测形态（issue 里贴的复现）：
//   第一段后：下发 delta=1、audio.done=true
//   第二段后：下发 delta=1        ← 第二段一帧都没到客户端
//   post_done_audio_dropped=3、错误码 ERR_UPSTREAM_AUDIO_AFTER_DONE
// 根因是 `doneEmitted` 一旦置位就没有任何复位路径，第二段每一帧都走
// post-done 丢弃分支。
describe('ESS-969 — 一个回合的多段回答', () => {
  function drive(clock) {
    const h = harness(clock ? { setTimer: clock.setTimer, clearTimer: clock.clearTimer } : {})
    start(h.session, h.scope)
    return h
  }
  const deltasOf = sent => sent.filter(f => f.type === 'audio.delta')
  const donesOf = sent => sent.filter(f => f.type === 'audio.done')

  it('第二段的音频必须到达客户端，而不是被 post-done 丢弃', () => {
    const clock = controlledClock()
    const { session, sent, agent, scope } = drive(clock)

    // 第 1 段：一帧音频 + 非最终 done（上游还有未终结的 task）
    agent.emit(scope.request_id, {
      type: 'agent.audio.delta', response_id: 'r-1:gen1',
      sequence: 0, audio: b64('seg1'), sample_rate: 24000, codec: 'pcm_s16le',
    })
    agent.emit(scope.request_id, {
      type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 0, final: false,
    })
    clock.fireAll()

    // 第 2 段：工具结果回来了
    agent.emit(scope.request_id, {
      type: 'agent.audio.delta', response_id: 'r-1:gen1',
      sequence: 1, audio: b64('seg2'), sample_rate: 24000, codec: 'pcm_s16le',
    })
    agent.emit(scope.request_id, {
      type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 1, final: true,
    })
    clock.fireAll()

    // 修复前这里是 1；第二段整段消失。
    assert.equal(deltasOf(sent).length, 2, '两段音频都必须下发')
    assert.deepEqual(deltasOf(sent).map(f => f.sequence), [0, 1],
      '序号在整个回合内连续递增——复位会让第二段撞上第一段并被去重丢掉')
    assert.equal(session.postDoneAudioDropped, 0, '不得有任何 post-done 丢弃')
    assert.ok(!sent.some(f => f.type === 'audio.segment_dropped'),
      '第二段是正常回答，不该被当成越界帧告警')
  })

  it('段落 done 与回合 done 在协议上可区分', () => {
    const clock = controlledClock()
    const { sent, agent, scope } = drive(clock)
    for (const [seq, final] of [[0, false], [1, true]]) {
      agent.emit(scope.request_id, {
        type: 'agent.audio.delta', response_id: 'r-1:gen1',
        sequence: seq, audio: b64('x'), sample_rate: 24000, codec: 'pcm_s16le',
      })
      agent.emit(scope.request_id, {
        type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: seq, final,
      })
      clock.fireAll()
    }
    const dones = donesOf(sent)
    assert.equal(dones.length, 2)
    // 客户端据此区分：false → markAnswerInterim 回 thinking 等下一段；
    // true → markAnswerFinished 开下一轮。不让客户端靠猜。
    assert.deepEqual(dones.map(d => d.final), [false, true])
    assert.deepEqual(dones.map(d => d.segment_index), [0, 1])
  })

  // 向后兼容：老客户端读不到 `final`，把任何 audio.done 都当回合结束。
  // 那正是修复前的行为——第一段照常播完、不卡死、不崩。
  it('老客户端语义不回退：第一段仍是一个完整可收口的 audio.done', () => {
    const clock = controlledClock()
    const { sent, agent, scope } = drive(clock)
    agent.emit(scope.request_id, {
      type: 'agent.audio.delta', response_id: 'r-1:gen1',
      sequence: 0, audio: b64('seg1'), sample_rate: 24000, codec: 'pcm_s16le',
    })
    agent.emit(scope.request_id, {
      type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 0, final: false,
    })
    clock.fireAll()
    const first = donesOf(sent)[0]
    assert.ok(first, '第一段必须有 audio.done')
    assert.equal(first.final_sequence, 0, '老客户端只认这个字段，语义不变')
    assert.equal(first.response_id, 'r-1:gen1')
  })

  // 缺 `final` 字段（老上游 / mock）时按单段处理，行为与修复前完全一致。
  it('done 缺 final 字段时按最终段处理，单段行为不变', () => {
    const clock = controlledClock()
    const { sent, agent, scope } = drive(clock)
    agent.emit(scope.request_id, {
      type: 'agent.audio.delta', response_id: 'r-1:gen1',
      sequence: 0, audio: b64('only'), sample_rate: 24000, codec: 'pcm_s16le',
    })
    agent.emit(scope.request_id, {
      type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 0,
    })
    clock.fireAll()
    assert.equal(donesOf(sent)[0].final, true)
    // 之后再来的帧仍然是越界帧，丢弃逻辑不能被本次改动放宽。
    agent.emit(scope.request_id, {
      type: 'agent.audio.delta', response_id: 'r-1:gen1',
      sequence: 1, audio: b64('late'), sample_rate: 24000, codec: 'pcm_s16le',
    })
    assert.equal(deltasOf(sent).length, 1, '最终段之后的帧必须照旧丢弃')
  })

  // 上游最后一个 task 终结、但没有再发第二段音频：必须补一个终态帧，
  // 否则客户端会永远停在 thinking 等一段不会来的回答。
  it('task 全部终结后补发回合终态帧', () => {
    const clock = controlledClock()
    const { sent, agent, scope } = drive(clock)
    agent.emit(scope.request_id, {
      type: 'agent.audio.delta', response_id: 'r-1:gen1',
      sequence: 0, audio: b64('seg1'), sample_rate: 24000, codec: 'pcm_s16le',
    })
    agent.emit(scope.request_id, {
      type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 0, final: false,
    })
    clock.fireAll()
    assert.equal(donesOf(sent).at(-1).final, false)

    agent.emit(scope.request_id, {
      type: 'agent.turn.done', response_id: 'r-1:gen1', segments: 1,
    })
    const last = donesOf(sent).at(-1)
    assert.equal(last.final, true, '回合终态必须显式下发')
    assert.equal(donesOf(sent).length, 2)
  })
})
