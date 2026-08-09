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
    log = () => {},
  } = {}) {
    this.gatewayUrl = gatewayUrl
    this.connectTimeoutMs = connectTimeoutMs
    this.maxPendingBytes = maxPendingBytes
    this.takeover = takeover
    this.log = log
    this.turns = new Map()
  }

  openTurn({ requestId, sessionId, generation, responseId, onEvent }) {
    // ESS-537: a Watch conversation session may issue a new request before
    // the provider has finished draining the prior response.  The upstream
    // voice service is ownership-oriented, so leaving both sockets alive can
    // deliver a late prior response on the newly-taken-over connection.  At
    // that point this adapter would (incorrectly) stamp those bytes with the
    // new request's responseId.  Enforce one active request per session and
    // cancel/close the old upstream socket before opening the replacement.
    for (const prior of this.turns.values()) {
      if (prior.sessionId === sessionId && prior.requestId !== requestId) {
        prior.supersede?.(requestId)
      }
    }
    const upstreamSessionId = `watch-direct-${sessionId}-${generation}`
    const url = new URL(this.gatewayUrl)
    url.searchParams.set('sessionId', upstreamSessionId)
    const turn = {
      requestId, sessionId, generation, responseId, onEvent,
      ws: null, ready: false, terminal: false, committed: false,
      pending: [], pendingBytes: 0, nextOutputSequence: 0,
      connectTimer: null,
    }
    turn.supersede = nextRequestId => {
      if (turn.terminal) return
      turn.terminal = true
      clearTimeout(turn.connectTimer)
      this.log('upstream_turn_superseded', {
        request_id: requestId, session_id: sessionId, generation,
        superseded_by_request_id: nextRequestId,
      })
      if (turn.ws?.readyState === WebSocket.OPEN) {
        try { turn.ws.send(JSON.stringify({ type: 'response.cancel' })) } catch { /* closing */ }
      }
      try { turn.ws?.close(1000, 'superseded') } catch { /* best effort */ }
      this.turns.delete(requestId)
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
          // ESS-551 A3：显式关闭服务端 VAD——Watch 是唯一断句权威
          // （方案 §2.1 单一 VAD 权威）。不下发此字段则上游默认策略可能
          // 自行 final，出现 Watch 未 commit 却产生回答的双权威事故。
          // 显式 null 而非省略：契约测试断言该 key 必须在场。
          turnDetection: null,
          timeZone: 'Asia/Shanghai', locale: 'zh-CN',
        }))
        this.log('upstream_open_sent', {
          request_id: requestId, session_id: sessionId, generation,
          turn_detection: 'off',
        })
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
          return
        }
        if (event.type === 'audio.done') {
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
