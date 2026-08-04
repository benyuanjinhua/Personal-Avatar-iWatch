import { createHash } from 'node:crypto'

export const VOICE_STREAM_PROTOCOL_VERSION = 2

const digest = payload => createHash('sha256').update(payload).digest('hex')
const uuid = value => typeof value === 'string'
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)

export class VoiceStreamUplink {
  constructor({
    enabled = false,
    maxPayloadBytes = 64 * 1024,
    maxBufferedBytes = 256 * 1024,
    maxSequenceWindow = 32,
    onChunk = () => {},
    onComplete = () => {},
    log = () => {},
  } = {}) {
    this.enabled = enabled === true
    this.maxPayloadBytes = maxPayloadBytes
    this.maxBufferedBytes = maxBufferedBytes
    this.maxSequenceWindow = maxSequenceWindow
    this.onChunk = onChunk
    this.onComplete = onComplete
    this.log = log
    this.streams = new Map()
    this.fallbacks = new Set()
  }

  ingest(chunk) {
    if (!this.enabled) return { status: 'disabled', fallback: true }
    const invalid = this.validate(chunk)
    if (invalid) return this.fallback(chunk?.request_id, invalid)
    if (this.fallbacks.has(chunk.request_id)) return { status: 'already_fell_back' }

    let stream = this.streams.get(chunk.request_id)
    if (!stream) {
      if (chunk.sequence !== 0) return this.fallback(chunk.request_id, 'first_chunk_missing')
      stream = { streamId: chunk.stream_id, nextSequence: 0, pending: new Map(), bufferedBytes: 0, ended: false }
      this.streams.set(chunk.request_id, stream)
    }
    if (stream.streamId !== chunk.stream_id || stream.ended) {
      return this.fallback(chunk.request_id, 'stream_identity_mismatch')
    }
    if (chunk.sequence < stream.nextSequence || stream.pending.has(chunk.sequence)) return { status: 'duplicate' }
    if (chunk.sequence - stream.nextSequence > this.maxSequenceWindow) {
      return this.fallback(chunk.request_id, 'sequence_window_exceeded')
    }
    const payload = Buffer.from(chunk.payload, 'base64')
    if (stream.bufferedBytes + payload.length > this.maxBufferedBytes) {
      return this.fallback(chunk.request_id, 'backpressure')
    }
    stream.pending.set(chunk.sequence, { chunk, payload })
    stream.bufferedBytes += payload.length
    const ready = []
    while (stream.pending.has(stream.nextSequence)) {
      const item = stream.pending.get(stream.nextSequence)
      stream.pending.delete(stream.nextSequence)
      stream.bufferedBytes -= item.payload.length
      ready.push(item)
      stream.nextSequence += 1
    }
    for (const item of ready) {
      if (item.payload.length) this.onChunk({ requestId: chunk.request_id, payload: item.payload, chunk: item.chunk })
      if (item.chunk.end_of_stream) {
        if (stream.pending.size) return this.fallback(chunk.request_id, 'stream_ended_with_gap')
        stream.ended = true
        this.streams.delete(chunk.request_id)
        this.onComplete({ requestId: chunk.request_id, streamId: chunk.stream_id })
        this.log({ evt: 'voice_uplink_stream_ended', request_id: chunk.request_id, chunks: stream.nextSequence })
      }
    }
    return { status: stream.ended ? 'ended' : ready.length ? 'accepted' : 'buffered', accepted: ready.length }
  }

  validate(chunk) {
    if (!chunk || chunk.protocol_version !== VOICE_STREAM_PROTOCOL_VERSION) return 'invalid_protocol_version'
    if (!uuid(chunk.request_id) || !uuid(chunk.stream_id)) return 'invalid_stream_identity'
    if (chunk.direction !== 'uplink') return 'invalid_direction'
    if (!Number.isInteger(chunk.sequence) || chunk.sequence < 0) return 'invalid_sequence'
    if (typeof chunk.end_of_stream !== 'boolean') return 'invalid_end_of_stream'
    if (chunk.codec !== 'aac_lc' || chunk.sample_rate !== 16_000) return 'invalid_format'
    if (typeof chunk.payload !== 'string' || typeof chunk.payload_sha256 !== 'string') return 'invalid_payload'
    const payload = Buffer.from(chunk.payload, 'base64')
    if ((!payload.length && !chunk.end_of_stream) || payload.length > this.maxPayloadBytes) return 'invalid_payload'
    if (digest(payload) !== chunk.payload_sha256.toLowerCase()) return 'digest_mismatch'
    return null
  }

  disconnect(requestId) {
    if (!this.streams.has(requestId)) return { status: 'missing' }
    return this.fallback(requestId, 'stream_disconnected')
  }

  fallback(requestId, reason) {
    if (!uuid(requestId)) return { status: 'rejected', reason }
    if (this.fallbacks.has(requestId)) return { status: 'already_fell_back' }
    this.streams.delete(requestId)
    this.fallbacks.add(requestId)
    this.log({ evt: 'voice_uplink_stream_fallback', request_id: requestId, reason, retry: 1 })
    return { status: 'fallback', reason, retry: 1 }
  }
}
