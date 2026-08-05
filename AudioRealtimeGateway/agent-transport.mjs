// Upstream Agent transport interface. ESS-403 defines the client-facing
// realtime contract and the Gateway framing; wiring to the *real* provider
// (upstream Agent WSS with provider key) belongs to ESS-401 integration.
//
// The interface below is the seam. The default `MockAgentTransport` is what
// the tests and dev servers use — it emits scripted deltas / done frames
// and honours cancel so the whole state machine can be exercised without a
// live provider.

import WebSocket from 'ws'

export class MockAgentTransport {
  constructor({ log = () => {} } = {}) {
    this.log = log
    this.sessions = new Map()
  }

  // openTurn returns a handle the RealtimeSession can push audio.append /
  // audio.commit / cancel into, and whose `onEvent` fires for each
  // Agent-produced frame (delta / done / error).
  openTurn({ requestId, sessionId, generation, responseId, onEvent }) {
    const handle = {
      requestId, sessionId, generation, responseId,
      cancelled: false, committed: false, scriptTimer: null,
      onEvent,
    }
    this.sessions.set(requestId, handle)
    return {
      appendAudio: () => { /* noop for mock */ },
      commit: () => {
        if (handle.committed || handle.cancelled) return
        handle.committed = true
        // Emit a scripted response: 3 deltas + done. Real Agent produces
        // this on its own timeline; the mock uses setImmediate so the state
        // machine sees interleaved async events.
        let seq = 0
        const emit = () => {
          if (handle.cancelled) return
          if (seq < 3) {
            handle.onEvent({
              type: 'agent.audio.delta',
              response_id: responseId, sequence: seq,
              sample_rate: 24_000, codec: 'pcm_s16le',
              audio: Buffer.from([seq, seq, seq, seq]).toString('base64'),
            })
            seq += 1
            handle.scriptTimer = setImmediate(emit)
          } else {
            handle.onEvent({
              type: 'agent.audio.done', response_id: responseId, final_sequence: 2,
            })
          }
        }
        handle.scriptTimer = setImmediate(emit)
      },
      cancel: () => {
        handle.cancelled = true
        if (handle.scriptTimer) clearImmediate(handle.scriptTimer)
      },
      close: () => {
        handle.cancelled = true
        if (handle.scriptTimer) clearImmediate(handle.scriptTimer)
        this.sessions.delete(requestId)
      },
    }
  }
}

// ScriptedAgentTransport lets tests choreograph specific event sequences
// (out-of-order, duplicates, done-before-delta, late-arriving stale-generation
// frames) without racing setImmediate. Each turn buffers an event script and
// releases it via `flush()` or by hooking `onCommit`.
export class ScriptedAgentTransport {
  constructor({ log = () => {} } = {}) {
    this.log = log
    this.handles = new Map()   // requestId → handle
    this.commits = []          // recorded commit calls (for assertions)
    this.appends = []          // recorded append calls
    this.cancels = []          // recorded cancels
  }

  openTurn({ requestId, sessionId, generation, responseId, onEvent }) {
    const handle = {
      requestId, sessionId, generation, responseId, onEvent,
      script: [], committed: false, cancelled: false,
    }
    this.handles.set(requestId, handle)
    return {
      appendAudio: frame => { this.appends.push({ requestId, sequence: frame.sequence, bytes: frame.bytes }) },
      commit: () => {
        if (handle.cancelled) return
        handle.committed = true
        this.commits.push({ requestId, generation })
      },
      cancel: () => {
        handle.cancelled = true
        this.cancels.push({ requestId, generation })
      },
      close: () => { handle.cancelled = true; this.handles.delete(requestId) },
    }
  }

  // Emit a scripted event from the "Agent" side. Returns whether the
  // handle exists (some tests deliberately emit into a closed handle to
  // verify stale-generation drop counts).
  emit(requestId, event) {
    const handle = this.handles.get(requestId)
    if (!handle) return false
    handle.onEvent(event)
    return true
  }

  handle(requestId) { return this.handles.get(requestId) }
}

