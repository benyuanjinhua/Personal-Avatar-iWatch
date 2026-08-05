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

  it('audio.done arriving with a bogus final_sequence uses the actual high-watermark', () => {
    const { session, sent, agent, scope, logs } = harness()
    start(session, scope)
    for (const seq of [0, 1]) {
      agent.emit(scope.request_id, {
        type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: seq, audio: b64('x'),
      })
    }
    // Upstream lies: final_sequence=5 but we only saw 0,1.
    agent.emit(scope.request_id, {
      type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 5,
    })
    const done = sent.find(e => e.type === 'audio.done')
    assert.equal(done.final_sequence, 1, 'client is told the real barrier so it can finish')
    assert.ok(logs.some(l => l.evt === 'done_deferred_awaiting_deltas'))
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
