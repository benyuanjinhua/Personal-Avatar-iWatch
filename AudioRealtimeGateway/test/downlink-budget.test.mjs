// ESS-746: the downlink path must be bounded end to end.
//
// Three independent ceilings, one per hop:
//   • QwenAgentTransport  — per-frame size / shape and a per-turn budget on
//     what the (separately deployed, untrusted) upstream may produce.
//   • RealtimeSession     — sequence window + per-session frame/byte budget,
//     which is what actually bounds `seenDownlinkSequences`.
//   • createDownlinkGuard — socket `bufferedAmount` backpressure, the only
//     signal that a Watch stopped draining.
//
// Each test drives a real oversized / endless / stalled scenario rather than
// asserting the constants exist.

import assert from 'node:assert/strict'
import { afterEach, describe, it, test } from 'node:test'
import { WebSocketServer } from 'ws'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'
import { QwenAgentTransport } from '../qwen-agent-transport.mjs'
import { createDownlinkGuard } from '../server.mjs'

function harness(overrides = {}) {
  const sent = []
  const logs = []
  const closes = []
  const agent = new ScriptedAgentTransport()
  const scope = { device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-1', generation: 1 }
  const timers = []
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: (code, reason) => closes.push({ code, reason }),
    agentTransport: agent,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0,
    idleDisconnectMs: 0,
    uplinkCommitTimeoutMs: 0,
    setTimer: (fn, ms) => { const t = { fn, ms }; timers.push(t); return t },
    clearTimer: t => { const i = timers.indexOf(t); if (i >= 0) timers.splice(i, 1) },
    ...overrides,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start',
    session_id: scope.session_id, request_id: scope.request_id,
    generation: scope.generation, protocol_version: 1,
  }))
  const responseId = 'r-1:gen1'
  const delta = (sequence, audio = 'AAAA') => agent.emit('r-1', {
    type: 'agent.audio.delta', response_id: responseId, sequence, audio,
  })
  const done = final_sequence => agent.emit('r-1', {
    type: 'agent.audio.done', response_id: responseId, final_sequence,
  })
  return { session, sent, logs, closes, agent, scope, timers, delta, done }
}

const errorOf = sent => sent.find(frame => frame.type === 'error')

describe('RealtimeSession — downlink budget (ESS-746)', () => {
  it('passes traffic that stays inside the budget', () => {
    const { sent, delta, done } = harness({ maxDownlinkFrames: 8, maxDownlinkBytes: 4096 })
    delta(0); delta(1); done(1)
    assert.equal(errorOf(sent), undefined)
    assert.equal(sent.filter(frame => frame.type === 'audio.delta').length, 2)
    assert.equal(sent.at(-1).type, 'audio.done')
    assert.equal(sent.at(-1).final_sequence, 1)
  })

  it('stops an endless upstream at the frame cap instead of growing the dedup set', () => {
    const { session, sent, logs, closes, delta } = harness({ maxDownlinkFrames: 4 })
    for (let sequence = 0; sequence < 200; sequence++) delta(sequence)
    const error = errorOf(sent)
    assert.equal(error?.code, 'ERR_DOWNLINK_BUDGET')
    assert.equal(error.retriable, false)
    assert.equal(closes[0]?.code, 1008)
    // The set is what would have leaked: it must never exceed the cap, and
    // the deltas past the ceiling are not forwarded either.
    assert.ok(session.seenDownlinkSequences.size <= 4, `set grew to ${session.seenDownlinkSequences.size}`)
    assert.equal(sent.filter(frame => frame.type === 'audio.delta').length, 4)
    assert.equal(logs.filter(item => item.evt === 'downlink_budget_exceeded').length, 1)
  })

  it('rejects a sequence beyond the window even when it arrives first', () => {
    const { sent, logs, delta } = harness({ maxDownlinkFrames: 4 })
    delta(1_000_000)
    assert.equal(errorOf(sent)?.code, 'ERR_DOWNLINK_BUDGET')
    const log = logs.find(item => item.evt === 'downlink_budget_exceeded')
    assert.equal(log.reason, 'sequence_out_of_window')
    assert.equal(log.sequence, 1_000_000)
  })

  it('charges the byte budget and fails once it is exhausted', () => {
    const audio = 'A'.repeat(1_000)
    const { session, sent, logs, delta } = harness({ maxDownlinkFrames: 64, maxDownlinkBytes: 2_500 })
    delta(0, audio); delta(1, audio)
    assert.equal(errorOf(sent), undefined)
    assert.equal(session.downlinkBytes, 2_000)
    delta(2, audio)
    assert.equal(errorOf(sent)?.code, 'ERR_DOWNLINK_BUDGET')
    assert.equal(logs.find(item => item.evt === 'downlink_budget_exceeded').reason, 'session_budget_exhausted')
  })

  it('does not charge duplicate sequences to the byte budget', () => {
    const audio = 'A'.repeat(1_000)
    const { session, sent, delta } = harness({ maxDownlinkFrames: 64, maxDownlinkBytes: 2_500 })
    delta(0, audio); delta(0, audio); delta(0, audio)
    assert.equal(errorOf(sent), undefined)
    assert.equal(session.downlinkBytes, 1_000)
  })

  it('fails an unsatisfiable done barrier immediately rather than after the gap timeout', () => {
    const { sent, logs, timers, delta, done } = harness({ maxDownlinkFrames: 4, doneBarrierGapMs: 30_000 })
    delta(0)
    done(2_000_000)
    assert.equal(errorOf(sent)?.code, 'ERR_DOWNLINK_BUDGET')
    assert.equal(logs.find(item => item.evt === 'downlink_budget_exceeded').reason, 'final_sequence_out_of_window')
    assert.equal(timers.length, 0, 'no barrier timer should be armed for an impossible barrier')
  })
})

