// ESS-265: deterministic media-plane state machine.
// It never buffers a whole utterance or response. Validated input PCM frames are
// forwarded immediately; Agent deltas are emitted immediately to the client.

const OPEN = 'open'
const ENDED = 'ended'
const CANCELLED = 'cancelled'

export class RealtimeMediaSession {
  constructor({
    requestId, sessionId, sendUpstream, sendDownstream,
    maxFrameBytes = 64 * 1024, log = () => {}, onFirstAudio = () => {},
    onResponseComplete = () => {},
  }) {
    if (!requestId || !sessionId) throw new Error('requestId and sessionId are required')
    if (typeof sendUpstream !== 'function' || typeof sendDownstream !== 'function') {
      throw new Error('media transports are required')
    }
    this.requestId = requestId
    this.sessionId = sessionId
    this.sendUpstream = sendUpstream
    this.sendDownstream = sendDownstream
    this.maxFrameBytes = maxFrameBytes
    this.log = log
    this.onFirstAudio = onFirstAudio
    this.onResponseComplete = onResponseComplete
    this.state = OPEN
    this.nextInputSequence = 0
    this.seenOutputSequences = new Map()
    this.playingResponseId = null
    this.inputCommitted = false
    this.assistantTranscript = ''
    this.taskId = null
    this.firstAudioReported = false
  }

  appendInput({ sequence, audio, sampleRate = 16_000, codec = 'pcm_s16le' }) {
    this.#assertOpen()
    if (this.inputCommitted) throw Object.assign(new Error('input already committed'), { code: 'ERR_STREAM_COMMITTED' })
    if (!Number.isInteger(sequence) || sequence !== this.nextInputSequence) {
      throw Object.assign(new Error('input sequence mismatch'), { code: 'ERR_STREAM_SEQUENCE' })
    }
    if (codec !== 'pcm_s16le' || sampleRate !== 16_000) {
      throw Object.assign(new Error('unsupported input format'), { code: 'ERR_STREAM_FORMAT' })
    }
    const bytes = decodeAudio(audio)
    if (bytes.length === 0 || bytes.length > this.maxFrameBytes) {
      throw Object.assign(new Error('invalid frame size'), { code: 'ERR_STREAM_FRAME_SIZE' })
    }
    this.nextInputSequence += 1
    this.sendUpstream({ type: 'audio.append', audio: bytes.toString('base64') })
    this.log({ event: 'stream.input.forwarded', request_id: this.requestId, sequence, bytes: bytes.length })
  }

  endInput() {
    this.#assertOpen()
    if (this.inputCommitted) return false
    this.inputCommitted = true
    this.sendUpstream({ type: 'audio.commit' })
    this.log({ event: 'stream.input.ended', request_id: this.requestId, frames: this.nextInputSequence })
    return true
  }

  handleAgentEvent(event) {
    if (this.state !== OPEN || !event || typeof event.type !== 'string') return false
    if (event.type === 'audio.delta') {
      const bytes = decodeAudio(event.audio)
      if (!bytes.length) return false
      const responseId = event.responseId ?? 'unknown'
      const seen = this.seenOutputSequences.get(responseId) ?? new Set()
      const sequence = Number.isInteger(event.sequence) ? event.sequence : seen.size
      if (seen.has(sequence)) return false
      seen.add(sequence)
      this.seenOutputSequences.set(responseId, seen)
      this.playingResponseId = event.responseId ?? this.playingResponseId
      if (!this.firstAudioReported) {
        this.firstAudioReported = true
        this.onFirstAudio({ responseId: event.responseId ?? null, bytes: bytes.length })
      }
      this.sendDownstream({
        type: 'audio.delta', request_id: this.requestId, session_id: this.sessionId,
        response_id: event.responseId ?? null, sequence, sample_rate: event.sampleRate ?? 24_000,
        codec: 'pcm_s16le', audio: bytes.toString('base64'),
      })
      return true
    }
    if (event.type === 'transcript.final' && event.role === 'assistant') {
      this.assistantTranscript = event.content ?? event.text ?? this.assistantTranscript
    }
    // Some gateway builds skip task.accepted on the Realtime socket and first
    // expose ownership on running/progress/completed. Any task lifecycle event
    // carrying the stable id is sufficient to retain request ownership.
    if (event.type.startsWith('task.') && event.task?.id) {
      this.taskId = String(event.task.id)
      return true
    }
    if (event.type === 'audio.done') {
      const responseId = event.responseId ?? this.playingResponseId ?? 'unknown'
      const seen = this.seenOutputSequences.get(responseId)
      const finalSequence = seen?.size ? Math.max(...seen) : -1
      this.sendDownstream({
        type: 'audio.done', request_id: this.requestId, session_id: this.sessionId,
        response_id: responseId,
        generation: event.turnGeneration ?? event.generation ?? 0,
        final_sequence: finalSequence,
      })
      return true
    }
    if (event.type === 'voice.state' && event.state === 'idle') {
      this.onResponseComplete({
        responseId: event.responseId ?? null,
        assistantTranscript: this.assistantTranscript,
        taskId: this.taskId,
      })
      return true
    }
    if (event.type === 'transcript.delta' || event.type === 'transcript.final'
      || event.type === 'playback.clear'
      || event.type === 'response.interrupted') {
      this.sendDownstream({ ...event, request_id: this.requestId, session_id: this.sessionId })
      return true
    }
    return false
  }

  playbackStarted(responseId) {
    this.#assertOpen()
    if (!responseId) throw new Error('responseId is required')
    this.playingResponseId = responseId
    this.sendUpstream({ type: 'playback.started', responseId })
  }

  playbackEnded(responseId) {
    this.#assertOpen()
    if (!responseId) throw new Error('responseId is required')
    this.sendUpstream({ type: 'playback.ended', responseId })
    if (this.playingResponseId === responseId) this.playingResponseId = null
  }

  bargeIn() {
    this.#assertOpen()
    const responseId = this.playingResponseId
    this.sendUpstream({ type: 'response.cancel', ...(responseId ? { responseId } : {}) })
    this.sendDownstream({
      type: 'playback.clear', request_id: this.requestId, session_id: this.sessionId,
      response_id: responseId,
    })
    this.playingResponseId = null
  }

  close(reason = 'completed') {
    if (this.state !== OPEN) return false
    this.state = reason === 'cancelled' ? CANCELLED : ENDED
    return true
  }

  #assertOpen() {
    if (this.state !== OPEN) throw Object.assign(new Error('stream is not open'), { code: 'ERR_STREAM_CLOSED' })
  }
}

function decodeAudio(value) {
  if (Buffer.isBuffer(value)) return value
  if (typeof value !== 'string') return Buffer.alloc(0)
  if (!value.length || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) return Buffer.alloc(0)
  return Buffer.from(value, 'base64')
}