// Production adapter for DashScope's Qwen-Audio Realtime WebSocket API.
// One provider socket is created per client turn, which keeps cancellation
// and request_id ownership unambiguous. Audio received before the provider
// handshake completes is queued in memory and flushed in order after
// session.updated.
export class QwenAgentTransport {
  constructor({ providerKey, url, model = 'qwen-audio-3.0-realtime-plus',
    voice = 'longanqian', instructions, log = () => {}, WebSocketImpl = WebSocket } = {}) {
    if (!providerKey) throw new Error('provider key is required')
    this.providerKey = providerKey
    this.url = withModel(url ?? 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime', model)
    this.voice = voice
    this.instructions = instructions
    this.log = log
    this.WebSocketImpl = WebSocketImpl
  }

  openTurn({ requestId, sessionId, generation, responseId, onEvent }) {
    let state = 'connecting'
    let sequence = 0
    let done = false
    const pending = []
    const ws = new this.WebSocketImpl(this.url, {
      headers: { Authorization: `Bearer ${this.providerKey}` },
    })
    const emitError = (code, detail, retriable = true) => {
      if (done) return
      done = true
      onEvent({ type: 'agent.error', response_id: responseId, code, detail, retriable })
    }
    const send = message => {
      const text = JSON.stringify(message)
      if (state === 'ready') ws.send(text)
      else if (state === 'connecting') pending.push(text)
      else throw new Error('provider websocket is not available')
    }
    const flush = () => {
      state = 'ready'
      for (const text of pending.splice(0)) ws.send(text)
    }

    ws.on('open', () => {
      this.log('agent_upstream_connected', { request_id: requestId, session_id: sessionId, generation })
      ws.send(JSON.stringify({
        type: 'session.update',
        session: {
          modalities: ['text', 'audio'], voice: this.voice,
          input_audio_format: 'pcm', output_audio_format: 'pcm',
          turn_detection: null,
          ...(this.instructions ? { instructions: this.instructions } : {}),
        },
      }))
    })
    ws.on('message', raw => {
      let event
      try { event = JSON.parse(raw.toString('utf8')) }
      catch { return emitError('ERR_UPSTREAM_PROTOCOL', 'provider returned invalid JSON', false) }
      if (event.type === 'session.updated') {
        if (state === 'connecting') flush()
        return
      }
      if (event.type === 'response.audio.delta') {
        const audio = event.delta ?? event.audio
        if (typeof audio !== 'string') return emitError('ERR_UPSTREAM_PROTOCOL', 'audio delta missing payload', false)
        onEvent({ type: 'agent.audio.delta', response_id: responseId, sequence: sequence++,
          sample_rate: 24_000, codec: 'pcm_s16le', audio })
        return
      }
      if (event.type === 'response.audio.done') {
        if (done) return
        done = true
        onEvent({ type: 'agent.audio.done', response_id: responseId, final_sequence: sequence - 1 })
        return
      }
      if (event.type === 'error') {
        const providerCode = event.error?.code ?? event.code ?? 'provider_error'
        const detail = event.error?.message ?? event.message ?? providerCode
        this.log('agent_upstream_error', { request_id: requestId, session_id: sessionId,
          generation, provider_code: String(providerCode).slice(0, 80) })
        emitError('ERR_UPSTREAM_UNAVAILABLE', detail, event.error?.type !== 'invalid_request_error')
      }
    })
    ws.on('error', error => {
      this.log('agent_upstream_error', { request_id: requestId, session_id: sessionId,
        generation, provider_code: error?.code ?? 'websocket_error' })
      emitError('ERR_UPSTREAM_UNAVAILABLE', error?.message ?? 'provider websocket error')
    })
    ws.on('close', (code) => {
      state = 'closed'
      if (!done) emitError('ERR_UPSTREAM_UNAVAILABLE', `provider websocket closed (${code})`)
    })

    return {
      appendAudio: ({ bytes }) => send({ type: 'input_audio_buffer.append', audio: bytes.toString('base64') }),
      commit: () => {
        send({ type: 'input_audio_buffer.commit' })
        send({ type: 'response.create', response: { modalities: ['audio', 'text'] } })
        this.log('agent_upstream_committed', { request_id: requestId, session_id: sessionId, generation })
      },
      cancel: () => {
        if (state === 'ready') ws.send(JSON.stringify({ type: 'response.cancel' }))
        done = true
        ws.close(1000, 'cancelled')
      },
      close: () => { done = true; ws.close(1000, 'client_closed') },
    }
  }
}

function withModel(url, model) {
  const parsed = new URL(url)
  if (!parsed.searchParams.has('model')) parsed.searchParams.set('model', model)
  return parsed.toString()
}
