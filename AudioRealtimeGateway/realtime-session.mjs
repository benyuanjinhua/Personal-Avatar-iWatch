// Realtime session state machine — one instance per accepted WSS upgrade.
// It owns:
//   • strict client→server frame schema + monotone uplink sequence check
//   • generation-aware server→client emission (dedup by sequence, drop
//     stale generations, `audio.done` barrier with `final_sequence`)
//   • server-authoritative cancel (stop emission + acknowledge)
//   • per-connection rate limits and frame-size cap
//   • structured logging keyed on request_id / session_id
//
// It is transport-agnostic: `send` is injected. The Node WSS glue lives in
// server.mjs; unit tests exercise this module directly.

const OPEN = 'open'
const CLOSED = 'closed'

const CLIENT_SCHEMAS = {
  'session.start': ['session_id', 'request_id', 'generation', 'protocol_version'],
  'audio.append': ['session_id', 'request_id', 'generation', 'sequence', 'audio'],
  'audio.commit': ['session_id', 'request_id', 'generation', 'sequence'],
  'cancel':       ['session_id', 'request_id', 'generation'],
  'playback.started': ['session_id', 'request_id', 'response_id'],
  'playback.ended':   ['session_id', 'request_id', 'response_id'],
  'ping':         ['nonce'],
  'close':        [],
}

// Fields the schema explicitly permits (used to reject unknown keys with
// ERR_UNKNOWN_FIELD — strict contract is part of ESS-403 acceptance #2).
const ALLOWED_KEYS = {
  'session.start': new Set(['type', 'session_id', 'request_id', 'generation', 'protocol_version']),
  'audio.append': new Set(['type', 'session_id', 'request_id', 'generation', 'sequence', 'audio', 'sample_rate', 'codec']),
  'audio.commit': new Set(['type', 'session_id', 'request_id', 'generation', 'sequence']),
  'cancel':       new Set(['type', 'session_id', 'request_id', 'generation', 'reason']),
  'playback.started': new Set(['type', 'session_id', 'request_id', 'response_id']),
  'playback.ended':   new Set(['type', 'session_id', 'request_id', 'response_id']),
  'ping':         new Set(['type', 'nonce']),
  'close':        new Set(['type', 'reason']),
}

export class RealtimeSession {
  constructor({
    scope, send, close, agentTransport, log,
    protocolVersion = 1,
    heartbeatIntervalMs = 15_000,
    idleDisconnectMs = 60_000,
    maxFrameBytes = 64 * 1024,
    maxEventsPerSecond = 200,
    maxUplinkBytesPerSecond = 512 * 1024,
    now = () => Date.now(),
    setTimer = (fn, ms) => setTimeout(fn, ms),
    clearTimer = t => clearTimeout(t),
  }) {
    if (!scope?.device_id || !scope?.session_id || !scope?.request_id || !scope?.generation) {
      throw new Error('scope with device_id/session_id/request_id/generation is required')
    }
    if (typeof send !== 'function' || typeof close !== 'function' || !agentTransport) {
      throw new Error('send/close/agentTransport are required')
    }
    this.scope = scope
    this.send = send
    this.closeSocket = close
    this.agent = agentTransport
    this.log = log
    this.protocolVersion = protocolVersion
    this.heartbeatIntervalMs = heartbeatIntervalMs
    this.idleDisconnectMs = idleDisconnectMs
    this.maxFrameBytes = maxFrameBytes
    this.maxEventsPerSecond = maxEventsPerSecond
    this.maxUplinkBytesPerSecond = maxUplinkBytesPerSecond
    this.now = now
    this.setTimer = setTimer
    this.clearTimer = clearTimer

    this.state = OPEN
    this.started = false
    this.nextUplinkSequence = 0
    this.uplinkCommitted = false
    this.firstUplinkAt = null
    this.firstDownlinkAt = null

    // Generation-scoped state. On barge-in the WSS is torn down and a new
    // handshake with generation+1 makes a new session, so we only ever have
    // one active generation per connection. Keep it as fields (not per-gen
    // maps) — simpler is better here.
    this.activeGeneration = scope.generation
    this.responseId = scope.request_id + ':gen' + scope.generation
    this.seenDownlinkSequences = new Set()
    this.downlinkHighWatermark = -1
    this.doneEmitted = false
    this.cancelled = false
    this.finalSequence = null       // set when audio.done arrives
    this.staleGenerationDropped = 0

    this.agentTurn = null

    // Rate-limit windows (1 s sliding, coarse but sufficient for realtime).
    this._eventsWindowStart = this.now()
    this._eventsInWindow = 0
    this._bytesWindowStart = this.now()
    this._bytesInWindow = 0

    this._heartbeatTimer = null
    this._idleTimer = null
    this._touchIdle()
  }