describe('QwenAgentTransport — upstream frame validation (ESS-746)', () => {
  const servers = []
  afterEach(async () => {
    await Promise.all(servers.splice(0).map(server => new Promise(resolve => server.close(resolve))))
  })

  async function upstream(onReady) {
    const server = new WebSocketServer({ port: 0 })
    servers.push(server)
    server.on('connection', ws => {
      ws.on('message', raw => {
        const message = JSON.parse(raw.toString())
        if (message.type === 'connect') {
          ws.send(JSON.stringify({ type: 'voice.ready' }))
          onReady(ws)
        }
      })
    })
    await new Promise(resolve => server.once('listening', resolve))
    return `ws://127.0.0.1:${server.address().port}/api/realtime`
  }

  function waitFor(predicate, timeoutMs = 2_000) {
    const started = Date.now()
    return new Promise((resolve, reject) => {
      const poll = () => {
        if (predicate()) return resolve()
        if (Date.now() - started > timeoutMs) return reject(new Error('waitFor timeout'))
        setTimeout(poll, 5)
      }
      poll()
    })
  }

  async function run(onReady, options) {
    const url = await upstream(onReady)
    const events = []; const logs = []
    const transport = new QwenAgentTransport({
      gatewayUrl: url, log: (evt, extra) => logs.push({ evt, ...extra }), ...options,
    })
    transport.openTurn({
      requestId: 'r1', sessionId: 's1', generation: 1, responseId: 'r1:gen1',
      onEvent: event => events.push(event),
    })
    await waitFor(() => events.length > 0)
    return { events, logs }
  }

  it('rejects an oversized audio.delta instead of forwarding it', async () => {
    const oversized = 'A'.repeat(4_096)
    const { events, logs } = await run(
      ws => ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: oversized })),
      { maxDownlinkFrameBytes: 1_024 },
    )
    assert.equal(events[0].type, 'agent.error')
    assert.equal(events[0].code, 'ERR_UPSTREAM_FRAME_SIZE')
    assert.ok(!events.some(event => event.type === 'agent.audio.delta'))
    const rejected = logs.find(item => item.evt === 'upstream_frame_rejected')
    assert.equal(rejected.audio_length, 4_096)
    assert.equal(rejected.cap, 1_024)
  })

  it('rejects a malformed (non-base64) audio payload', async () => {
    const { events, logs } = await run(
      ws => ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: '!!not base64!!' })),
    )
    assert.equal(events[0].code, 'ERR_UPSTREAM_FRAME_INVALID')
    assert.ok(logs.some(item => item.evt === 'upstream_frame_rejected'))
  })

  it('rejects a non-string audio payload', async () => {
    const { events } = await run(
      ws => ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: 12_345 })),
    )
    assert.equal(events[0].code, 'ERR_UPSTREAM_FRAME_INVALID')
  })

  it('cuts an endless upstream off at the per-turn budget', async () => {
    const { events, logs } = await run(
      ws => {
        for (let sequence = 0; sequence < 50; sequence++) {
          ws.send(JSON.stringify({ type: 'audio.delta', sequence, audio: 'AAAA' }))
        }
      },
      { maxDownlinkFrames: 3 },
    )
    await waitFor(() => events.some(event => event.type === 'agent.error'))
    assert.equal(events.filter(event => event.type === 'agent.audio.delta').length, 3)
    const error = events.find(event => event.type === 'agent.error')
    assert.equal(error.code, 'ERR_UPSTREAM_BUDGET_EXCEEDED')
    // Exactly one terminal error for the turn, however many frames follow.
    assert.equal(events.filter(event => event.type === 'agent.error').length, 1)
    assert.equal(logs.filter(item => item.evt === 'upstream_frame_rejected').length, 1)
  })

  it('caps the per-turn byte budget independently of the frame count', async () => {
    const audio = 'A'.repeat(1_000)
    const { events } = await run(
      ws => {
        for (let sequence = 0; sequence < 10; sequence++) {
          ws.send(JSON.stringify({ type: 'audio.delta', sequence, audio }))
        }
      },
      { maxDownlinkFrames: 1_000, maxDownlinkBytes: 2_500 },
    )
    await waitFor(() => events.some(event => event.type === 'agent.error'))
    assert.equal(events.filter(event => event.type === 'agent.audio.delta').length, 2)
    assert.equal(events.find(event => event.type === 'agent.error').code, 'ERR_UPSTREAM_BUDGET_EXCEEDED')
  })
})

