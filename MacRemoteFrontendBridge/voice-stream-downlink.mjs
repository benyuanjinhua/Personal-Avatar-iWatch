import { createHash, randomUUID } from 'node:crypto'

export const VOICE_STREAM_PROTOCOL_VERSION = 2
export const VOICE_STREAM_DOWNLINK_CAPABILITY = 'voice_stream_downlink_v2'

const digest = payload => createHash('sha256').update(payload).digest('hex')

export class VoiceStreamingNegotiator {
  constructor({ serverEnabled = false, log = () => {}, setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
    this.serverEnabled = serverEnabled === true
    this.log = log
    this.setTimer = setTimer
    this.clearTimer = clearTimer
    this.turns = new Map()
    this.releaseTimers = new Map()
  }

  negotiate({ requestId, sessionId = null, streaming = null } = {}) {
    const pendingRelease = this.releaseTimers.get(requestId)
    if (pendingRelease) this.clearTimer(pendingRelease)
    this.releaseTimers.delete(requestId)
    const requested = streaming?.requested === true
    const versions = Array.isArray(streaming?.protocol_versions) ? streaming.protocol_versions : []
    const capabilities = Array.isArray(streaming?.capabilities) ? streaming.capabilities : []
    const capable = capabilities.includes(VOICE_STREAM_DOWNLINK_CAPABILITY)
      && versions.includes(VOICE_STREAM_PROTOCOL_VERSION)
    let reason = null
    if (!requested) reason = 'not_requested'
    else if (!this.serverEnabled) reason = 'server_disabled'
    else if (!capabilities.includes(VOICE_STREAM_DOWNLINK_CAPABILITY)) reason = 'capability_missing'
    else if (!versions.includes(VOICE_STREAM_PROTOCOL_VERSION)) reason = 'protocol_version_mismatch'
    const decision = {
      session_id: sessionId,
      request_id: requestId,
      requested,
      capable,
      effective: requested && capable && this.serverEnabled,
      fallback_reason: reason,
      protocol_version: VOICE_STREAM_PROTOCOL_VERSION,
    }
    this.turns.set(requestId, decision)
    this.log({ evt: 'voice_stream_negotiated', ...decision })
    return decision
  }

  decision(requestId) {
    return this.turns.get(requestId) ?? {
      request_id: requestId, requested: false, capable: false, effective: false,
      fallback_reason: 'not_negotiated', protocol_version: VOICE_STREAM_PROTOCOL_VERSION,
    }
  }

  release(requestId) {
    const timer = this.releaseTimers.get(requestId)
    if (timer) this.clearTimer(timer)
    this.releaseTimers.delete(requestId)
    this.turns.delete(requestId)
  }

  releaseAfter(requestId, delayMs) {
    if (!this.turns.has(requestId)) return false
    const previous = this.releaseTimers.get(requestId)
    if (previous) this.clearTimer(previous)
    const timer = this.setTimer(() => {
      this.releaseTimers.delete(requestId)
      this.turns.delete(requestId)
    }, delayMs)
    timer?.unref?.()
    this.releaseTimers.set(requestId, timer)
    return true
  }
}

// Bridge-side projection of the ESS-249 L1 state machine. The reliable m4a
// result remains independent of this best-effort path and is never suppressed.
export class VoiceStreamDownlink {
  constructor({
    enabled = false,
    maxPayloadBytes = 64 * 1024,
    maxBufferedBytes = 256 * 1024,
    maxSequenceWindow = 32,
    gapTimeoutMs = 1_500,
    send,
    log = () => {},
    now = () => Date.now(),
    setTimer = setTimeout,
    clearTimer = clearTimeout,
    isAllowed = null,
  } = {}) {
    this.enabled = enabled === true
    this.maxPayloadBytes = maxPayloadBytes
    this.maxBufferedBytes = maxBufferedBytes
    this.maxSequenceWindow = maxSequenceWindow
    this.gapTimeoutMs = gapTimeoutMs
    this.send = send ?? (() => false)
    this.log = log
    this.now = now
    this.setTimer = setTimer
    this.clearTimer = clearTimer
    this.isAllowed = isAllowed
    this.streams = new Map()
  }

