import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { allowDownlinkMessage, prepareDownlinkMessage } from '../audio-policy.mjs'

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

  it('requires kind on every audio-producing downlink path', () => {
    const cases = [
      { name: 'interim', event: { type: 'turn.interim', interim: { request_id: 'i1', text: '处理中', audio: { kind: 'interim' } } } },
      { name: 'direct result', event: { type: 'turn.state', turn: { request_id: 'd1', path: 'direct', result: { text: '完成', audio: { kind: 'result' } } } } },
      { name: 'background result', event: { type: 'turn.state', turn: { request_id: 'b1', path: 'background', result: { text: '完成', audio: { kind: 'result' } } } } },
      { name: 'redelivery snapshot', event: { type: 'snapshot', turns: [{ request_id: 'r1', path: 'background', result: { text: '完成', audio: { kind: 'result' } } }] } },
    ]
    for (const { name, event } of cases) {
      assert.equal(allowDownlinkMessage(event, () => {}), true, name)
      const missing = structuredClone(event)
      const audio = missing.interim?.audio ?? missing.turn?.result?.audio ?? missing.turns?.[0]?.result?.audio
      delete audio.kind
      assert.equal(allowDownlinkMessage(missing, () => {}), false, `${name} without kind`)
    }
  })

  it('keeps visible text when audio is rejected', () => {
    const logs = []
    const event = { type: 'turn.interim', interim: {
      request_id: 'r1', text: '收到，正在处理，请稍后', audio: { base64: 'AAAA' },
    } }
    const safe = prepareDownlinkMessage(event, item => logs.push(item))
    assert.equal(safe.interim.text, event.interim.text)
    assert.equal(safe.interim.audio, undefined)
    assert.equal(event.interim.audio.base64, 'AAAA', 'source event must remain intact')
    assert.equal(logs[0].reason, 'missing_kind')
  })

  // ESS-184：门禁探针 kind=probe 必须走白名单（避免自己拦自己，参见
  // ESS-181）。causal 判据（request_id 存在）同其他 kind 一致。
  it('admits probe audio when it carries a causal request_id', () => {
    const logs = []
    const causal = {
      type: 'turn.state',
      turn: {
        request_id: 'probe-0000000000000000',
        path: 'direct',
        result: { audio: { kind: 'probe', sha256: 'p' }, audio_base64: 'AAAA' },
      },
    }
    assert.equal(allowDownlinkMessage(causal, item => logs.push(item)), true)
    assert.deepEqual(logs, [])

    const noCausal = {
      type: 'turn.state',
      turn: {
        path: 'direct',
        result: { audio: { kind: 'probe', sha256: 'p' }, audio_base64: 'AAAA' },
      },
    }
    assert.equal(allowDownlinkMessage(noCausal, item => logs.push(item)), false)
    assert.deepEqual(logs[0], {
      evt: 'l1_audio_rejected', reason: 'missing_causal_request',
      request_id: null, source: 'direct', kind: 'probe',
    })
  })
})
