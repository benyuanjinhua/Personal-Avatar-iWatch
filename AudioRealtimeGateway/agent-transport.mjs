// Upstream Agent transport interface. ESS-403 defines the client-facing
// realtime contract and the Gateway framing; wiring to the *real* provider
// (upstream Agent WSS with provider key) belongs to ESS-401 integration.
//
// The interface below is the seam. The default `MockAgentTransport` is what
// the tests and dev servers use — it emits scripted deltas / done frames
// and honours cancel so the whole state machine can be exercised without a
// live provider.

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