  append({ requestId, responseId = null, audio, sampleRate = 24_000, sequence = null }) {
    if (!this.enabled) return { status: 'disabled' }
    const decision = this.isAllowed?.(requestId)
    if (decision && decision.effective !== true) {
      return { status: 'fallback', reason: decision.fallback_reason ?? 'not_negotiated' }
    }
    if (!requestId || !audio) return this.fallback(requestId, 'invalid_chunk')
    const payload = Buffer.isBuffer(audio) ? audio : Buffer.from(audio, 'base64')
    if (!payload.length || payload.length > this.maxPayloadBytes || sampleRate !== 24_000) {
      return this.fallback(requestId, 'invalid_chunk')
    }

    let stream = this.streams.get(requestId)
    if (!stream) {
      stream = {
        requestId, responseId, streamId: randomUUID(), nextSequence: 0,
        pending: new Map(), bufferedBytes: 0, fellBack: false, startedAtMs: this.now(),
        gapTimer: null,
      }
      this.streams.set(requestId, stream)
    }
    if (stream.fellBack) return { status: 'already_fell_back' }
    const seq = sequence ?? stream.nextSequence
    if (!Number.isInteger(seq) || seq < 0) return this.fallback(requestId, 'invalid_chunk')
    if (seq < stream.nextSequence || stream.pending.has(seq)) return { status: 'duplicate' }
    if (seq - stream.nextSequence > this.maxSequenceWindow) return this.fallback(requestId, 'sequence_window_exceeded')
    if (stream.bufferedBytes + payload.length > this.maxBufferedBytes) return this.fallback(requestId, 'backpressure')

    stream.pending.set(seq, { payload, sampleRate })
    stream.bufferedBytes += payload.length
    let sent = 0
    while (stream.pending.has(stream.nextSequence)) {
      const ready = stream.pending.get(stream.nextSequence)
      stream.pending.delete(stream.nextSequence)
      stream.bufferedBytes -= ready.payload.length
      if (!this.emit(stream, ready.payload, ready.sampleRate, false)) {
        return this.fallback(requestId, 'downlink_unavailable')
      }
      stream.nextSequence += 1
      sent += 1
    }
    this.refreshGapTimer(stream)
    return { status: sent ? 'sent' : 'accepted', sent }
  }

  finish(requestId) {
    if (!this.enabled) return { status: 'disabled' }
    const decision = this.isAllowed?.(requestId)
    if (decision && decision.effective !== true) {
      return this.fallback(requestId, decision.fallback_reason ?? 'not_negotiated')
    }
    const stream = this.streams.get(requestId)
    if (!stream) return { status: 'missing' }
    if (stream.fellBack) return { status: 'already_fell_back' }
    if (stream.pending.size) return this.fallback(requestId, 'stream_ended_with_gap')
    this.cancelGapTimer(stream)
    // L1 validator rejects empty payloads, including EOS. A single PCM16
    // silence sample closes the stream without inventing a second wire shape.
    const sent = this.emit(stream, Buffer.alloc(2), 24_000, true)
    if (!sent) return this.fallback(requestId, 'downlink_unavailable')
    this.streams.delete(requestId)
    this.log({ evt: 'voice_stream_ended', request_id: requestId, chunks: stream.nextSequence })
    return { status: 'ended' }
  }

  gapTimedOut(requestId) {
    const stream = this.streams.get(requestId)
    if (stream?.fellBack) return { status: 'already_fell_back' }
    if (!stream || !stream.pending.size) return { status: 'accepted' }
    return this.fallback(requestId, 'gap_timed_out')
  }

  refreshGapTimer(stream) {
    this.cancelGapTimer(stream)
    if (!stream.pending.size || stream.fellBack) return
    stream.gapTimer = this.setTimer(() => {
      stream.gapTimer = null
      this.gapTimedOut(stream.requestId)
    }, this.gapTimeoutMs)
    stream.gapTimer?.unref?.()
  }

  cancelGapTimer(stream) {
    if (!stream?.gapTimer) return
    this.clearTimer(stream.gapTimer)
    stream.gapTimer = null
  }

  fallback(requestId, reason = 'client_requested') {
    if (!requestId) return { status: 'invalid' }
    let stream = this.streams.get(requestId)
    if (!stream) {
      stream = { requestId, fellBack: false, pending: new Map(), bufferedBytes: 0 }
      this.streams.set(requestId, stream)
    }
    if (stream.fellBack) return { status: 'already_fell_back' }
    this.cancelGapTimer(stream)
    stream.fellBack = true
    stream.pending.clear()
    stream.bufferedBytes = 0
    this.log({ evt: 'voice_stream_fallback', request_id: requestId, reason, retry: 1 })
    return { status: 'fallback', reason, retry: 1 }
  }

  emit(stream, payload, sampleRate, endOfStream) {
    const capturedAtMs = this.now()
    const envelope = {
      type: 'voice.stream.chunk',
      chunk: {
        protocol_version: VOICE_STREAM_PROTOCOL_VERSION,
        request_id: stream.requestId,
        stream_id: stream.streamId,
        direction: 'downlink',
        sequence: stream.nextSequence,
        captured_at_ms: capturedAtMs,
        codec: 'pcm_s16le',
        sample_rate: sampleRate,
        payload: payload.toString('base64'),
        payload_sha256: digest(payload),
        end_of_stream: endOfStream,
      },
    }
    const ok = this.send(stream.requestId, envelope) === true
    if (ok && stream.nextSequence === 0 && !endOfStream) {
      this.log({
        evt: 'voice_stream_first_chunk', request_id: stream.requestId,
        response_id: stream.responseId, stream_id: stream.streamId,
        first_chunk_at_ms: capturedAtMs, source: 'bridge_realtime_audio_delta',
      })
    }
    return ok
  }
}
