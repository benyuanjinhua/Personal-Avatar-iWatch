// Structured log tests (ESS-403 acceptance #4 + #5): logs let a reviewer
// locate every stage of a turn by request_id / session_id, and secret
// material (tokens, provider keys, signatures) never appears in the output.

import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { createLogger, _redactForTest } from '../logging.mjs'
import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'
import { TokenIssuer } from '../token-issuer.mjs'

function b64(str) { return Buffer.from(str, 'utf8').toString('base64') }

describe('logger', () => {
  it('redacts secret fields recursively', () => {
    const cleaned = _redactForTest({
      request_id: 'r-1', token: 'rtk_secret',
      nested: { signature: 'deadbeef', ok: true, audio: 'AAAA' },
      list: [{ authorization: 'Bearer x', value: 1 }],
    })
    assert.deepEqual(cleaned, {
      request_id: 'r-1',
      nested: { ok: true },
      list: [{ value: 1 }],
    })
  })

  it('emits one JSON object per line with ts + evt', () => {
    const lines = []
    const log = createLogger({ write: line => lines.push(line), now: () => '2026-08-05T00:00:00Z' })
    log('token_issued', { request_id: 'r-1', jti: 'abcdef01' })
    assert.equal(lines.length, 1)
    const obj = JSON.parse(lines[0])
    assert.equal(obj.ts, '2026-08-05T00:00:00Z')
    assert.equal(obj.evt, 'token_issued')
    assert.equal(obj.request_id, 'r-1')
    assert.equal(obj.jti, 'abcdef01')
  })

  it('drops secret values before write', () => {
    const lines = []
    const log = createLogger({ write: line => lines.push(line), now: () => 't' })
    log('token_issued', { token: 'rtk_XXXX', provider_key: 'sk-live', request_id: 'r-1' })
    const obj = JSON.parse(lines[0])
    assert.ok(!('token' in obj))
    assert.ok(!('provider_key' in obj))
    assert.equal(obj.request_id, 'r-1')
  })
})

describe('turn reconstruction', () => {
  it('a happy-path turn produces every named stage keyed on request_id', () => {
    const records = []
    const log = (evt, extra = {}) => records.push({ evt, ...extra })
    const issuer = new TokenIssuer({ log, now: () => 1_000_000 })
    const issued = issuer.issue({
      protocol_version: 1, device_id: 'jackson-iphone',
      session_id: 's-1', request_id: 'r-1', generation: 1, ttl_ms: 30_000,
    }, { authDeviceId: 'jackson-iphone' })
    issuer.consume(issued.token, issued.scope)

    const agent = new ScriptedAgentTransport()
    const session = new RealtimeSession({
      scope: issued.scope,
      send: () => {},
      close: () => {},
      agentTransport: agent,
      log,
      heartbeatIntervalMs: 0,
      idleDisconnectMs: 0,
    })
    session.onFrame(JSON.stringify({
      type: 'session.start', session_id: 's-1', request_id: 'r-1', generation: 1, protocol_version: 1,
    }))
    session.onFrame(JSON.stringify({
      type: 'audio.append', session_id: 's-1', request_id: 'r-1', generation: 1, sequence: 0, audio: b64('hello'),
    }))
    session.onFrame(JSON.stringify({
      type: 'audio.commit', session_id: 's-1', request_id: 'r-1', generation: 1, sequence: 0,
    }))
    agent.emit('r-1', { type: 'agent.audio.delta', response_id: 'r-1:gen1', sequence: 0, audio: b64('reply') })
    agent.emit('r-1', { type: 'agent.audio.done', response_id: 'r-1:gen1', final_sequence: 0 })
    session.onSocketClose(1000, 'completed')

    const named = records.map(r => r.evt)
    for (const expected of [
      'token_issued', 'token_consumed',
      'session_ready', 'uplink_first_frame', 'uplink_committed',
      'downlink_first_frame', 'downlink_done', 'session_ended',
    ]) {
      assert.ok(named.includes(expected), `expected event ${expected}, saw: ${named.join(', ')}`)
    }
    // All non-token records tagged with request_id or session_id so a single
    // grep reconstructs the turn.
    for (const rec of records) {
      if (['token_issued', 'token_consumed'].includes(rec.evt)) continue
      assert.equal(rec.request_id, 'r-1', `evt ${rec.evt} missing request_id`)
      assert.equal(rec.session_id, 's-1', `evt ${rec.evt} missing session_id`)
    }
    // No log record leaks the raw token or provider key.
    const serialised = JSON.stringify(records)
    assert.ok(!serialised.includes(issued.token), 'raw token must not appear in any log')
  })
})
