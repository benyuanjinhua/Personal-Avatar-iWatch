import WebSocket from 'ws'
import { createHash, randomUUID } from 'node:crypto'

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

// ESS-978: the client-label family every instance of this gateway presents on
// the upstream. A production instance appends its pid (`watch-direct-gateway:
// <pid>`), so two copies on one machine are distinguishable in ownership logs
// and — crucially — never take the single voice slot from each other.
const GATEWAY_LABEL = 'watch-direct-gateway'

// Adapter from the secure northbound Gateway contract to the already deployed
// qwen-audio-agent realtime WSS. The qwen service owns the provider credential;
// this process only talks to its loopback endpoint, so provider secrets never
// cross this adapter or enter its logs.

const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/

// ESS-773: replay identity for an upstream audio frame. Composite on purpose —
// the upstream sequence AND the payload, never the payload alone, since a later
// frame with identical bytes (silence is the common case) is legitimate audio.
// Hashed so an entry costs bytes rather than a frame.
const replayKey = (upstreamSequence, audio) =>
  `audio.delta:${upstreamSequence}:${createHash('sha1').update(audio).digest('base64')}`

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
    // ESS-773: how long `audio.done` waits for a late `audio.delta` before it
    // is forwarded. The provider has been observed emitting done while frames
    // were still in flight; releasing the downstream barrier at that instant
    // discards the tail. Costs at most this much added latency on the last
    // frame, and only when the upstream is well behaved.
    doneSettleMs = 120,
    // ESS-773 replay window. Deliberately short: it may only recognise a
    // near-simultaneous exact replay of a frame the upstream already sent.
    // Outside it, identical audio at the same upstream sequence is treated as
    // legitimate new audio — the provider's counter is not response-scoped, so
    // a restart can legitimately re-present a sequence, and silence repeats
    // constantly. Bounded by TTL and by `maxReplayFingerprints`.
    duplicateWindowMs = 200,
    maxReplayFingerprints = 128,
    // ESS-773 reorder / gap barrier. The upstream sequence still decides the
    // ORDER frames are forwarded in and is what proves the run is complete;
    // only the number handed downstream is reassigned. A hole is held this
    // long, then fails the turn — renumbering past it would present a lossy
    // response to the Watch as a successful one.
    reorderWaitMs = 300,
    maxReorderFrames = 64,
    // ESS-842: how long a committed turn may wait for the upstream to produce
    // ANY part of its response before the turn fails closed. Without it the
    // committed turn has no deadline at all: the upstream discards audio from
    // a non-owner connection silently (ESS-37 §2.1), so a lost-ownership turn
    // sits at `uplink_committed` forever and the client waits on a socket that
    // will never speak.
    //
    // 8 s, NOT the Bridge's 12 s (ESS-37 §3): a deadline is only worth having
    // if the error it produces reaches a client that is still listening, and
    // the only measured client survival window after commit is the incident's
    // 10.153 s (`uplink_committed=12:21:03.156` → `peer_closed=12:21:13.309`).
    // 8 s + delivery margin fits inside it; 12 s does not.
    //
    // That argument only bounds the deadline from ABOVE. The lower bound is
    // measured too (PR #325): window = the 2026-08-10 / -11 / -12 gateway.log
    // rotations, n=9 successful turns, `uplink_committed` → first
    // `upstream_audio_delta` = 0.17 / 0.63 / 1.09 / 1.11 / 1.15 / 1.75 / 1.80 /
    // 2.81 / 3.46 s. 8 s is 2.3x the slowest of those, so a slow-but-healthy
    // answer is not killed. Both bounds are pinned by
    // `test/ess842-response-deadline.test.mjs` against the shipped config, and
    // the client side is mirrored by `AudioRealtimeAgentConfig.responseWaitTimeout`.
    // n=9 is a thin sample (R-04.4), which is why this stays a config knob.
    responseTimeoutMs = 8_000,
    takeover = true,
    // ESS-978: our own identity on the upstream. The label embeds the pid so
    // two copies of this gateway on one machine are distinguishable, and the
    // takeover guard treats "same label" as "same process, our own residual".
    clientLabel = `watch-direct-gateway:${process.pid}`,
    log = () => {},
  } = {}) {
    this.gatewayUrl = gatewayUrl
    this.connectTimeoutMs = connectTimeoutMs
    this.maxPendingBytes = maxPendingBytes
    this.maxDownlinkFrameBytes = maxDownlinkFrameBytes
    this.maxDownlinkFrames = maxDownlinkFrames
    this.maxDownlinkBytes = maxDownlinkBytes
    this.doneSettleMs = doneSettleMs
    this.duplicateWindowMs = duplicateWindowMs
    this.maxReplayFingerprints = maxReplayFingerprints
    this.reorderWaitMs = reorderWaitMs
    this.maxReorderFrames = maxReorderFrames
    this.responseTimeoutMs = responseTimeoutMs
    this.takeover = takeover
    this.clientLabel = clientLabel
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

  // ESS-978: may this turn steal the single voice slot from `holder`?
  // A second copy of this gateway on the same machine shares our label family
  // but not our process, so a foreign `watch-direct-gateway:*` is never taken
  // over — that is the exact shape of the 2026-08-22 02:19 incident. Our own
  // prior connection (same client label → same process) is always reclaimable,
  // and a frontend / bridge holder is taken over only when configured
  // (`agent_takeover_voice`, the `takeover` constructor flag).
  #takeoverEligible(holder) {
    const label = holder?.label ?? ''
    if (!label) return false
    if (label === this.clientLabel) return true
    if (label === GATEWAY_LABEL || label.startsWith(`${GATEWAY_LABEL}:`)) return false
    return this.takeover === true
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
    // ESS-842: our own client identity on the upstream, kept on the turn so an
    // ownership event can be compared against it. The upstream reports the
    // holder of the single voice slot; without knowing who WE are, a `busy`
    // frame cannot be told apart from an echo of our own ownership.
    const clientInstanceId = `gateway_${randomUUID()}`
    const turn = {
      key, conversation,
      requestId, sessionId, deviceId, generation, responseId, onEvent,
      ws: null, ready: false, terminal: false, committed: false,
      pending: [], pendingBytes: 0, nextOutputSequence: 0,
      downlinkFrames: 0, downlinkBytes: 0,
      connectTimer: null,
      doneTimer: null, pendingDone: false, recentUpstreamFrames: new Map(),
      expectedUpstream: 0, anchored: false, reorderBuffer: new Map(), gapTimer: null,
      clientInstanceId, ownershipState: null, ownershipHolderLabel: null,
      ownershipHolderInstanceId: null, takeoverAttempted: false,
      responseTimer: null, responded: false, commitSentAt: null,
    }
    const scopeLog = { request_id: requestId, session_id: sessionId, device_id: deviceId, generation }
    turn.supersede = nextRequestId => {
      if (turn.terminal) return
      turn.terminal = true
      clearTimeout(turn.connectTimer)
      clearTimeout(turn.doneTimer)
      clearTimeout(turn.gapTimer)
      clearTimeout(turn.responseTimer)
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
      clearTimeout(turn.doneTimer)
      clearTimeout(turn.gapTimer)
      clearTimeout(turn.responseTimer)
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

    // ESS-842 committed-turn deadline. Armed the moment `audio.commit` really
    // reaches the upstream socket (not when the client asks for it — a queued
    // commit is still covered by the connect timeout), disarmed by the first
    // frame that proves a response exists. On expiry the turn fails closed
    // with a typed, retriable error so the client learns "no answer" instead
    // of waiting on a silent socket until it dies as a bare 1006.
    const armResponseDeadline = () => {
      if (this.responseTimeoutMs <= 0) return
      if (turn.terminal || turn.responded || turn.responseTimer) return
      turn.commitSentAt = Date.now()
      turn.responseTimer = setTimeout(() => {
        turn.responseTimer = null
        if (turn.terminal || turn.responded) return
        this.log('upstream_response_timeout', {
          ...scopeLog,
          waited_ms: Date.now() - turn.commitSentAt,
          timeout_ms: this.responseTimeoutMs,
          upstream_ready: turn.ready,
          ownership_state: turn.ownershipState,
          ownership_holder_label: turn.ownershipHolderLabel,
          ownership_holder_instance_id: turn.ownershipHolderInstanceId,
        })
        fail('ERR_UPSTREAM_NO_RESPONSE',
          `upstream produced no response within ${this.responseTimeoutMs}ms of audio.commit`)
      }, this.responseTimeoutMs)
      turn.responseTimer.unref?.()
    }

    // Any frame that belongs to the response (delta, done, or an upstream
    // error) proves the upstream is answering; the deadline has done its job.
    const noteResponseProgress = () => {
      if (turn.responded) return
      turn.responded = true
      clearTimeout(turn.responseTimer)
      turn.responseTimer = null
    }

    // ESS-773 done barrier. `audio.done` is not forwarded on arrival: it opens
    // a settle window that every late `audio.delta` restarts, so `final_sequence`
    // always covers the frames that were actually forwarded. Anything that ends
    // the upstream socket while the window is open flushes it rather than
    // dropping it — a completed response must not surface as a disconnect.
    const flushDone = () => {
      if (!turn.pendingDone) return
      // A hole is still outstanding: the run is not complete, so it is not done.
      // The gap timer decides — the frame arrives, or the turn fails closed.
      if (turn.reorderBuffer.size > 0) return
      turn.pendingDone = false
      clearTimeout(turn.doneTimer)
      turn.doneTimer = null
      const finalSequence = turn.nextOutputSequence - 1
      this.log('upstream_audio_done', { ...scopeLog, final_sequence: finalSequence })
      onEvent({
        type: 'agent.audio.done', response_id: responseId, final_sequence: finalSequence,
      })
    }

    const scheduleDone = () => {
      clearTimeout(turn.doneTimer)
      turn.doneTimer = setTimeout(() => {
        turn.doneTimer = null
        if (turn.terminal) return
        flushDone()
      }, this.doneSettleMs)
      turn.doneTimer.unref?.()
    }

    // Forward one accepted frame and stamp it with the downstream contract's
    // sequence. Ordering has already been settled by `enqueueOrdered`.
    const emitDelta = frame => {
      const sequence = turn.nextOutputSequence++
      if (turn.pendingDone) {
        clearTimeout(turn.doneTimer)
        turn.doneTimer = null
        this.log('upstream_done_extended_for_late_delta', {
          ...scopeLog, upstream_sequence: frame.upstreamSequence, sequence,
        })
      }
      this.log('upstream_event_received', {
        ...scopeLog, upstream_event_type: 'audio.delta', sequence,
        upstream_sequence: frame.upstreamSequence,
      })
      this.log('upstream_audio_delta', { ...scopeLog, sequence })
      onEvent({
        type: 'agent.audio.delta', response_id: responseId, sequence,
        sample_rate: frame.sampleRate, codec: 'pcm_s16le', audio: frame.audio,
      })
      if (turn.pendingDone) scheduleDone()
    }

    const drainContiguous = () => {
      while (turn.reorderBuffer.has(turn.expectedUpstream)) {
        const buffered = turn.reorderBuffer.get(turn.expectedUpstream)
        turn.reorderBuffer.delete(turn.expectedUpstream)
        turn.expectedUpstream += 1
        turn.anchored = true
        emitDelta(buffered)
      }
      if (turn.reorderBuffer.size === 0) {
        clearTimeout(turn.gapTimer)
        turn.gapTimer = null
      }
    }

    const armGapTimer = () => {
      if (turn.gapTimer) return
      turn.gapTimer = setTimeout(() => {
        turn.gapTimer = null
        if (turn.terminal || turn.reorderBuffer.size === 0) return
        // Nothing has been forwarded yet, so this is not a lost frame — the
        // response simply did not start where we assumed. Anchor on the lowest
        // sequence actually offered and continue; only a hole AFTER the first
        // forwarded frame is evidence that the upstream dropped audio.
        if (!turn.anchored) {
          const lowest = Math.min(...turn.reorderBuffer.keys())
          this.log('upstream_sequence_anchored', { ...scopeLog, upstream_sequence: lowest })
          turn.expectedUpstream = lowest
          drainContiguous()
          if (turn.reorderBuffer.size > 0) armGapTimer()
          return
        }
        fail('ERR_UPSTREAM_SEQUENCE_GAP',
          `upstream never delivered sequence ${turn.expectedUpstream}`)
      }, this.reorderWaitMs)
      turn.gapTimer.unref?.()
    }

    // ESS-773: the upstream sequence keeps its ordering meaning here — it is
    // the only thing that can witness a hole — while the number handed
    // downstream is always the dense contract sequence assigned in `emitDelta`.
    const enqueueOrdered = frame => {
      const { upstreamSequence } = frame
      if (upstreamSequence < turn.expectedUpstream) {
        // The counter went backwards. An exact near-simultaneous replay was
        // already dropped upstream of here, so this is a restart carrying new
        // audio. A hole open at that moment can never be filled by it.
        if (turn.reorderBuffer.size > 0) {
          fail('ERR_UPSTREAM_SEQUENCE_GAP',
            `upstream restarted at ${upstreamSequence} while ${turn.expectedUpstream} was missing`)
          return
        }
        this.log('upstream_sequence_restarted', {
          ...scopeLog, upstream_sequence: upstreamSequence,
          expected_upstream_sequence: turn.expectedUpstream,
        })
        turn.expectedUpstream = upstreamSequence
      }
      if (upstreamSequence === turn.expectedUpstream) {
        turn.expectedUpstream += 1
        turn.anchored = true
        emitDelta(frame)
        drainContiguous()
        return
      }
      // Ahead of what is owed: hold it until the hole in front of it is filled.
      if (turn.reorderBuffer.has(upstreamSequence)) {
        fail('ERR_UPSTREAM_SEQUENCE_GAP',
          `upstream repeated sequence ${upstreamSequence} while reordering`)
        return
      }
      turn.reorderBuffer.set(upstreamSequence, frame)
      if (turn.reorderBuffer.size > this.maxReorderFrames) {
        fail('ERR_UPSTREAM_REORDER_OVERFLOW',
          `upstream reorder buffer exceeded ${this.maxReorderFrames} frames`)
        return
      }
      armGapTimer()
    }

    // Returns true when the event actually reached the upstream socket, false
    // when it was queued (or dropped because the turn is over) — the commit
    // deadline may only start once the upstream has really been told.
    const sendOrQueue = (event, bytes = 0) => {
      if (turn.terminal) return false
      if (turn.ready && turn.ws?.readyState === WebSocket.OPEN) {
        turn.ws.send(JSON.stringify(event))
        return true
      }
      if (turn.pendingBytes + bytes > this.maxPendingBytes) {
        fail('ERR_UPSTREAM_BUFFER_LIMIT', 'upstream was not ready before the audio buffer filled')
        return false
      }
      turn.pending.push(event)
      turn.pendingBytes += bytes
      return false
    }

    // ESS-978: two-step upstream connect. The first attempt connects WITHOUT
    // takeover so the upstream reports who currently holds the single voice
    // slot; we only steal it when the holder is provably ours (our own prior
    // connection, same process) or an allowed frontend. A foreign gateway
    // instance — a second copy of this module on the same machine — is never
    // stolen from, so a stray dev/test process cannot silently kill a live
    // production turn (2026-08-22 02:19 incident).
    const connect = takeover => {
      if (turn.terminal) return
      let ws
      try {
        ws = new WebSocket(url)
      } catch (error) {
        fail('ERR_UPSTREAM_UNAVAILABLE', error.message)
        return
      }
      turn.ws = ws
      clearTimeout(turn.connectTimer)
      turn.connectTimer = setTimeout(() => {
        fail('ERR_UPSTREAM_TIMEOUT', `upstream connect exceeded ${this.connectTimeoutMs}ms`)
      }, this.connectTimeoutMs)
      turn.connectTimer.unref?.()

      ws.on('open', () => {
        // A stale socket — superseded/cancelled, or retired for a takeover
        // retry — must not announce a connection nobody owns any more.
        if (turn.ws !== ws) {
          try { ws.close(1000, 'superseded') } catch { /* best effort */ }
          return
        }
        if (!this.#isCurrent(turn)) {
          try { ws.close(1000, 'superseded') } catch { /* best effort */ }
          return
        }
        ws.send(JSON.stringify({
          type: 'connect', clientType: 'cli', clientLabel: this.clientLabel,
          clientInstanceId: turn.clientInstanceId, voiceEnabled: true,
          manualTurnDetection: true, takeover,
          timeZone: 'Asia/Shanghai', locale: 'zh-CN',
        }))
      })
      ws.on('message', raw => {
        // Every frame is validated against THIS turn instance — and against
        // THIS socket — before it can touch downstream state: a superseded or
        // retired socket may still be draining the provider's prior response,
        // and forwarding it would stamp those bytes with a scope that no
        // longer owns the conversation (ESS-745).
        if (turn.ws !== ws) return
        if (!this.#isCurrent(turn)) return
        let event
        try { event = JSON.parse(raw.toString()) } catch { return }
        if (event.type === 'voice.ready') {
          if (turn.ready) return
          turn.ready = true
          turn.ownershipState = 'active'
          clearTimeout(turn.connectTimer)
          this.log('upstream_ready', scopeLog)
          for (const queued of turn.pending) ws.send(JSON.stringify(queued))
          turn.pending = []
          turn.pendingBytes = 0
          // A commit that was queued behind the handshake only reaches the
          // upstream here, so this is where its deadline starts.
          if (turn.committed) armResponseDeadline()
          return
        }
        if (event.type === 'voice.ownership' || event.type === 'voice.deactivated') {
          const holder = event.holder ?? null
          const holderIsSelf = holder?.instanceId === turn.clientInstanceId
          turn.ownershipState = event.type === 'voice.deactivated'
            ? 'deactivated' : (event.state ?? null)
          turn.ownershipHolderLabel = holder?.label ?? null
          turn.ownershipHolderInstanceId = holder?.instanceId ?? null
          // ESS-842 forensics: the single fact that decides whether a silent
          // upstream is "still thinking" or "discarding our audio" was never
          // recorded. ESS-978 adds the holder's per-connection instance id —
          // with every instance sharing the same client label, only the
          // instance id distinguishes WHICH gateway copy stole the voice. The
          // holder identity is a client label / instance id, not a credential.
          this.log('upstream_ownership', {
            ...scopeLog, event_type: event.type,
            state: turn.ownershipState, holder_label: turn.ownershipHolderLabel,
            holder_instance_id: turn.ownershipHolderInstanceId,
            holder_is_self: holderIsSelf, upstream_ready: turn.ready,
          })
          if (!turn.ready) {
            if (event.state !== 'busy') return
            // Connect-time busy: the single voice slot is held by somebody
            // else. Only steal when the holder is provably ours or an allowed
            // frontend — never a foreign gateway instance. The retry is
            // attempted once, with takeover, on a fresh socket.
            if (!turn.takeoverAttempted && this.#takeoverEligible(holder)) {
              turn.takeoverAttempted = true
              this.log('upstream_takeover_retry', {
                ...scopeLog, holder_label: turn.ownershipHolderLabel,
                holder_instance_id: turn.ownershipHolderInstanceId,
              })
              // Terminate rather than gracefully close: the retry reuses this
              // turn's clientInstanceId, so two sockets must never coexist
              // under the same identity (mirrors the Bridge supervisor).
              try { ws.terminate() } catch { /* closing */ }
              connect(true)
              return
            }
            fail('ERR_VOICE_BUSY',
              `upstream voice ownership held by ${turn.ownershipHolderLabel ?? 'unknown'}`
              + (turn.ownershipHolderInstanceId ? ` (${turn.ownershipHolderInstanceId})` : ''))
            return
          }
          // Ownership lost mid-turn. The upstream drops a non-owner's
          // `audio.append` / `audio.commit` without answering (ESS-37 §2.1),
          // so continuing would spend the whole response deadline on audio
          // that is being thrown away. Fail now, with the holder named.
          if (event.type === 'voice.deactivated'
            || (event.state === 'busy' && !holderIsSelf)) {
            fail('ERR_VOICE_OWNERSHIP_LOST',
              `upstream voice ownership lost mid-turn (holder=${turn.ownershipHolderLabel ?? 'unknown'}`
              + (turn.ownershipHolderInstanceId ? `/${turn.ownershipHolderInstanceId}` : '') + ')')
          }
          return
        }
        if (event.type === 'audio.delta' && event.audio) {
          noteResponseProgress()
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
          // ESS-773: drop a near-simultaneous exact replay, and only that. The
          // fingerprint needs the upstream sequence to witness a replay at all,
          // so a frame that arrives without one is always forwarded; and the
          // window has to expire, because outside it the same fingerprint is
          // legitimate audio (a restarted counter re-presenting silence).
          const upstreamSequence = Number.isInteger(event.sequence) && event.sequence >= 0
            ? event.sequence : null
          if (upstreamSequence !== null) {
            const now = Date.now()
            for (const [seen, at] of turn.recentUpstreamFrames) {
              if (now - at > this.duplicateWindowMs) turn.recentUpstreamFrames.delete(seen)
            }
            const key = replayKey(upstreamSequence, audio)
            const lastSeenAt = turn.recentUpstreamFrames.get(key)
            if (lastSeenAt !== undefined && now - lastSeenAt <= this.duplicateWindowMs) {
              this.log('upstream_audio_duplicate_dropped', {
                ...scopeLog, upstream_sequence: upstreamSequence,
                age_ms: now - lastSeenAt,
              })
              return
            }
            turn.recentUpstreamFrames.set(key, now)
            // Capacity backstop: a flood inside one window must not outgrow the
            // TTL sweep. Map preserves insertion order, so this drops oldest.
            while (turn.recentUpstreamFrames.size > this.maxReplayFingerprints) {
              turn.recentUpstreamFrames.delete(turn.recentUpstreamFrames.keys().next().value)
            }
          }
          // The downstream barrier can only release on a dense 0..N run, so the
          // number handed downstream is always assigned here — but the upstream
          // sequence still decides ORDER and still proves the run is complete.
          // A frame that carries no upstream sequence cannot be ordered against
          // anything, so it is forwarded as it arrives.
          const frame = {
            upstreamSequence, audio: event.audio,
            sampleRate: event.sampleRate ?? 24_000,
          }
          if (upstreamSequence === null) emitDelta(frame)
          else enqueueOrdered(frame)
          return
        }
        if (event.type === 'audio.done') {
          noteResponseProgress()
          this.log('upstream_event_received', {
            ...scopeLog, upstream_event_type: 'audio.done',
            final_sequence: turn.nextOutputSequence - 1,
          })
          turn.pendingDone = true
          scheduleDone()
          return
        }
        // Metadata is optional for the direct Watch stream (RealtimeSession
        // ignores unknown agent events) but required by the full-file job
        // executor so Bridge can preserve text and background task semantics.
        if (event.type === 'transcript.final') {
          noteResponseProgress()
          onEvent({ type: 'agent.transcript.final', response_id: responseId,
            role: event.role, content: typeof event.content === 'string' ? event.content : '' })
          return
        }
        if (event.type.startsWith('task.') && event.task?.id) {
          noteResponseProgress()
          onEvent({ type: 'agent.task', response_id: responseId,
            task: { id: String(event.task.id), status: event.task.status ?? event.type.slice(5) } })
          return
        }
        if (event.type === 'error' || event.type === 'session.error' || event.type === 'voice.error') {
          noteResponseProgress()
          fail(event.code ?? 'ERR_UPSTREAM_UNAVAILABLE', event.message ?? event.detail ?? 'upstream error')
        }
      })
      ws.on('error', error => {
        if (turn.ws !== ws) return
        fail('ERR_UPSTREAM_UNAVAILABLE', error.message)
      })
      ws.on('close', (code, reason) => {
        if (turn.ws !== ws) return
        if (turn.terminal) return
        // The provider may close right after `audio.done`. The response is
        // complete, so release the barrier instead of reporting a disconnect —
        // but only if nothing is still missing; a close over an open hole is a
        // disconnect, not a completion.
        if (turn.pendingDone && turn.reorderBuffer.size === 0) {
          flushDone()
          turn.terminal = true
          clearTimeout(turn.connectTimer)
          clearTimeout(turn.responseTimer)
          this.#release(turn)
          return
        }
        fail('ERR_UPSTREAM_DISCONNECTED', `code=${code} reason=${String(reason)}`)
      })
    }
    connect(false)

    return {
      appendAudio: ({ bytes, parentRequestId = null, contextSummary = null }) => sendOrQueue({
        type: 'audio.append', audio: bytes.toString('base64'),
        ...(parentRequestId ? { parent_request_id: parentRequestId } : {}),
        ...(contextSummary ? { context_summary: contextSummary } : {}),
      }, bytes.length),
      commit: () => {
        if (turn.committed || turn.terminal) return
        turn.committed = true
        if (sendOrQueue({ type: 'audio.commit' })) armResponseDeadline()
      },
      cancel: () => {
        if (turn.terminal) return
        if (turn.ws?.readyState === WebSocket.OPEN) {
          turn.ws.send(JSON.stringify({ type: 'response.cancel' }))
        }
        turn.terminal = true
        clearTimeout(turn.connectTimer)
        clearTimeout(turn.doneTimer)
        clearTimeout(turn.gapTimer)
        clearTimeout(turn.responseTimer)
        turn.ws?.close()
        this.#release(turn)
      },
      close: () => {
        if (turn.terminal) return
        turn.terminal = true
        clearTimeout(turn.connectTimer)
        clearTimeout(turn.doneTimer)
        clearTimeout(turn.gapTimer)
        clearTimeout(turn.responseTimer)
        if (turn.ws?.readyState === WebSocket.OPEN) {
          turn.ws.send(JSON.stringify({ type: 'mute' }))
        }
        turn.ws?.close()
        this.#release(turn)
      },
    }
  }
}
