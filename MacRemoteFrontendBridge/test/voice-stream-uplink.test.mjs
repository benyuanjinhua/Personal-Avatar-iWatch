import { createHash, randomUUID } from 'node:crypto'
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { VoiceStreamUplink } from '../voice-stream-uplink.mjs'

const sha = b => createHash('sha256').update(b).digest('hex')
const requestId = randomUUID()
const streamId = randomUUID()
const make = (sequence, { bytes = Buffer.from(`chunk-${sequence}`), end = false, ...overrides } = {}) => ({
  protocol_version: 2, request_id: requestId, stream_id: streamId, direction: 'uplink', sequence,
  captured_at_ms: Date.now(), codec: 'aac_lc', sample_rate: 16_000,
  payload: bytes.toString('base64'), payload_sha256: sha(bytes), end_of_stream: end, ...overrides,
})

describe('VoiceStreamUplink', () => {
  it('is default-off and leaves the complete-file path authoritative', () => {
    assert.deepEqual(new VoiceStreamUplink().ingest(make(0)), { status: 'disabled', fallback: true })
  })

  it('delivers the first and continuation chunks before EOS', () => {
    const delivered = []
    const completed = []
    const uplink = new VoiceStreamUplink({ enabled: true, onChunk: x => delivered.push(x.payload), onComplete: x => completed.push(x) })
    assert.equal(uplink.ingest(make(0)).status, 'accepted')
    assert.equal(delivered.length, 1)
    assert.equal(uplink.ingest(make(1)).status, 'accepted')
    assert.equal(delivered.length, 2)
    assert.equal(uplink.ingest(make(2, { bytes: Buffer.alloc(0), end: true })).status, 'ended')
    assert.equal(completed.length, 1)
  })

  it('de-duplicates and rejects out-of-order first chunks fail closed', () => {
    const uplink = new VoiceStreamUplink({ enabled: true })
    assert.equal(uplink.ingest(make(1)).reason, 'first_chunk_missing')
    assert.equal(uplink.ingest(make(0)).status, 'already_fell_back')

    const duplicate = new VoiceStreamUplink({ enabled: true })
    duplicate.ingest(make(0))
    assert.equal(duplicate.ingest(make(0)).status, 'duplicate')
  })

  it('fails closed on every security-critical envelope field', () => {
    for (const mutation of [
      { protocol_version: 1 }, { stream_id: 'bad' }, { sequence: -1 },
      { payload_sha256: '0'.repeat(64) }, { end_of_stream: 'false' },
    ]) {
      const uplink = new VoiceStreamUplink({ enabled: true })
      assert.equal(uplink.ingest(make(0, mutation)).status, 'fallback')
    }
  })

  it('falls back once on backpressure and disconnect', () => {
    const pressure = new VoiceStreamUplink({ enabled: true, maxBufferedBytes: 2 })
    assert.equal(pressure.ingest(make(0)).reason, 'backpressure')
    assert.equal(pressure.ingest(make(0)).status, 'already_fell_back')

    const disconnected = new VoiceStreamUplink({ enabled: true })
    disconnected.ingest(make(0))
    assert.equal(disconnected.disconnect(requestId).retry, 1)
    assert.equal(disconnected.disconnect(requestId).status, 'missing')
  })
})