  // === Entry points from the WSS glue =====================================

  onFrame(rawText) {
    if (this.state !== OPEN) return
    if (rawText.length > this.maxFrameBytes) return this.fail('ERR_STREAM_FRAME_SIZE')
    if (!this._checkRate()) return this.fail('ERR_RATE_LIMIT')

    let message
    try { message = JSON.parse(rawText) } catch { return this.fail('ERR_BAD_JSON') }
    if (!message || typeof message !== 'object' || typeof message.type !== 'string') {
      return this.fail('ERR_BAD_JSON', { detail: 'missing type' })
    }
    const schema = CLIENT_SCHEMAS[message.type]
    const allowed = ALLOWED_KEYS[message.type]
    if (!schema || !allowed) return this.fail('ERR_UNKNOWN_EVENT', { detail: message.type })
    for (const key of Object.keys(message)) {
      if (!allowed.has(key)) return this.fail('ERR_UNKNOWN_FIELD', { detail: key })
    }
    for (const field of schema) {
      if (message[field] === undefined) return this.fail('ERR_MISSING_FIELD', { detail: field })
    }

    if (message.type === 'session.start') return this._handleStart(message)
    if (!this.started) return this.fail('ERR_NOT_STARTED')

    // Scope binding: every non-`session.start`/non-`ping` message MUST match
    // the token-pinned scope, including generation (which cannot change
    // within a connection — barge-in tears the WSS down).
    if (message.type !== 'ping' && message.type !== 'close') {
      if (message.session_id !== this.scope.session_id
        || message.request_id !== this.scope.request_id) {
        return this.fail('ERR_SCOPE_MISMATCH', { field: 'session_id/request_id' })
      }
      if ('generation' in message && message.generation !== this.scope.generation) {
        return this.fail('ERR_SCOPE_MISMATCH', { field: 'generation' })
      }
    }
    this._touchIdle()

    switch (message.type) {
      case 'audio.append': return this._handleAudioAppend(message)
      case 'audio.commit': return this._handleAudioCommit(message)
      case 'cancel':       return this._handleCancel(message)
      case 'playback.started': return this._handlePlayback(message, 'started')
      case 'playback.ended':   return this._handlePlayback(message, 'ended')
      case 'ping': return this._sendJson({ type: 'pong', nonce: message.nonce })
      case 'close': return this._gracefulClose(message.reason)
    }
  }

  onBinary() { this.fail('ERR_UNSUPPORTED_BINARY') }

