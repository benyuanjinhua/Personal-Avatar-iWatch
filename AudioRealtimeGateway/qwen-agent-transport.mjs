import WebSocket from 'ws'
import { randomUUID } from 'node:crypto'

// Adapter from the secure northbound Gateway contract to the already deployed
// qwen-audio-agent realtime WSS. The qwen service owns the provider credential;
// this process only talks to its loopback endpoint, so provider secrets never
// cross this adapter or enter its logs.
export class QwenAgentTransport {
  constructor({
    gatewayUrl = 'ws://127.0.0.1:3101/api/realtime',
    connectTimeoutMs = 10_000,
    maxPendingBytes = 2 * 1024 * 1024,
    takeover = true,
    // ESS-532: grace period to wait for late-arriving deltas after the
    // upstream emits audio.done with zero emitted deltas. The qwen-audio-agent
    // can emit done(final=-1) and then send actual deltas several seconds
    // later (observed in production: 8 s gap, see ESS-532 gateway.log Session 3).
    doneZeroGraceMs = 3_000,
    log = () => {},
  } = {}) {
    this.gatewayUrl = gatewayUrl
    this.connectTimeoutMs = connectTimeoutMs
    this.maxPendingBytes = maxPendingBytes
    this.takeover = takeover
    this.doneZeroGraceMs = doneZeroGraceMs
    this.log = log
    this.turns = new Map()
  }

  openTurn({ requestId, sessionId, generation, responseId, onEvent }) {
    const upstreamSessionId = `watch-direct-${sessionId}-${generation}`
    const url = new URL(this.gatewayUrl)
    url.searchParams.set('sessionId', upstreamSessionId)
    const turn = {
      requestId, sessionId, generation, responseId, onEvent,
      ws: null, ready: false, terminal: false, committed: false,
      pending: [], pendingBytes: 0, nextOutputSequence: 0,
      connectTimer: null,
      // ESS-532: grace timer for late deltas after upstream done
      doneZeroGraceTimer: null,
      doneEmitted: false,
    }
    this.turns.set(requestId, turn)
    this.log('upstream_connecting', { request_id: requestId, session_id: sessionId, generation })

    const fail = (code, detail) => {
      if (turn.terminal) return
      turn.terminal = true
      clearTimeout(turn.connectTimer)
      this.log('upstream_error', {
        request_id: requestId, session_id: sessionId, generation, code,
      })
      onEvent({ type: 'agent.error', response_id: responseId, code, detail, retriable: true })
      try { turn.ws?.close() } catch { /* best effort */ }
      this.turns.delete(requestId)
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
        ws.send(JSON.stringify({
          type: 'connect', clientType: 'cli', clientLabel: 'watch-direct-gateway',
          clientInstanceId: `gateway_${randomUUID()}`, voiceEnabled: true,
          manualTurnDetection: true, takeover: this.takeover,
          timeZone: 'Asia/Shanghai', locale: 'zh-CN',
        }))
      })
      ws.on('message', raw => {
        let event
        try { event = JSON.parse(raw.toString()) } catch { return }
        if (event.type === 'voice.ready') {
          if (turn.terminal || turn.ready) return
          turn.ready = true
          clearTimeout(turn.connectTimer)
          this.log('upstream_ready', { request_id: requestId, session_id: sessionId, generation })
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
          const sequence = Number.isInteger(event.sequence)
            ? event.sequence : turn.nextOutputSequence
          turn.nextOutputSequence = Math.max(turn.nextOutputSequence, sequence + 1)
          this.log('upstream_event_received', {
            request_id: requestId, session_id: sessionId, generation,
            upstream_event_type: 'audio.delta', sequence,
          })
          this.log('upstream_audio_delta', {
            request_id: requestId, session_id: sessionId, generation, sequence,
          })
          onEvent({
            type: 'agent.audio.delta', response_id: responseId, sequence,
            sample_rate: event.sampleRate ?? 24_000, codec: 'pcm_s16le', audio: event.audio,
          })
          // ESS-532: if we had a deferred done (zero-delta done with grace
          // timer pending), a late delta has now arrived — cancel the grace
          // timer so the real done (with the correct final_sequence) takes over.
          if (turn.doneZeroGraceTimer) {
            clearTimeout(turn.doneZeroGraceTimer)
            turn.doneZeroGraceTimer = null
            this.log('done_zero_grace_cancelled', {
              request_id: requestId, session_id: sessionId, generation,
              detail: 'late delta arrived, will use real done for final_sequence',
            })
          }
          return
        }
        if (event.type === 'audio.done') {
          // ESS-532: if the upstream has not emitted any deltas yet
          // (nextOutputSequence === 0), this is a zero-audio done. The
          // qwen-audio-agent can emit done before its deltas arrive —
          // observed in production with an 8 s gap (ESS-532 Session 3).
          // Defer the done emission for a short grace window; if a delta
          // arrives, we cancel the grace timer and let the real audio flow
          // produce the real done with the correct final_sequence.
          if (turn.nextOutputSequence === 0 && !turn.doneZeroGraceTimer) {
            this.log('done_zero_grace_started', {
              request_id: requestId, session_id: sessionId, generation,
              grace_ms: this.doneZeroGraceMs,
            })
            turn.doneZeroGraceTimer = setTimeout(() => {
              turn.doneZeroGraceTimer = null
              if (turn.doneEmitted) return
              turn.doneEmitted = true
              this.log('done_zero_grace_expired', {
                request_id: requestId, session_id: sessionId, generation,
                final_sequence: -1,
              })
              onEvent({
                type: 'agent.audio.done', response_id: responseId,
                final_sequence: -1,
              })
            }, this.doneZeroGraceMs)
            return
          }
          if (turn.doneEmitted) return
          turn.doneEmitted = true
          if (turn.doneZeroGraceTimer) {
            clearTimeout(turn.doneZeroGraceTimer)
            turn.doneZeroGraceTimer = null
          }
          const finalSequence = turn.nextOutputSequence - 1
          this.log('upstream_event_received', {
            request_id: requestId, session_id: sessionId, generation,
            upstream_event_type: 'audio.done', final_sequence: finalSequence,
          })
          this.log('upstream_audio_done', {
            request_id: requestId, session_id: sessionId, generation,
            final_sequence: finalSequence,
          })
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
        this.turns.delete(requestId)
      },
      close: () => {
        if (turn.terminal) return
        turn.terminal = true
        clearTimeout(turn.connectTimer)
        if (turn.ws?.readyState === WebSocket.OPEN) {
          turn.ws.send(JSON.stringify({ type: 'mute' }))
        }
        turn.ws?.close()
        this.turns.delete(requestId)
      },
    }
  }
}
