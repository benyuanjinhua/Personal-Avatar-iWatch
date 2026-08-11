import WebSocket from 'ws'
import { randomUUID } from 'node:crypto'

// ESS-745: `request_id` is client-supplied and only validated as a string
// (token-issuer.mjs `#assertScope`); nothing makes it unique beyond the
// device/session that minted it, and one QwenAgentTransport instance is
// shared by every connection of the process (server.mjs `createAgentTransport`).
// So the active-turn book-keeping must be keyed by the FULL scope, and every
// removal must prove it is removing its own turn instance — otherwise a late
// close from an old socket evicts the turn that replaced it.
const scopeKey = ({ deviceId, sessionId, generation, requestId }) =>
  JSON.stringify([deviceId ?? null, sessionId ?? null, generation ?? null, requestId ?? null])

// Conversation identity for the one-active-turn rule (ESS-537): a turn may only
// supersede another turn of the same device + session, never a same-named
// request that belongs to somebody else.
const conversationKey = ({ deviceId, sessionId }) =>
  JSON.stringify([deviceId ?? null, sessionId ?? null])

// Adapter from the secure northbound Gateway contract to the already deployed
// qwen-audio-agent realtime WSS. The qwen service owns the provider credential;
// this process only talks to its loopback endpoint, so provider secrets never
// cross this adapter or enter its logs.

const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/

export class QwenAgentTransport {
  constructor({
    gatewayUrl = 'ws://127.0.0.1:3101/api/realtime',
    connectTimeoutMs = 10_000,
    maxPendingBytes = 2 * 1024 * 1024,
    // Downlink budget (ESS-746). The upstream is a separate process whose
    // output this adapter cannot trust: an oversized, malformed or endless
    // `audio.delta` stream would otherwise be forwarded verbatim and grow
    // the session's dedup set and the Watch socket's send buffer without
    // bound. Caps are per turn and fail the turn explicitly (retriable) so
    // the client degrades in seconds instead of waiting for the 30 s done
    // barrier to time out.
    maxDownlinkFrameBytes = 128 * 1024,
    maxDownlinkFrames = 4096,
    maxDownlinkBytes = 32 * 1024 * 1024,
    takeover = true,
    log = () => {},
  } = {}) {
    this.gatewayUrl = gatewayUrl
    this.connectTimeoutMs = connectTimeoutMs
    this.maxPendingBytes = maxPendingBytes
    this.maxDownlinkFrameBytes = maxDownlinkFrameBytes
    this.maxDownlinkFrames = maxDownlinkFrames
    this.maxDownlinkBytes = maxDownlinkBytes
    this.takeover = takeover
    this.log = log
    this.turns = new Map()
  }