describe('createDownlinkGuard — slow consumer (ESS-746)', () => {
  function fakeWs(bufferedAmount = 0) {
    return {
      bufferedAmount,
      sent: [], closed: null, terminated: false,
      send(text) { this.sent.push(text) },
      close(code, reason) { this.closed = { code, reason } },
      terminate() { this.terminated = true },
    }
  }

  function guardFor(ws, options = {}) {
    const logs = []
    const timers = []
    const guard = createDownlinkGuard({
      ws, scope: { request_id: 'r-1', session_id: 's-1', generation: 1 },
      log: (evt, extra) => logs.push({ evt, ...extra }),
      maxBufferedBytes: 1_000, warnBufferedBytes: 500, closeGraceMs: 5_000,
      setTimer: (fn, ms) => { const t = { fn, ms }; timers.push(t); return t },
      clearTimer: t => { const i = timers.indexOf(t); if (i >= 0) timers.splice(i, 1) },
      ...options,
    })
    return { guard, logs, timers }
  }

  it('forwards normally while the peer drains', () => {
    const ws = fakeWs(0)
    const { guard, logs } = guardFor(ws)
    guard.send('a'); guard.send('b')
    assert.deepEqual(ws.sent, ['a', 'b'])
    assert.equal(ws.closed, null)
    assert.equal(guard.tripped(), false)
    assert.equal(logs.length, 0)
  })

  it('warns once when the send buffer crosses the warning mark but keeps sending', () => {
    const ws = fakeWs(600)
    const { guard, logs } = guardFor(ws)
    guard.send('a'); guard.send('b'); guard.send('c')
    assert.equal(ws.sent.length, 3)
    assert.equal(logs.filter(item => item.evt === 'downlink_backpressure_warning').length, 1)
    assert.equal(logs[0].buffered_bytes, 600)
    assert.equal(guard.tripped(), false)
  })

  it('is a hard cap: the frame that would cross it is never queued (ESS-792)', () => {
    // 900 already buffered + a 200 B frame = 1100 > cap 1000. Checking only
    // the existing backlog would queue this frame and trip on the next one,
    // leaving the buffer above the cap in between.
    const ws = fakeWs(900)
    const { guard, logs } = guardFor(ws)
    guard.send('x'.repeat(200))
    assert.deepEqual(ws.sent, [])
    assert.equal(ws.closed.code, 1013)
    const log = logs.find(item => item.evt === 'downlink_backpressure_disconnect')
    assert.equal(log.buffered_bytes, 900)
    assert.equal(log.projected_bytes, 1_100)
  })

  it('leaves a frame that still fits alone', () => {
    const ws = fakeWs(900)
    const { guard } = guardFor(ws)
    guard.send('x'.repeat(50))
    assert.equal(ws.sent.length, 1)
    assert.equal(ws.closed, null)
    assert.equal(guard.tripped(), false)
  })

  it('disconnects a stalled consumer and drops every later frame', () => {
    const ws = fakeWs(5_000)
    const { guard, logs, timers } = guardFor(ws)
    guard.send('a')
    assert.deepEqual(ws.sent, [], 'the frame that tripped the cap must not be queued')
    assert.equal(ws.closed.code, 1013)
    assert.equal(ws.closed.reason, 'ERR_SLOW_CONSUMER')
    assert.equal(guard.tripped(), true)
    const log = logs.find(item => item.evt === 'downlink_backpressure_disconnect')
    assert.equal(log.code, 'ERR_SLOW_CONSUMER')
    assert.equal(log.buffered_bytes, 5_000)
    assert.equal(log.request_id, 'r-1')

    // A session mid-response keeps emitting until its close callback runs;
    // none of it may reach a socket we already gave up on.
    guard.send('b'); guard.send('c')
    assert.deepEqual(ws.sent, [])
    assert.equal(logs.filter(item => item.evt === 'downlink_backpressure_disconnect').length, 1)

    // close() itself queues behind the backlog — terminate is the fallback.
    assert.equal(timers.length, 1)
    timers[0].fn()
    assert.equal(ws.terminated, true)
  })

  it('cancels the terminate fallback once the socket closes on its own', () => {
    const ws = fakeWs(5_000)
    const { guard, timers } = guardFor(ws)
    guard.send('a')
    assert.equal(timers.length, 1)
    guard.dispose()
    assert.equal(timers.length, 0)
    assert.equal(ws.terminated, false)
  })
})

test('gateway config exposes the downlink limits it enforces', async () => {
  const { readFileSync } = await import('node:fs')
  const config = JSON.parse(readFileSync(new URL('../config.json', import.meta.url), 'utf8'))
  for (const key of [
    'max_downlink_frame_bytes', 'max_downlink_frames', 'max_downlink_bytes',
    'max_downlink_buffered_bytes', 'downlink_backpressure_warn_bytes', 'downlink_close_grace_ms',
  ]) {
    assert.equal(typeof config[key], 'number', `${key} missing from config.json`)
  }
})
