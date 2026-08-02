import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { allowDownlinkMessage } from '../audio-policy.mjs'

describe('ESS-57 audio downlink allowlist', () => {
  it('rejects injected unknown audio and emits searchable evidence', () => {
    const logs = []
    const event = { type: 'turn.state', turn: {
      request_id: '018f0000-0000-7000-8000-000000000057', path: 'direct',
      result: { audio: { kind: 'unknown', sha256: 'bad' }, audio_base64: 'AAAA' },
    } }
    assert.equal(allowDownlinkMessage(event, item => logs.push(item)), false)
    assert.deepEqual(logs[0], {
      evt: 'l1_audio_rejected', reason: 'unknown_kind',
      request_id: event.turn.request_id, source: 'direct', kind: 'unknown',
    })
  })

  it('allows only causal interim/result audio', () => {
    assert.equal(allowDownlinkMessage({ type: 'turn.interim', interim: {
      request_id: 'r1', audio: { kind: 'interim' },
    } }, () => {}), true)
    assert.equal(allowDownlinkMessage({ type: 'turn.interim', interim: {
      audio: { kind: 'interim' },
    } }, () => {}), false)
  })
})
