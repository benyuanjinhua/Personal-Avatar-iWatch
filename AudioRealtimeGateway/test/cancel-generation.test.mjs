// Unit tests for server-authoritative cancel + generation isolation
// (ESS-403 acceptance #3). Cancel must stop the current generation's
// downlink immediately, ack the client, and drop any late frames the
// upstream still emits.

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'

function b64(str) { return Buffer.from(str, 'utf8').toString('base64') }

function harness() {
  const sent = []
  const logs = []
  const closes = []
  const agent = new ScriptedAgentTransport()
  const scope = { device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-1', generation: 2 }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: (code, reason) => closes.push({ code, reason }),
    agentTransport: agent,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0,
    idleDisconnectMs: 0,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start', session_id: scope.session_id,
    request_id: scope.request_id, generation: scope.generation, protocol_version: 1,
  }))
  return { session, sent, logs, closes, agent, scope }
}

describe('cancel is server-authoritative', () => {
  it('acks and stops emitting deltas immediately after cancel', () => {
    const { session, sent, logs, agent, scope } = harness()
    // One delta already in-flight.
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen2', sequence: 0, audio: b64('x') })
    session.onFrame(JSON.stringify({
      type: 'cancel', session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation, reason: 'user_barge_in',
    }))
    const ack = sent.find(e => e.type === 'cancel.ack')
    assert.ok(ack, 'cancel.ack emitted')
    assert.equal(ack.cancelled_response_id, 'r-1:gen2')
    assert.equal(ack.generation, scope.generation)
    assert.equal(agent.cancels.length, 1, 'agent transport was told to cancel')
    // Any further agent deltas / done must be dropped.
    const beforeCount = sent.filter(e => e.type === 'audio.delta').length
    agent.emit(scope.request_id, { type: 'agent.audio.delta', response_id: 'r-1:gen2', sequence: 1, audio: b64('x') })
    agent.emit(scope.request_id, { type: 'agent.audio.done', response_id: 'r-1:gen2', final_sequence: 1 })
    const afterCount = sent.filter(e => e.type === 'audio.delta').length
    assert.equal(afterCount, beforeCount, 'no new deltas emitted post-cancel')
    assert.equal(sent.filter(e => e.type === 'audio.done').length, 0, 'no done emitted post-cancel')
    assert.ok(logs.some(l => l.evt === 'stale_generation_dropped' && l.reason === 'post_cancel'))
    assert.ok(logs.some(l => l.evt === 'cancel_received' && l.reason === 'user_barge_in'))
    assert.ok(logs.some(l => l.evt === 'cancel_ack_sent'))
  })

  it('is idempotent: a second cancel re-acks without touching the agent', () => {
    const { session, sent, agent, scope } = harness()
    session.onFrame(JSON.stringify({
      type: 'cancel', session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
    }))
    session.onFrame(JSON.stringify({
      type: 'cancel', session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
    }))
    assert.equal(sent.filter(e => e.type === 'cancel.ack').length, 2)
    assert.equal(agent.cancels.length, 1, 'agent transport only cancelled once')
  })

  it('rejects uplink after cancel with ERR_GENERATION_STALE', () => {
    const { session, sent, scope } = harness()
    session.onFrame(JSON.stringify({
      type: 'cancel', session_id: scope.session_id, request_id: scope.request_id, generation: scope.generation,
    }))
    session.onFrame(JSON.stringify({
      type: 'audio.append', session_id: scope.session_id, request_id: scope.request_id,
      generation: scope.generation, sequence: 0, audio: b64('x'),
    }))
    const err = sent.find(e => e.type === 'error')
    assert.equal(err?.code, 'ERR_GENERATION_STALE')
  })

  it('drops upstream deltas tagged with a foreign response_id (stale generation)', () => {
    const { session, sent, logs, agent, scope } = harness()
    // Agent emits a delta belonging to a previous generation (response_id
    // does not match this connection's response_id).
    agent.emit(scope.request_id, {
      type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 5, audio: b64('x'),
    })
    assert.equal(sent.filter(e => e.type === 'audio.delta').length, 0)
    assert.ok(logs.some(l => l.evt === 'stale_generation_dropped' && l.got === 'r-1:gen1'))
  })
})