  // Remove a turn from the active map ONLY if that slot still holds this exact
  // turn instance. A superseded/failed socket can settle long after its
  // replacement was registered; an unconditional delete by key would evict the
  // live turn and leave an orphan upstream socket nobody can cancel.
  #release(turn) {
    if (this.turns.get(turn.key) === turn) this.turns.delete(turn.key)
  }

  // A turn is current only while it is both non-terminal and still the
  // registered instance for its scope key.
  #isCurrent(turn) {
    return !turn.terminal && this.turns.get(turn.key) === turn
  }

  openTurn({ requestId, sessionId, deviceId = null, generation, responseId, onEvent }) {
    const key = scopeKey({ deviceId, sessionId, generation, requestId })
    const conversation = conversationKey({ deviceId, sessionId })
    // ESS-537: a Watch conversation session may issue a new request before
    // the provider has finished draining the prior response.  The upstream
    // voice service is ownership-oriented, so leaving both sockets alive can
    // deliver a late prior response on the newly-taken-over connection.  At
    // that point this adapter would (incorrectly) stamp those bytes with the
    // new request's responseId.  Enforce one active request per session and
    // cancel/close the old upstream socket before opening the replacement.
    //
    // ESS-745: match on the conversation (device + session), not on session
    // alone, and supersede every prior turn of that conversation — including
    // one that reuses the same requestId with a new generation, which the old
    // `prior.requestId !== requestId` guard let survive as an orphan.  The new
    // turn is not in the map yet, so nothing here can supersede itself.
    for (const prior of this.turns.values()) {
      if (prior.conversation === conversation) prior.supersede?.(requestId)
    }
    const upstreamSessionId = `watch-direct-${sessionId}-${generation}`
    const url = new URL(this.gatewayUrl)
    url.searchParams.set('sessionId', upstreamSessionId)
    const turn = {
      key, conversation,
      requestId, sessionId, deviceId, generation, responseId, onEvent,
      ws: null, ready: false, terminal: false, committed: false,
      pending: [], pendingBytes: 0, nextOutputSequence: 0,
      downlinkFrames: 0, downlinkBytes: 0,
      connectTimer: null,
    }
    const scopeLog = { request_id: requestId, session_id: sessionId, device_id: deviceId, generation }
    turn.supersede = nextRequestId => {
      if (turn.terminal) return
      turn.terminal = true
      clearTimeout(turn.connectTimer)
      this.log('upstream_turn_superseded', {
        ...scopeLog, superseded_by_request_id: nextRequestId,
      })
      if (turn.ws?.readyState === WebSocket.OPEN) {
        try { turn.ws.send(JSON.stringify({ type: 'response.cancel' })) } catch { /* closing */ }
      }
      try { turn.ws?.close(1000, 'superseded') } catch { /* best effort */ }
      this.#release(turn)
    }
    this.turns.set(key, turn)
    this.log('upstream_connecting', scopeLog)

    const fail = (code, detail) => {
      if (turn.terminal) return
      turn.terminal = true
      clearTimeout(turn.connectTimer)
      this.log('upstream_error', { ...scopeLog, code })
      onEvent({ type: 'agent.error', response_id: responseId, code, detail, retriable: true })
      try { turn.ws?.close() } catch { /* best effort */ }
      this.#release(turn)
    }

    // A frame the upstream should never have sent. Log the rejection with the
    // measured size so the cap can be re-tuned from evidence, then fail the
    // turn — dropping it silently would leave a hole the downstream done
    // barrier can only resolve by timing out.
    const rejectFrame = (code, detail, extra) => {
      if (turn.terminal) return
      this.log('upstream_frame_rejected', {
        request_id: requestId, session_id: sessionId, generation, code, ...extra,
      })
      fail(code, detail)
    }

    const sendOrQueue = (event, bytes = 0) => {
      if (turn.terminal) return
      if (turn.ready && turn.ws?.readyState === WebSocket.OPEN) {
        turn.ws.send(JSON.stringify(event))
        return
      }
      if (turn.pendingBytes + bytes > this.maxPendingBytes) {
        fail('ERR_UPSTREAM_BUFFER_LIMIT', 'upstream was not ready before the audio buffer filled')
        return
      }
      turn.pending.push(event)
      turn.pendingBytes += bytes
    }

    try {
      const ws = new WebSocket(url)
      turn.ws = ws
      turn.connectTimer = setTimeout(() => {
        fail('ERR_UPSTREAM_TIMEOUT', `upstream connect exceeded ${this.connectTimeoutMs}ms`)
      }, this.connectTimeoutMs)
      turn.connectTimer.unref?.()

      ws.on('open', () => {
        // The turn can be superseded/cancelled while the handshake is still in
        // flight; do not announce a connection nobody owns any more.
        if (!this.#isCurrent(turn)) {
          try { ws.close(1000, 'superseded') } catch { /* best effort */ }
          return
        }
        ws.send(JSON.stringify({
          type: 'connect', clientType: 'cli', clientLabel: 'watch-direct-gateway',
          clientInstanceId: `gateway_${randomUUID()}`, voiceEnabled: true,
          manualTurnDetection: true, takeover: this.takeover,
          timeZone: 'Asia/Shanghai', locale: 'zh-CN',
        }))
      })
      ws.on('message', raw => {
        // Every frame is validated against THIS turn instance before it can
        // touch downstream state: a superseded socket may still be draining
        // the provider's prior response, and forwarding it would stamp those
        // bytes with a scope that no longer owns the conversation (ESS-745).
        if (!this.#isCurrent(turn)) return
        let event
        try { event = JSON.parse(raw.toString()) } catch { return }
        if (event.type === 'voice.ready') {
          if (turn.ready) return
          turn.ready = true
          clearTimeout(turn.connectTimer)
          this.log('upstream_ready', scopeLog)
          for (const queued of turn.pending) ws.send(JSON.stringify(queued))
          turn.pending = []
          turn.pendingBytes = 0
          return
        }
        if (event.type === 'voice.ownership' && event.state === 'busy' && !turn.ready) {
          fail('ERR_VOICE_BUSY', 'upstream voice ownership is busy')
          return
        }
        if (event.type === 'audio.delta' && event.audio) {
          const audio = event.audio
          if (typeof audio !== 'string' || audio.length % 4 !== 0 || !BASE64.test(audio)) {
            rejectFrame('ERR_UPSTREAM_FRAME_INVALID', 'audio payload is not base64', {
              audio_type: typeof audio,
              audio_length: typeof audio === 'string' ? audio.length : null,
            })
            return
          }
          if (audio.length > this.maxDownlinkFrameBytes) {
            rejectFrame('ERR_UPSTREAM_FRAME_SIZE', 'upstream audio frame exceeds the downlink frame cap', {
              audio_length: audio.length, cap: this.maxDownlinkFrameBytes,
            })
            return
          }
          turn.downlinkFrames += 1
          turn.downlinkBytes += audio.length
          if (turn.downlinkFrames > this.maxDownlinkFrames
            || turn.downlinkBytes > this.maxDownlinkBytes) {
            rejectFrame('ERR_UPSTREAM_BUDGET_EXCEEDED', 'upstream exceeded the per-turn downlink budget', {
              frames: turn.downlinkFrames, frames_cap: this.maxDownlinkFrames,
              bytes: turn.downlinkBytes, bytes_cap: this.maxDownlinkBytes,
            })
            return
          }
          const sequence = Number.isInteger(event.sequence) && event.sequence >= 0
            ? event.sequence : turn.nextOutputSequence
          turn.nextOutputSequence = Math.max(turn.nextOutputSequence, sequence + 1)
          this.log('upstream_event_received', {
            ...scopeLog, upstream_event_type: 'audio.delta', sequence,
          })
          this.log('upstream_audio_delta', { ...scopeLog, sequence })
          onEvent({
            type: 'agent.audio.delta', response_id: responseId, sequence,
            sample_rate: event.sampleRate ?? 24_000, codec: 'pcm_s16le', audio: event.audio,
          })
          return
        }
        if (event.type === 'audio.done') {
          const finalSequence = turn.nextOutputSequence - 1
          this.log('upstream_event_received', {
            ...scopeLog, upstream_event_type: 'audio.done', final_sequence: finalSequence,
          })
          this.log('upstream_audio_done', { ...scopeLog, final_sequence: finalSequence })
          onEvent({
            type: 'agent.audio.done', response_id: responseId,
            final_sequence: finalSequence,
          })
          return
        }
        if (event.type === 'error' || event.type === 'session.error' || event.type === 'voice.error') {
          fail(event.code ?? 'ERR_UPSTREAM_UNAVAILABLE', event.message ?? event.detail ?? 'upstream error')
        }
      })
      ws.on('error', error => fail('ERR_UPSTREAM_UNAVAILABLE', error.message))
      ws.on('close', (code, reason) => {
        if (!turn.terminal) fail('ERR_UPSTREAM_DISCONNECTED', `code=${code} reason=${String(reason)}`)
      })
    } catch (error) {
      fail('ERR_UPSTREAM_UNAVAILABLE', error.message)
    }

    return {
      appendAudio: ({ bytes }) => sendOrQueue({
        type: 'audio.append', audio: bytes.toString('base64'),
      }, bytes.length),
      commit: () => {
        if (turn.committed || turn.terminal) return
        turn.committed = true
        sendOrQueue({ type: 'audio.commit' })
      },
      cancel: () => {
        if (turn.terminal) return
        if (turn.ws?.readyState === WebSocket.OPEN) {
          turn.ws.send(JSON.stringify({ type: 'response.cancel' }))
        }
        turn.terminal = true
        clearTimeout(turn.connectTimer)
        turn.ws?.close()
        this.#release(turn)
      },
      close: () => {
        if (turn.terminal) return
        turn.terminal = true
        clearTimeout(turn.connectTimer)
        if (turn.ws?.readyState === WebSocket.OPEN) {
          turn.ws.send(JSON.stringify({ type: 'mute' }))
        }
        turn.ws?.close()
        this.#release(turn)
      },
    }
  }
}
