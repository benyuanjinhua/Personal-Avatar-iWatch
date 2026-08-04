import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { VoiceStreamDownlink } from '../voice-stream-downlink.mjs'

const requestId = 'req_test'
const delta = n => Buffer.from(`delta-${n}`)

function harness(overrides = {}) {
  const messages = []
  const logs = []
  const stream = new VoiceStreamDownlink({
    enabled: true,
    now: () => 1_800_000_000_000,
    send: (_, message) => { messages.push(message); return true },
    log: entry => logs.push(entry),
    ...overrides,
  })
  return { stream, messages, logs }
}

describe('VoiceStreamDownlink', () => {
  it('is default-off and emits nothing', () => {
    const messages = []
    const stream = new VoiceStreamDownlink({ send: (_, m) => { messages.push(m); return true } })
    assert.deepEqual(stream.append({ requestId, audio: delta(0) }), { status: 'disabled' })
    assert.equal(messages.length, 0)
  })

  it('sends the first and subsequent deltas immediately, then EOS', () => {
    const { stream, messages, logs } = harness()
    assert.equal(stream.append({ requestId, responseId: 'resp-1', audio: delta(0) }).status, 'sent')
    assert.equal(stream.append({ requestId, audio: delta(1) }).status, 'sent')
    assert.equal(stream.finish(requestId).status, 'ended')
    assert.deepEqual(messages.map(m => m.chunk.sequence), [0, 1, 2])
    assert.deepEqual(messages.map(m => m.chunk.end_of_stream), [false, false, true])
    assert.equal(messages[0].chunk.payload, delta(0).toString('base64'))
    assert.equal(logs.filter(l => l.evt === 'voice_stream_first_chunk').length, 1)
  })

  it('reorders within the window and de-duplicates', () => {
    const { stream, messages } = harness()
    assert.equal(stream.append({ requestId, sequence: 1, audio: delta(1) }).status, 'accepted')
    assert.equal(stream.append({ requestId, sequence: 1, audio: delta(1) }).status, 'duplicate')
    assert.equal(stream.append({ requestId, sequence: 0, audio: delta(0) }).sent, 2)
    assert.deepEqual(messages.map(m => m.chunk.sequence), [0, 1])
  })

  it('falls back once for gaps, backpressure, interruption, and unavailable downlink', () => {
    const gap = harness({ maxSequenceWindow: 1 })
    assert.equal(gap.stream.append({ requestId, sequence: 2, audio: delta(2) }).status, 'fallback')
    assert.equal(gap.stream.append({ requestId, audio: delta(0) }).status, 'already_fell_back')

    const pressure = harness({ maxBufferedBytes: 2 })
    assert.equal(pressure.stream.append({ requestId, sequence: 1, audio: delta(1) }).reason, 'backpressure')

    const interrupted = harness()
    interrupted.stream.append({ requestId, sequence: 1, audio: delta(1) })
    assert.equal(interrupted.stream.finish(requestId).reason, 'stream_ended_with_gap')
    assert.equal(interrupted.logs.filter(l => l.evt === 'voice_stream_fallback').length, 1)

    const unavailable = harness({ send: () => false })
    assert.equal(unavailable.stream.append({ requestId, audio: delta(0) }).reason, 'downlink_unavailable')
  })

  it('accepts explicit client-requested per-turn fallback only once', () => {
    const { stream, logs } = harness()
    assert.equal(stream.fallback(requestId).retry, 1)
    assert.equal(stream.fallback(requestId).status, 'already_fell_back')
    assert.equal(logs.length, 1)
  })
})