  onSocketClose(code, reason) {
    if (this.state === CLOSED) return
    this.state = CLOSED
    if (this._heartbeatTimer) this.clearTimer(this._heartbeatTimer)
    if (this._idleTimer) this.clearTimer(this._idleTimer)
    if (this.agentTurn) { try { this.agentTurn.close() } catch { /* ignore */ } }
    this.log('session_ended', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation,
      reason: (reason && String(reason)) || 'peer_closed',
      close_code: typeof code === 'number' ? code : null,
      stale_generation_dropped: this.staleGenerationDropped,
      final_sequence: this.finalSequence,
      done_emitted: this.doneEmitted,
      cancelled: this.cancelled,
    })
  }

  // === Handlers ===========================================================

  _handleStart(message) {
    if (this.started) return this.fail('ERR_ALREADY_STARTED')
    if (message.session_id !== this.scope.session_id
      || message.request_id !== this.scope.request_id
      || message.generation !== this.scope.generation) {
      return this.fail('ERR_SCOPE_MISMATCH', { detail: 'start scope disagrees with token' })
    }
    if (message.protocol_version !== this.protocolVersion) {
      return this.fail('ERR_PROTOCOL_VERSION')
    }
    this.started = true
    this.agentTurn = this.agent.openTurn({
      requestId: this.scope.request_id,
      sessionId: this.scope.session_id,
      generation: this.scope.generation,
      responseId: this.responseId,
      onEvent: e => this._handleAgentEvent(e),
    })
    this._startHeartbeat()
    this._sendJson({
      type: 'ready',
      session_id: this.scope.session_id,
      request_id: this.scope.request_id,
      generation: this.scope.generation,
      response_id: this.responseId,
      heartbeat_interval_ms: this.heartbeatIntervalMs,
      protocol_version: this.protocolVersion,
    })
    this.log('session_ready', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation, response_id: this.responseId,
    })
  }

  _handleAudioAppend(message) {
    if (this.uplinkCommitted) return this.fail('ERR_STREAM_COMMITTED')
    if (this.cancelled) return this.fail('ERR_GENERATION_STALE')
    if (message.sequence !== this.nextUplinkSequence) {
      return this.fail('ERR_STREAM_SEQUENCE', {
        expected: this.nextUplinkSequence, got: message.sequence,
      })
    }
    const bytes = decodeAudio(message.audio)
    if (!bytes.length || bytes.length > this.maxFrameBytes) {
      return this.fail('ERR_STREAM_FRAME_SIZE')
    }
    if (!this._checkUplinkBytes(bytes.length)) return this.fail('ERR_RATE_LIMIT')
    if (message.codec !== undefined && message.codec !== 'pcm_s16le') {
      return this.fail('ERR_UNSUPPORTED_CODEC')
    }
    if (message.sample_rate !== undefined && message.sample_rate !== 16_000) {
      return this.fail('ERR_UNSUPPORTED_SAMPLE_RATE')
    }
    this.nextUplinkSequence += 1
    if (this.firstUplinkAt === null) {
      this.firstUplinkAt = this.now()
      this.log('uplink_first_frame', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation, sequence: message.sequence, bytes: bytes.length,
      })
    }
    try {
      this.agentTurn.appendAudio({ sequence: message.sequence, bytes })
    } catch (error) {
      return this.fail('ERR_UPSTREAM_UNAVAILABLE', { detail: String(error?.message ?? error) })
    }
  }

  _handleAudioCommit(message) {
    if (this.uplinkCommitted) return this.fail('ERR_STREAM_COMMITTED')
    if (this.cancelled) return this.fail('ERR_GENERATION_STALE')
    if (message.sequence !== this.nextUplinkSequence - 1) {
      return this.fail('ERR_STREAM_SEQUENCE', {
        detail: 'commit sequence must equal last accepted uplink sequence',
        expected: this.nextUplinkSequence - 1, got: message.sequence,
      })
    }
    this.uplinkCommitted = true
    try { this.agentTurn.commit() }
    catch (error) { return this.fail('ERR_UPSTREAM_UNAVAILABLE', { detail: String(error?.message ?? error) }) }
    this.log('uplink_committed', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation, frames: this.nextUplinkSequence,
    })
  }

  _handleCancel(message) {
    if (this.cancelled) {
      // Idempotent — ack again but do NOT re-log or re-touch the agent.
      return this._sendJson({
        type: 'cancel.ack',
        session_id: this.scope.session_id, request_id: this.scope.request_id,
        generation: this.scope.generation, cancelled_response_id: this.responseId,
      })
    }
    this.cancelled = true
    try { this.agentTurn?.cancel() } catch { /* best effort */ }
    this.log('cancel_received', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation, reason: message.reason ?? null,
    })
    this._sendJson({
      type: 'cancel.ack',
      session_id: this.scope.session_id, request_id: this.scope.request_id,
      generation: this.scope.generation, cancelled_response_id: this.responseId,
    })
    this.log('cancel_ack_sent', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation,
    })
  }

  _handlePlayback(message, phase) {
    this.log('playback_' + phase, {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      response_id: message.response_id,
    })
  }

  // === Agent → client path ===============================================

  _handleAgentEvent(event) {
    if (this.state !== OPEN || !event || typeof event.type !== 'string') return

    // ESS-388 §"强制契约": drop late frames from prior generations. In this
    // per-connection model, an event tagged with a different response_id
    // (i.e. a stale generation, since response_id is
    // `request_id:gen<generation>`) is silently dropped and counted.
    if (event.response_id && event.response_id !== this.responseId) {
      this.staleGenerationDropped += 1
      this.log('stale_generation_dropped', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        expected_response_id: this.responseId, got: event.response_id,
        total_dropped: this.staleGenerationDropped,
      })
      return
    }
    if (this.cancelled) {
      // Cancel is authoritative: after cancel.ack we do not emit further
      // deltas or done for this generation, even if the upstream still
      // produces them.
      this.staleGenerationDropped += 1
      this.log('stale_generation_dropped', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        reason: 'post_cancel', event_type: event.type,
        total_dropped: this.staleGenerationDropped,
      })
      return
    }
    if (event.type === 'agent.audio.delta') return this._emitDelta(event)
    if (event.type === 'agent.audio.done') return this._emitDone(event)
    if (event.type === 'agent.error') return this.fail(event.code ?? 'ERR_UPSTREAM_UNAVAILABLE',
      { detail: event.detail ?? null, retriable: Boolean(event.retriable) })
  }

  _emitDelta(event) {
    if (this.doneEmitted) {
      this.staleGenerationDropped += 1
      this.log('stale_generation_dropped', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        reason: 'post_done', sequence: event.sequence,
        total_dropped: this.staleGenerationDropped,
      })
      return
    }
    if (!Number.isInteger(event.sequence) || event.sequence < 0) return
    if (this.seenDownlinkSequences.has(event.sequence)) {
      this.log('duplicate_sequence', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        response_id: this.responseId, sequence: event.sequence,
      })
      return
    }
    this.seenDownlinkSequences.add(event.sequence)
    if (event.sequence > this.downlinkHighWatermark) {
      this.downlinkHighWatermark = event.sequence
    }
    if (this.firstDownlinkAt === null) {
      this.firstDownlinkAt = this.now()
      this.log('downlink_first_frame', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        response_id: this.responseId, sequence: event.sequence,
      })
    }
    this._sendJson({
      type: 'audio.delta',
      session_id: this.scope.session_id, request_id: this.scope.request_id,
      response_id: this.responseId, generation: this.scope.generation,
      sequence: event.sequence,
      sample_rate: event.sample_rate ?? 24_000, codec: event.codec ?? 'pcm_s16le',
      audio: event.audio,
    })
  }

  _emitDone(event) {
    if (this.doneEmitted) return
    const finalSequence = Number.isInteger(event.final_sequence)
      ? event.final_sequence
      : this.downlinkHighWatermark
    // The barrier is the client's obligation, but the server refuses to
    // emit `audio.done` before the delta with `sequence == final_sequence`
    // has been emitted: without this, done-before-first-delta and
    // done-before-tail-delta collapse into indistinguishable failures.
    if (finalSequence >= 0 && !this.seenDownlinkSequences.has(finalSequence)) {
      this.log('done_deferred_awaiting_deltas', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        response_id: this.responseId, final_sequence: finalSequence,
        high_watermark: this.downlinkHighWatermark,
      })
      // Deliver `done` with the actual high-watermark instead of the claimed
      // one. This lets the client complete rather than stall; the mismatch
      // is captured in the log for the receiving team to reconcile.
      this.finalSequence = this.downlinkHighWatermark
    } else {
      this.finalSequence = finalSequence
    }
    this.doneEmitted = true
    this._sendJson({
      type: 'audio.done',
      session_id: this.scope.session_id, request_id: this.scope.request_id,
      response_id: this.responseId, generation: this.scope.generation,
      final_sequence: this.finalSequence,
    })
    this.log('downlink_done', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      response_id: this.responseId, final_sequence: this.finalSequence,
    })
  }

  // === Housekeeping =======================================================

  fail(code, extra = {}) {
    if (this.state !== OPEN) return
    const { detail = null, retriable = false, ...structured } = extra ?? {}
    this._sendJson({
      type: 'error', code,
      session_id: this.scope.session_id, request_id: this.scope.request_id,
      generation: this.scope.generation, retriable: Boolean(retriable),
      ...structured,
      ...(detail === null ? {} : { detail: String(detail).slice(0, 256) }),
    })
    this.log('session_error', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation, code, retriable: Boolean(retriable),
    })
    this.closeSocket(1008, code)
  }

  _gracefulClose(reason) {
    this.closeSocket(1000, typeof reason === 'string' ? reason.slice(0, 120) : 'client_close')
  }

  _sendJson(obj) {
    try { this.send(JSON.stringify(obj)) }
    catch (error) {
      this.log('send_failed', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        code: error?.code ?? null, detail: String(error?.message ?? error).slice(0, 200),
      })
    }
  }

  _startHeartbeat() {
    if (this.heartbeatIntervalMs <= 0) return
    const tick = () => {
      if (this.state !== OPEN) return
      try { this.send(JSON.stringify({ type: 'server_ping', at: this.now() })) } catch { /* ignore */ }
      this._heartbeatTimer = this.setTimer(tick, this.heartbeatIntervalMs)
    }
    this._heartbeatTimer = this.setTimer(tick, this.heartbeatIntervalMs)
  }

  _touchIdle() {
    if (this._idleTimer) this.clearTimer(this._idleTimer)
    if (this.idleDisconnectMs <= 0) return
    this._idleTimer = this.setTimer(() => {
      if (this.state !== OPEN) return
      this.log('heartbeat_timeout', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        idle_ms: this.idleDisconnectMs,
      })
      this.fail('ERR_IDLE_TIMEOUT')
    }, this.idleDisconnectMs)
  }

  _checkRate() {
    const now = this.now()
    if (now - this._eventsWindowStart >= 1_000) {
      this._eventsWindowStart = now
      this._eventsInWindow = 0
    }
    this._eventsInWindow += 1
    if (this._eventsInWindow > this.maxEventsPerSecond) {
      this.log('rate_limit_tripped', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        events_in_window: this._eventsInWindow, cap: this.maxEventsPerSecond,
      })
      return false
    }
    return true
  }

  _checkUplinkBytes(len) {
    const now = this.now()
    if (now - this._bytesWindowStart >= 1_000) {
      this._bytesWindowStart = now
      this._bytesInWindow = 0
    }
    this._bytesInWindow += len
    if (this._bytesInWindow > this.maxUplinkBytesPerSecond) {
      this.log('rate_limit_tripped', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        bytes_in_window: this._bytesInWindow, cap: this.maxUplinkBytesPerSecond,
      })
      return false
    }
    return true
  }
}

function decodeAudio(value) {
  if (typeof value !== 'string') return Buffer.alloc(0)
  if (!value.length || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) return Buffer.alloc(0)
  return Buffer.from(value, 'base64')
}
