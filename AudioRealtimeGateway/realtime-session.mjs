// Realtime session state machine — one instance per accepted WSS upgrade.
// It owns:
//   • strict client→server frame schema + monotone uplink sequence check
//   • generation-aware server→client emission (dedup by sequence, drop
//     stale generations, `audio.done` barrier with `final_sequence`)
//   • ESS-969 multi-segment turns: `audio.segment_done` marks the end of ONE
//     answer segment while the turn continues (a tool-calling turn speaks
//     「我正在查询…」, runs the tool, then speaks the real answer); `audio.done`
//     stays the single turn terminal. Both ride the same dense-prefix barrier
//     and the same monotone downlink sequence space.
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
    doneBarrierGapMs = 30_000,
    // ESS-959: 「session_ready → uplink_committed」的看门狗时限。上游的
    // responseTimeoutMs 只在 commit 之后起算，建连了但永远不 commit 的
    // 会话没有任何服务端时限，只能等上游 socket 自然死亡（真机实测白等
    // 30s）。超时 fail-closed，不再把兜底寄托在上游 socket 生命周期。
    commitDeadlineMs = 30_000,
    maxFrameBytes = 64 * 1024,
    maxEventsPerSecond = 200,
    maxUplinkBytesPerSecond = 512 * 1024,
    // Downlink budget (ESS-746). `seenDownlinkSequences` and the socket send
    // buffer both grow with the number of forwarded deltas, so an upstream
    // that never stops producing (or that claims an absurd `final_sequence`)
    // must hit a ceiling instead of the process heap. The sequence window is
    // what bounds the Set: a sequence at or beyond `maxDownlinkFrames` can
    // never be part of a legal dense prefix within the budget.
    maxDownlinkFrames = 4096,
    maxDownlinkBytes = 32 * 1024 * 1024,
    // ESS-1160 产生端抑制与背压护栏。真机取证（turn
    // `01a07230-b0a1-795a-ad2a-d2e67c6478be`）：上游在 209 ms 内推了 33 次
    // 逐字相同的「正在整理结果」，网关逐帧下发，客户端（iPhone → Watch 走
    // WCSession 那一跳）积压 3 s 后 1006 断连，答案一个字都没到。
    //   • `taskStateHeartbeatMs`：同文帧的**最小下发间隔**。0 关闭抑制。
    //     下限心跳仍要留——完全不发会让客户端无从区分「上游在慢慢做」和
    //     「网关死了」，而客户端的任务活动看门狗（`SessionController`
    //     `taskActivityTimeoutSeconds = 60 s`）量的正是静默时长。
    //   • `maxTaskStateFramesPerSecond`：**纯展示帧**的每秒上限，防止未来
    //     任何「文字每帧都在变」的上游异常再打穿客户端。0 关闭限速。
    taskStateHeartbeatMs = 2_000,
    maxTaskStateFramesPerSecond = 10,
    taskStateRateWindowMs = 1_000,
    // `session_ended` 帧率快照的回看窗口：断线前这段时间里实际下发了多少帧。
    taskStateSnapshotWindowMs = 5_000,
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
    this.doneBarrierGapMs = doneBarrierGapMs
    this.maxFrameBytes = maxFrameBytes
    this.maxEventsPerSecond = maxEventsPerSecond
    this.maxUplinkBytesPerSecond = maxUplinkBytesPerSecond
    this.maxDownlinkFrames = maxDownlinkFrames
    this.maxDownlinkBytes = maxDownlinkBytes
    this.taskStateHeartbeatMs = taskStateHeartbeatMs
    this.maxTaskStateFramesPerSecond = maxTaskStateFramesPerSecond
    this.taskStateRateWindowMs = taskStateRateWindowMs
    this.taskStateSnapshotWindowMs = taskStateSnapshotWindowMs
    this.commitDeadlineMs = commitDeadlineMs
    this.now = now
    this.setTimer = setTimer
    this.clearTimer = clearTimer

    this.state = OPEN
    this.started = false
    this.nextUplinkSequence = 0
    this.uplinkCommitted = false
    this.firstUplinkAt = null
    this.firstDownlinkAt = null
    this._commitDeadlineTimer = null

    // Generation-scoped state. On barge-in the WSS is torn down and a new
    // handshake with generation+1 makes a new session, so we only ever have
    // one active generation per connection. Keep it as fields (not per-gen
    // maps) — simpler is better here.
    this.activeGeneration = scope.generation
    this.responseId = scope.request_id + ':gen' + scope.generation
    this.seenDownlinkSequences = new Set()
    this.downlinkHighWatermark = -1
    this.downlinkBytes = 0
    this.doneEmitted = false
    // ESS-1145: 收口原因（`task_terminal_audio_done` / `task_cancelled_answer_done`
    // / `segment_gap` …）。只留证，不上线格。
    this.doneReason = null
    this.cancelled = false
    // `pendingFinalSequence` is the raw `final_sequence` the upstream sent on
    // `agent.audio.done`; we hold it verbatim until `0..pendingFinalSequence`
    // is dense in `seenDownlinkSequences`, then release ONE downstream
    // `audio.done(final_sequence=pendingFinalSequence)`. Never rewritten.
    this.pendingFinalSequence = null
    // ESS-969: segment boundaries WITHIN one turn. `audio.done` remains the
    // single turn terminal (`doneEmitted` is still set exactly once and is
    // never reset — the reset problem disappears because a segment boundary
    // no longer masquerades as a turn end). A segment done is held on the
    // same dense-prefix rule as the turn barrier, but it needs its own slot:
    // it must NOT become `pendingFinalSequence`, or `_emitDelta` would start
    // dropping the next segment's frames as "past the promised barrier".
    this.pendingSegmentDone = null
    this.segmentsEmitted = 0
    // ESS-1071: after a segment boundary is released, the next delta is the
    // first audio frame of the following segment — the marker that makes
    // `segment_to_first_audio_ms` measurable end-to-end.
    this.expectSegmentFirstFrame = false
    // `done(-1)` is ambiguous until a short bounded window elapses: it can
    // mean a genuinely empty response, or (as observed in ESS-526) an
    // upstream marker that races ahead of the first delta.  Do not commit it
    // downstream until the existing barrier window proves no delta followed.
    this._emptyDoneWindowElapsed = false
    this.finalSequence = null       // set when the downstream done is released
    this.staleGenerationDropped = 0
    this.postDoneAudioDropped = 0
    // ESS-1100: per-session monotone display sequence for `task.state`
    // progress. Only bumped when a frame actually carries progress text, so
    // the client's「drop anything not newer」rule has no holes to fall into.
    this.progressSequence = 0
    // ESS-1111: per-session monotone display sequence for `task.state`
    // answer deltas. Independent of `progressSequence` and of the audio
    // sequence space — a progress frame must never renumber the answer
    // stream, and an answer delta must never consume an audio sequence.
    this.answerSequence = 0
    // ESS-1160: 产生端同文抑制的记账。`lifecycleKey` 是 ESS-1097 的裁决面
    // （`task_id` + `status`），`displayKey` 在它之上再叠 ESS-1100 的展示面
    // （进展文字 + 类目）。抑制只发生在**两者都没变且不带答案增量**的帧上：
    // 生命周期跃迁与答案增量永远原样下发，护栏不碰它们。
    this._lastTaskStateLifecycleKey = null
    this._lastTaskStateDisplayKey = null
    this._lastTaskStateSentAt = null
    this.taskStateFrames = 0
    this.taskStateSuppressedSameText = 0
    this.taskStateRateLimited = 0
    this._taskStateRateWindowStart = this.now()
    this._taskStateInRateWindow = 0
    this._taskStateRateWindowLogged = false
    // 断线前 N 秒的帧率快照用的发送时刻环形缓冲，按窗口裁剪，天然有界。
    this._taskStateEmitTimes = []
    this._barrierTimer = null

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
    this._clearBarrierTimer()
    this._clearCommitDeadline()
    if (this.agentTurn) { try { this.agentTurn.close() } catch { /* ignore */ } }
    this.log('session_ended', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation,
      reason: (reason && String(reason)) || 'peer_closed',
      close_code: typeof code === 'number' ? code : null,
      stale_generation_dropped: this.staleGenerationDropped,
      post_done_audio_dropped: this.postDoneAudioDropped,
      segments_emitted: this.segmentsEmitted,
      final_sequence: this.finalSequence,
      done_emitted: this.doneEmitted,
      cancelled: this.cancelled,
      // ESS-1160 取证：断线的**成因面**。1006 之后只有「done_emitted=false」
      // 一句话时，无从判断是客户端放下手腕还是被下行帧打穿；这四个数把
      // 「断线前这几秒网关到底往下灌了多少」变成可判定的。
      task_state_frames: this.taskStateFrames,
      task_state_frames_last_window: this._taskStateFramesSince(this.now()),
      task_state_snapshot_window_ms: this.taskStateSnapshotWindowMs,
      task_state_suppressed_same_text: this.taskStateSuppressedSameText,
      task_state_rate_limited: this.taskStateRateLimited,
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
      // ESS-745: request_id / session_id are client-supplied and unique only
      // within a device, so the transport needs the whole scope to key its
      // active turns.
      deviceId: this.scope.device_id,
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
    this._armCommitDeadline()
  }

  /// ESS-959: arm the「建连后迟迟不 commit」看门狗。session_ready 后起算，
  /// 超时 fail-closed 并落结构化事件；audio.commit 到达时清除。
  _armCommitDeadline() {
    if (this.commitDeadlineMs <= 0 || this._commitDeadlineTimer) return
    this._commitDeadlineTimer = this.setTimer(() => {
      this._commitDeadlineTimer = null
      if (this.state !== OPEN || this.uplinkCommitted || this.cancelled) return
      this.log('commit_deadline_timeout', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        deadline_ms: this.commitDeadlineMs,
        frames_seen: this.nextUplinkSequence,
      })
      this.fail('ERR_COMMIT_DEADLINE_TIMEOUT', {
        detail: `no audio.commit within ${this.commitDeadlineMs}ms of session.start`,
        retriable: true,
      })
    }, this.commitDeadlineMs)
    this._commitDeadlineTimer.unref?.()
  }

  _clearCommitDeadline() {
    if (this._commitDeadlineTimer) {
      this.clearTimer(this._commitDeadlineTimer)
      this._commitDeadlineTimer = null
    }
  }

  _handleAudioAppend(message) {
    if (this.uplinkCommitted) return this.fail('ERR_STREAM_COMMITTED')
    if (this.cancelled) return this.fail('ERR_GENERATION_STALE')
    if (message.sequence !== this.nextUplinkSequence) {
      return this.fail('ERR_STREAM_SEQUENCE', {
        expected_sequence: this.nextUplinkSequence, got_sequence: message.sequence,
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
    this._clearCommitDeadline()
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
    // Cancel is authoritative — kill any pending done barrier so the gap
    // timer cannot fire a fail-closed after the client has moved on.
    this._clearBarrierTimer()
    this.pendingFinalSequence = null
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
      generation: this.scope.generation,
      response_id: message.response_id,
    })
    // ESS-1068 复审第1点：把 Watch 的 playback 回执转发给上游
    //（qwen-agent-transport → qwen），触发 qwen 的 announcement
    // confirmMany（ack）。不回这个回执，qwen 会在 ack 超时后无限重投
    // 已播报的后台任务结果。
    if (phase === 'started') this.agentTurn?.playbackStarted?.(message.response_id)
    else if (phase === 'ended') this.agentTurn?.playbackEnded?.(message.response_id)
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
        generation: this.scope.generation,
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
        generation: this.scope.generation,
        reason: 'post_cancel', event_type: event.type,
        total_dropped: this.staleGenerationDropped,
      })
      return
    }
    if (event.type === 'agent.task') {
      return this._emitTaskState({
        taskId: event.task?.id ?? null,
        status: event.task?.status ?? null,
        progress: event.progress ?? null,
        answer: event.answer ?? null,
      })
    }
    if (event.type === 'agent.tool_call_state') {
      return this._emitTaskState({ taskId: null, status: event.status ?? null })
    }
    if (event.type === 'agent.audio.delta') return this._emitDelta(event)
    if (event.type === 'agent.audio.segment_done') return this._emitSegmentDone(event)
    if (event.type === 'agent.audio.done') return this._emitDone(event)
    if (event.type === 'agent.error') return this.fail(event.code ?? 'ERR_UPSTREAM_UNAVAILABLE',
      { detail: event.detail ?? null, retriable: Boolean(event.retriable) })
  }

  // ESS-1097: project the upstream task lifecycle onto the client.
  //
  // Why the client needs it (ESS-1095 real-device evidence): until now the ONLY
  // inputs a client had for「is this turn over」were audio-side — the
  // `audio.done` barrier and its own playback endgame. Whether a tool was still
  // running was known HERE and nowhere else, so the client had to trust this
  // gateway's bounded idle window (ESS-1043 `toolCallWindowMs = 30_000`,
  // calibrated on 8–16 s tool runs). One slower tool overshoots that window, the
  // client relistens, the user speaks, and the new request supersedes the tool
  // turn — the incident exactly. The contract this implements is the one the
  // client documents in `AudioRealtimeGateway/README.md`
  //「`task.state` 线格不变量」(ESS-1097 / ESS-1098).
  //
  // Two shapes, distinguished by whether `task_id` is present:
  //   • task frame  `{task_id, status}` — status is passed through verbatim;
  //     interpreting it is the client's business (an unknown status must be
  //     read as NON-terminal there).
  //   • latch frame `{status: 'tool_call_pending' | 'tool_call_resolved'}` —
  //     「a task is coming but has no id yet」and its release.
  //
  // Deliberately NOT gated on `doneEmitted`: a task terminal that lands after
  // the turn barrier is precisely what releases the client's hold. Dropping it
  // there would build the deadlock this event exists to prevent. It carries no
  // audio and touches no barrier, so it cannot reorder or delay playback.
  //
  // ESS-1100 追加的第三个可选切面 `progress`：`{progress_text,
  // progress_category, progress_seq}`。它**只是展示面**——不参与任何屏障、
  // 不改变任务集合的裁决，缺席时这一帧与 ESS-1097 的老帧逐字节相同，所以
  // 未升级的客户端忽略这三个键即可。
  //
  // `progress_seq` 是**每会话单调递增**的展示序号：客户端据此丢弃迟到与重复
  // 的进展帧。它必须由服务端发，因为客户端那一侧（iPhone → Watch 的
  // WCSession 跳）不保证顺序，只靠到达顺序会把旧进展盖回新进展上。
  _emitTaskState({ taskId, status, progress = null, answer = null }) {
    if (taskId === null && !status) return
    const progressText = typeof progress?.text === 'string' && progress.text.trim()
      ? progress.text.trim()
      : null
    // ESS-1111 的第四个可选切面 `answer_delta` / `answer_seq`：最终答案的
    // **文本增量**。与 `progress_*` 一样是纯展示面，不参与任何屏障，也不占用
    // 音频的 sequence 空间——音频仍按既有序列与 barrier 保序，两者互不阻塞。
    // 缺席时这一帧与 ESS-1100 的帧逐字节相同，老客户端忽略这两个键即可。
    //
    // 与 `progress_seq` 同理，序号由服务端发：iPhone → Watch 那一跳走
    // WCSession，不保证顺序，客户端只有拿着单调序号才能把迟到的增量丢掉，
    // 而不是把一段旧文本追加到新答案后面。
    const answerDelta = typeof answer?.delta === 'string' && answer.delta !== ''
      ? answer.delta
      : null

    // ESS-1160 产生端抑制。ESS-1100 把「同文去抖 + 0.8 s 节流」放在客户端
    // `Shared/ToolProgressNarration.swift`，那是**渲染**节流——它减少 UI 刷新
    // 次数，减不掉已经上了 WSS 与 WCSession 的帧。真机取证里 209 ms 33 帧同文
    // 全部过网，客户端积压 3 s 后 1006。抑制必须做在产生端。
    //
    // 判据分三层，越靠前的越不可抑制：
    //   1. **答案增量**（ESS-1111）：每一帧内容都不同，永远下发。
    //   2. **生命周期跃迁**（ESS-1097 的 `task_id` + `status`）：客户端的任务集合
    //      裁决与终态收口全靠它，丢一帧就是把 ESS-1095 的死等装回去，永远下发。
    //   3. **纯展示帧**：只有这一层进抑制与限速。逐字相同且距上一帧不足
    //      `taskStateHeartbeatMs` 的丢弃；满了心跳间隔补发一帧，让客户端的
    //      60 s 任务活动看门狗有据可依。
    const taskKey = taskId === null ? null : String(taskId)
    const statusText = String(status ?? 'unknown')
    const progressCategory = progressText !== null && progress?.category
      ? String(progress.category)
      : null
    const lifecycleKey = `${taskKey ?? ''}\u0000${statusText}`
    const displayKey = `${lifecycleKey}\u0000${progressText ?? ''}\u0000${progressCategory ?? ''}`
    const lifecycleChanged = lifecycleKey !== this._lastTaskStateLifecycleKey
    const sameAsLastFrame = displayKey === this._lastTaskStateDisplayKey
    const at = this.now()
    if (answerDelta === null && !lifecycleChanged) {
      if (sameAsLastFrame
        && this.taskStateHeartbeatMs > 0
        && this._lastTaskStateSentAt !== null
        && at - this._lastTaskStateSentAt < this.taskStateHeartbeatMs) {
        // 抑制的帧**不占** `progress_seq`：客户端的「不比已应用的更新就丢弃」
        // 规则依赖序号连续可比，被抑制的帧本来就不该在那条线上留洞。
        // 这里刻意不落日志——一条帧一行日志就是把线格上的风暴原样搬进日志。
        this.taskStateSuppressedSameText += 1
        return
      }
      if (!this._admitTaskStateFrame(at)) return
    }

    let progressSeq = null
    if (progressText !== null) {
      this.progressSequence = (this.progressSequence ?? 0) + 1
      progressSeq = this.progressSequence
    }
    let answerSeq = null
    if (answerDelta !== null) {
      this.answerSequence = (this.answerSequence ?? 0) + 1
      answerSeq = this.answerSequence
    }
    this._noteTaskStateEmitted(at, { lifecycleKey, displayKey })
    this._sendJson({
      type: 'task.state',
      session_id: this.scope.session_id, request_id: this.scope.request_id,
      generation: this.scope.generation,
      ...(taskId === null ? {} : { task_id: String(taskId) }),
      status: String(status ?? 'unknown'),
      ...(progressText === null ? {} : {
        progress_text: progressText,
        progress_seq: progressSeq,
        ...(progressCategory === null ? {} : { progress_category: progressCategory }),
      }),
      ...(answerDelta === null ? {} : {
        answer_delta: answerDelta,
        answer_seq: answerSeq,
      }),
    })
    this.log('downlink_task_state', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation, response_id: this.responseId,
      task_id: taskId === null ? null : String(taskId),
      status: String(status ?? 'unknown'),
      progress_text: progressText,
      progress_category: progress?.category ?? null,
      progress_seq: progressSeq,
      // 答案文本是用户内容，只记长度与序号，不落原文。
      answer_seq: answerSeq,
      answer_delta_length: answerDelta === null ? null : answerDelta.length,
      after_turn_done: this.doneEmitted,
      // ESS-1160 取证：到这一帧为止被同文抑制掉的累计帧数，以及本帧是不是
      // 「同文但到了心跳间隔」补发的那一帧。
      suppressed_same_text: this.taskStateSuppressedSameText,
      same_text_heartbeat: answerDelta === null && !lifecycleChanged && sameAsLastFrame,
    })
  }

  /// ESS-1160 背压护栏：纯展示帧的每秒上限。生命周期帧与答案增量帧**不过**这道
  /// 闸（它们承载裁决与内容，丢弃比风暴更危险），但仍计入窗口——占用的带宽
  /// 是同一份。超限只在每个窗口首次触发时落一行日志，累计数一直记着。
  _admitTaskStateFrame(at) {
    if (this.maxTaskStateFramesPerSecond <= 0) return true
    this._rollTaskStateWindow(at)
    if (this._taskStateInRateWindow < this.maxTaskStateFramesPerSecond) return true
    this.taskStateRateLimited += 1
    if (!this._taskStateRateWindowLogged) {
      this._taskStateRateWindowLogged = true
      this.log('task_state_rate_limited', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        limit_per_second: this.maxTaskStateFramesPerSecond,
        window_ms: this.taskStateRateWindowMs,
        frames_in_window: this._taskStateInRateWindow,
        dropped_total: this.taskStateRateLimited,
      })
    }
    return false
  }

  _rollTaskStateWindow(at) {
    if (at - this._taskStateRateWindowStart >= this.taskStateRateWindowMs) {
      this._taskStateRateWindowStart = at
      this._taskStateInRateWindow = 0
      this._taskStateRateWindowLogged = false
    }
  }

  _noteTaskStateEmitted(at, { lifecycleKey, displayKey }) {
    this._rollTaskStateWindow(at)
    this._taskStateInRateWindow += 1
    this.taskStateFrames += 1
    this._lastTaskStateLifecycleKey = lifecycleKey
    this._lastTaskStateDisplayKey = displayKey
    this._lastTaskStateSentAt = at
    this._taskStateEmitTimes.push(at)
    this._taskStateFramesSince(at)
  }

  /// 裁掉快照窗口之外的发送时刻并返回窗口内的帧数。裁剪就地做，缓冲区因此
  /// 由「窗口 × 实际帧率」定界；再加一道硬上限，防止时钟回拨把它撑大。
  _taskStateFramesSince(at) {
    const cutoff = at - this.taskStateSnapshotWindowMs
    let drop = 0
    while (drop < this._taskStateEmitTimes.length && this._taskStateEmitTimes[drop] < cutoff) drop += 1
    if (drop > 0) this._taskStateEmitTimes.splice(0, drop)
    const overflow = this._taskStateEmitTimes.length - 1024
    if (overflow > 0) this._taskStateEmitTimes.splice(0, overflow)
    return this._taskStateEmitTimes.length
  }

  _emitDelta(event) {
    if (this.doneEmitted) {
      this.staleGenerationDropped += 1
      this.postDoneAudioDropped += 1
      this.log('stale_generation_dropped', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        reason: 'post_done', sequence: event.sequence,
        total_dropped: this.staleGenerationDropped,
      })
      this.log('post_done_audio_dropped', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        response_id: this.responseId, code: 'ERR_UPSTREAM_AUDIO_AFTER_DONE',
        sequence: event.sequence, dropped_count: this.postDoneAudioDropped,
      })
      // ESS-957: 工具调用场景下，第一段回答 done 之后模型还会产出第二段
      //（真正的答案）。静默丢弃让客户端完全无从知晓，Watch 只能在第一段
      // 播完后傻等。至少下发一个可观测的 warning 帧，让客户端能提示/降级。
      this._sendJson({
        type: 'audio.segment_dropped',
        session_id: this.scope.session_id, request_id: this.scope.request_id,
        response_id: this.responseId, generation: this.scope.generation,
        sequence: event.sequence, dropped_count: this.postDoneAudioDropped,
        reason: 'post_done',
      })
      return
    }
    if (!Number.isInteger(event.sequence) || event.sequence < 0) return
    // Sequence window: beyond it a delta can never complete a dense prefix
    // inside the frame budget, so accepting it would only grow the dedup set.
    if (event.sequence >= this.maxDownlinkFrames) {
      return this._failDownlinkBudget('sequence_out_of_window', {
        sequence: event.sequence, frames_cap: this.maxDownlinkFrames,
      })
    }
    // A first delta inside the bounded empty-response window disproves the
    // provisional done(-1).  Withdraw only that ambiguous marker.  A later
    // done(N) is still held and released verbatim under the ESS-388 barrier.
    if (this.pendingFinalSequence !== null && this.pendingFinalSequence < 0
      && this.seenDownlinkSequences.size === 0) {
      this.log('premature_empty_done_withdrawn', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        response_id: this.responseId, first_sequence: event.sequence,
      })
      this.pendingFinalSequence = null
      this._emptyDoneWindowElapsed = false
      this._clearBarrierTimer()
    }
    // Deltas whose sequence is beyond the upstream-claimed final_sequence
    // are dropped — upstream is contradicting itself, and forwarding them
    // would let a client receive frames past the promised barrier.
    if (this.pendingFinalSequence !== null && event.sequence > this.pendingFinalSequence) {
      this.staleGenerationDropped += 1
      this.log('stale_generation_dropped', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        reason: 'past_pending_final_sequence',
        sequence: event.sequence, pending_final_sequence: this.pendingFinalSequence,
        total_dropped: this.staleGenerationDropped,
      })
      return
    }
    if (this.seenDownlinkSequences.has(event.sequence)) {
      this.log('duplicate_sequence', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        response_id: this.responseId, sequence: event.sequence,
      })
      return
    }
    // Total budget for this session, charged only for frames actually
    // retained and forwarded (duplicates above cost neither memory nor
    // socket buffer, so they must not burn the budget either).
    const frameBytes = typeof event.audio === 'string' ? event.audio.length : 0
    if (this.seenDownlinkSequences.size >= this.maxDownlinkFrames
      || this.downlinkBytes + frameBytes > this.maxDownlinkBytes) {
      return this._failDownlinkBudget('session_budget_exhausted', {
        sequence: event.sequence,
        frames: this.seenDownlinkSequences.size, frames_cap: this.maxDownlinkFrames,
        bytes: this.downlinkBytes + frameBytes, bytes_cap: this.maxDownlinkBytes,
      })
    }
    this.downlinkBytes += frameBytes
    this.seenDownlinkSequences.add(event.sequence)
    if (event.sequence > this.downlinkHighWatermark) {
      this.downlinkHighWatermark = event.sequence
    }
    if (this.firstDownlinkAt === null) {
      this.firstDownlinkAt = this.now()
      const pcm = pcm16Level(decodeAudio(event.audio))
      this.log('downlink_first_frame', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        response_id: this.responseId, sequence: event.sequence,
      })
      if (pcm) {
        // ESS-891: comparable to the Watch's `downlink_pcm_level` — the
        // Gateway-side half of the source-vs-player RMS comparison.
        this.log('downlink_pcm_level', {
          request_id: this.scope.request_id, session_id: this.scope.session_id,
          generation: this.scope.generation,
          response_id: this.responseId, sequence: event.sequence,
          ...pcm,
        })
      }
    }
    if (this.expectSegmentFirstFrame) {
      // ESS-1071: first audio frame of a follow-on segment. The first segment's
      // first frame is `downlink_first_frame`; this is the per-segment marker
      // that lets the observability collector measure `segment_to_first_audio_ms`.
      this.expectSegmentFirstFrame = false
      this.log('segment_first_frame', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        response_id: this.responseId, sequence: event.sequence,
        segment_index: this.segmentsEmitted - 1,
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
    // A backfilled hole may have completed the dense prefix; check whether
    // an upstream `audio.done` we've been holding can now be released.
    this._maybeReleaseSegmentDone()
    this._maybeReleaseDone()
  }

  // ESS-969: one segment of a multi-segment turn ended. This is NOT the turn
  // terminal — `doneEmitted` stays false and the next segment's deltas keep
  // flowing, which is precisely the drop this issue exists to remove. The
  // client reads it as「这一段完了，回合没完」and can hold its turn open
  // (Watch: `SessionController.markAnswerInterim`) instead of guessing.
  _emitSegmentDone(event) {
    if (this.doneEmitted) {
      // The turn already ended downstream; a segment boundary after it is the
      // upstream contradicting its own terminal. Counted, not forwarded.
      this.log('segment_done_after_turn_done', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        response_id: this.responseId, segment_index: event.segment_index ?? null,
      })
      return
    }
    const claimed = Number.isInteger(event.final_sequence)
      ? event.final_sequence
      : this.downlinkHighWatermark
    // An empty segment carries no barrier to wait for and nothing for the
    // client to have played; forwarding it would only produce a boundary
    // around silence.
    if (claimed < 0) return
    if (claimed >= this.maxDownlinkFrames) {
      return this._failDownlinkBudget('segment_final_sequence_out_of_window', {
        claimed_final_sequence: claimed, frames_cap: this.maxDownlinkFrames,
      })
    }
    this.pendingSegmentDone = {
      segment_index: Number.isInteger(event.segment_index) ? event.segment_index : this.segmentsEmitted,
      final_sequence: claimed,
    }
    this.log('segment_done_pending', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation,
      response_id: this.responseId,
      segment_index: this.pendingSegmentDone.segment_index,
      segment_final_sequence: claimed,
      dense_prefix: this._highestDensePrefix(),
    })
    this._maybeReleaseSegmentDone()
  }

  // Release a held segment boundary once every 0..final_sequence delta has
  // gone downstream. No timer of its own: a segment whose prefix never
  // completes is a hole in the turn, and the turn barrier's existing gap
  // timer is the thing that fails it closed.
  _maybeReleaseSegmentDone() {
    const pending = this.pendingSegmentDone
    if (!pending || this.doneEmitted) return
    if (this._highestDensePrefix() < pending.final_sequence) return
    this.pendingSegmentDone = null
    this.segmentsEmitted += 1
    this._sendJson({
      type: 'audio.segment_done',
      session_id: this.scope.session_id, request_id: this.scope.request_id,
      response_id: this.responseId, generation: this.scope.generation,
      segment_index: pending.segment_index,
      final_sequence: pending.final_sequence,
    })
    this.log('downlink_segment_done', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation,
      response_id: this.responseId,
      segment_index: pending.segment_index,
      segment_final_sequence: pending.final_sequence,
    })
    this.expectSegmentFirstFrame = true
  }

  _emitDone(event) {
    if (this.doneEmitted) return
    // ESS-388 §"强制契约": save the upstream `final_sequence` verbatim as
    // the pending barrier and hold `audio.done` until every 0..N delta has
    // been emitted downstream. Never rewrite the barrier; never emit done
    // before it (毕玄 review on PR #159 — the old clamp let a hole like
    // {0, 2, done(2)} slip through as done(0) and the client would then
    // silently lose seq=1 when it arrived late).
    const claimed = Number.isInteger(event.final_sequence)
      ? event.final_sequence
      : this.downlinkHighWatermark
    // ESS-1145: 终态**原因**只进日志，不上线格——客户端的 `audio.done` 契约
    // 一个字都没变。有了它，一条真机日志就能分清「答案交付完才收口」
    // (`task_terminal_audio_done`) 与「取消 / 失败」，不必再去比对上游时间戳。
    if (typeof event.reason === 'string' && event.reason) this.doneReason = event.reason
    // A barrier outside the sequence window can never be satisfied — waiting
    // for it would only burn the full gap timeout before failing anyway.
    if (claimed >= this.maxDownlinkFrames) {
      return this._failDownlinkBudget('final_sequence_out_of_window', {
        claimed_final_sequence: claimed, frames_cap: this.maxDownlinkFrames,
      })
    }
    if (this.pendingFinalSequence === null) {
      this.pendingFinalSequence = claimed
      this.log('done_barrier_pending', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        response_id: this.responseId,
        pending_final_sequence: claimed,
        high_watermark: this.downlinkHighWatermark,
        missing: this._missingBelow(claimed),
      })
    } else if (claimed !== this.pendingFinalSequence) {
      // Upstream re-emitted done with a different final_sequence — a
      // protocol violation. Keep the first one we saw (already committed)
      // and log the divergence for post-hoc reconciliation.
      this.log('done_barrier_conflicting_final_sequence', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        response_id: this.responseId,
        pending_final_sequence: this.pendingFinalSequence,
        rejected_final_sequence: claimed,
      })
    }
    this._maybeReleaseDone()
  }

  // Release the held `audio.done` if the dense prefix has caught up to the
  // upstream-claimed `pendingFinalSequence`. Idempotent: only fires once,
  // always with the original `pendingFinalSequence`.
  _maybeReleaseDone() {
    if (this.doneEmitted) return
    if (this.pendingFinalSequence === null) return
    const target = this.pendingFinalSequence
    // A negative claim (e.g. -1) is only a proven empty response after its
    // bounded observation window.  Positive barriers retain their original
    // dense-prefix semantics and are never rewritten.
    if ((target < 0 && this._emptyDoneWindowElapsed)
      || (target >= 0 && this._highestDensePrefix() >= target)) {
      this._clearBarrierTimer()
      this.finalSequence = target
      this.doneEmitted = true
      // ESS-969: a boundary that only becomes releasable at the same instant
      // as the turn terminal carries no information — the turn end already
      // says everything it would have said. Drop it rather than make the
      // client flip to「等下一段」and back within one frame.
      this.pendingSegmentDone = null
      this._sendJson({
        type: 'audio.done',
        session_id: this.scope.session_id, request_id: this.scope.request_id,
        response_id: this.responseId, generation: this.scope.generation,
        final_sequence: this.finalSequence,
      })
      this.log('downlink_done', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        response_id: this.responseId, final_sequence: this.finalSequence,
        reason: this.doneReason ?? null,
      })
      return
    }
    // Still waiting for holes to be backfilled — arm the gap timer once.
    this._armBarrierTimer()
  }

  // Terminal, non-retriable: the upstream has already produced more than one
  // turn can legally contain, so retrying the same turn would reproduce it.
  _failDownlinkBudget(reason, extra) {
    this.log('downlink_budget_exceeded', {
      request_id: this.scope.request_id, session_id: this.scope.session_id,
      generation: this.scope.generation,
      response_id: this.responseId, reason, ...extra,
    })
    this.fail('ERR_DOWNLINK_BUDGET', { detail: reason, retriable: false, ...extra })
  }

  _armBarrierTimer() {
    if (this._barrierTimer !== null) return
    if (this.doneBarrierGapMs <= 0) return
    this._barrierTimer = this.setTimer(() => {
      this._barrierTimer = null
      if (this.state !== OPEN) return
      if (this.doneEmitted || this.cancelled) return
      if (this.pendingFinalSequence === null) return
      if (this.pendingFinalSequence < 0) {
        this._emptyDoneWindowElapsed = true
        this.log('empty_done_window_elapsed', {
          request_id: this.scope.request_id, session_id: this.scope.session_id,
          generation: this.scope.generation,
          response_id: this.responseId,
          pending_final_sequence: this.pendingFinalSequence,
        })
        this._maybeReleaseDone()
        return
      }
      // Structured fail-closed: single event, no forged smaller endpoint,
      // no double execution. Client falls back per turn to the legacy path.
      this.log('done_barrier_gap_timeout', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
        response_id: this.responseId,
        pending_final_sequence: this.pendingFinalSequence,
        dense_prefix: this._highestDensePrefix(),
        high_watermark: this.downlinkHighWatermark,
        missing: this._missingBelow(this.pendingFinalSequence),
      })
      this.fail('ERR_STREAM_GAP_TIMEOUT', {
        pending_final_sequence: this.pendingFinalSequence,
        dense_prefix: this._highestDensePrefix(),
        retriable: false,
      })
    }, this.doneBarrierGapMs)
    // The socket/session owns this watchdog's lifecycle. It must not keep the
    // process alive after explicit session teardown while Node retires a
    // cleared Timeout resource on a later loop turn.
    this._barrierTimer.unref?.()
  }

  _clearBarrierTimer() {
    if (this._barrierTimer !== null) {
      this.clearTimer(this._barrierTimer)
      this._barrierTimer = null
    }
  }

  // Largest N such that every 0..N is in `seenDownlinkSequences`; -1 if
  // even seq=0 is missing. Small integer scan is fine — a realtime
  // response is bounded to O(hundreds) of deltas.
  _highestDensePrefix() {
    let n = -1
    while (this.seenDownlinkSequences.has(n + 1)) n += 1
    return n
  }

  _missingBelow(target) {
    const missing = []
    for (let s = 0; s <= target && missing.length < 16; s++) {
      if (!this.seenDownlinkSequences.has(s)) missing.push(s)
    }
    return missing
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
    // Terminate synchronously so no further agent events squeak through
    // between now and when the transport's real close callback fires.
    // `onSocketClose` is idempotent (`state === CLOSED` early-return).
    this.onSocketClose(1008, code)
  }

  _gracefulClose(reason) {
    this.closeSocket(1000, typeof reason === 'string' ? reason.slice(0, 120) : 'client_close')
  }

  _sendJson(obj) {
    try { this.send(JSON.stringify(obj)) }
    catch (error) {
      this.log('send_failed', {
        request_id: this.scope.request_id, session_id: this.scope.session_id,
        generation: this.scope.generation,
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
        generation: this.scope.generation,
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
        generation: this.scope.generation,
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
        generation: this.scope.generation,
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

// ESS-891: PCM16 level metering for the low-volume diagnosis. Mirrors the
// Watch-side `PCM16LevelMeter` math so `downlink_pcm_level` is directly
// comparable across Gateway and Watch logs.
export function pcm16Level(buf) {
  const sampleCount = Math.floor(buf.length / 2)
  if (sampleCount <= 0) return null
  let sumSquares = 0
  let peak = 0
  for (let i = 0; i < sampleCount; i++) {
    const s = buf.readInt16LE(i * 2)
    sumSquares += s * s
    const a = Math.abs(s)
    if (a > peak) peak = a
  }
  const rms = Math.sqrt(sumSquares / sampleCount)
  const round2 = v => (Number.isFinite(v) ? Math.round(v * 100) / 100 : v)
  return {
    rms: round2(rms),
    peak,
    rms_dbfs: round2(rms > 0 ? 20 * Math.log10(rms / 32768) : -Infinity),
    peak_dbfs: round2(peak > 0 ? 20 * Math.log10(peak / 32768) : -Infinity),
    frames: sampleCount,
  }
}
