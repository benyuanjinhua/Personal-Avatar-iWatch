import WebSocket from 'ws'
import { createHash, randomUUID } from 'node:crypto'

import { projectStreamProgress, projectTaskProgress } from './task-progress.mjs'

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

// ESS-990 upstream task lifecycle. `task.completed` / `.failed` / `.cancelled`
// are the terminal events in the upstream's own enum (`GatewayTaskEvent` in
// `shared/realtime-events.mjs`); `task.progress.check` /
// `.notification.pending` / `.notification.delivered` / `.permission.*` are
// notifications ABOUT a task, not a change of its lifecycle state.
const TASK_TERMINAL_EVENTS = new Set(['task.completed', 'task.failed', 'task.cancelled'])
const TASK_TERMINAL_STATUSES = new Set(['completed', 'failed', 'cancelled'])
const TASK_NON_LIFECYCLE_EVENTS = new Set([
  'task.progress.check', 'task.notification.pending', 'task.notification.delivered',
  'task.notification.offline', 'task.permission.requested', 'task.permission.resolved',
  'task.snapshot',
])
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/

// ESS-1068: bound on the per-conversation task identity / delivered tables.
// A conversation's background tasks are a small working set (measured n=10
// turns produced at most a couple of tasks each); the cap is a memory backstop
// against a misbehaving upstream, trimming the OLDEST entry (a long-finished
// task no longer needs attribution).
const MAX_TASKS_PER_CONVERSATION = 256

// ESS-849: cap on the per-turn responseId → announcement book-keeping. A turn
// lives seconds and the biggest real capture held 2 announcements, so this is a
// memory backstop against a misbehaving upstream, not a functional limit —
// trimming the OLDEST entry is safe because a long-finished announcement can no
// longer produce frames, while a live one is always among the newest.
const MAX_ANNOUNCEMENT_RESPONSES = 64

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
    // ESS-969 multi-segment turns. Upstream `audio.done` is a SEGMENT
    // boundary, not the end of the turn: in a tool-calling turn the model
    // says 「我正在查询…」, closes that response, runs the tool, then opens a
    // second response with the real answer. Treating the first `audio.done`
    // as terminal is what made the second segment unreachable.
    //
    // ESS-990 取证结果：上游**没有**回合终态信号。#365 曾把
    // `voice.state {state:'idle'}` 当作终态，实测已推翻：
    //   • L1（2026-08-22、真实上游 `ws://127.0.0.1:3101/api/realtime`、
    //     10 个工具调用回合）—— idle 在**每一段** `audio.done` 后
    //     0.14–0.54 ms 内到达，且 10/10 的回合在首条 idle 之后又开了新段。
    //     按 #365 的规则，每个工具调用回合都会在第 1 段就收口。
    //   • L2：上游 `server/src/voice/realtime-gateway.mjs` 在 `finishPlayback` /
    //     `cancelPlayback`（每个 response 播放结束）与 `response.done`
    //     （无音频时）发 idle——它是**段落级播放状态**，不是回合终态；
    //     `shared/realtime-events.mjs` 的 `GatewayServerEvent` 有 `turn.started`，
    //     没有任何 turn 终态事件。
    // 所以这里只能用「段落收口后的有界空闲窗口」（R-04.4 启发式），
    // 并把 idle 降级为方言指纹：`'auto'` 仍然只对「说过 voice.state」的
    // 上游启用分段路径，其它上游逐字节保持 ESS-969 之前的行为。
    multiSegmentMode = 'auto',
    // ESS-990 已标定，替换 ESS-969 的 `turnIdleBackstopMs = 45_000` 占位值。
    // 一个已收口的段落要等多久才能判定「回合真的完了」。
    // 样本：2026-08-22 真实上游 10 个工具调用回合、n=17 个回合内段落间隔
    // （`audio.done` → 下一条非播报 `response.started`）：
    //   min 326.6 / p50 1171.2 / p90 4143.4 / max 7332.5 ms。
    // 其中所有 > 1194.7 ms 的间隔（n=6）都伴有「上游声道忙着别的事」的显式
    // 证据（后台播报开始 / task 事件），所以分两档：
    //   • `segmentGapMs`（基础）盖住无证据时的最大间隔 1194.7 ms，取 2.5 s ≈ 2.1x；
    //   • `segmentGapBusyMs`（延长）盖住全部实测间隔 7332.5 ms，取 12 s ≈ 1.6x。
    // 生产侧交叉验证（`Services/.../logs/gateway.log`，2026-08-22）：
    // `upstream_segment_closed` → 下一条 `upstream_response_started` 共 8 例，
    // 其中 **7 例中间夹着 `uplink_committed`** —— 那是用户又说了一句，后面的
    // response 回答的是新话，不是工具调用的第二段，不能当段间隔用（PR #377
    // 把这 7 例的 ~15 s 当成「段间隔下界」，据此的下界主张不成立）。
    // 唯一一例干净的同一句续段是 363 ms，与下面这组采样一致。
    //
    // 采样口径（必须连着结论一起读）：取证脚本按 Bridge 的方言回了
    // `playback.started` / `playback.ended` 回执，而本适配器**不回回执**
    // （见下方 idle 那段），上游据此决定何时开下一段，所以真机 Watch 链路上的
    // 间隔分布可能与这 17 个样本不同——两个值因此都是配置项，并由
    // `upstream_turn_terminal` 的 `gap_ms` / `window_ms` / `outstanding_tasks`
    // 继续累积（R-04.4，n=17 仍是薄样本，且取自一台机器、任务队列较忙的时段）。
    //
    // 上界参考 ESS-1004 实测的两条时间线（不是「两个 45 s 相等」——那个因果
    // 已被 ESS-1004 复审推翻并撤回）：段落收口时本窗口起表，客户端
    // `SessionController.thinkingHardTimeoutSeconds = 45` 要等到收到 interim
    // 才起表，因此本窗口天然早于客户端。12 s 距客户端预算仍有充足余量。
    segmentGapMs = 2_500,
    segmentGapBusyMs = 12_000,
    // ESS-1043 tool-call window. qwen `response.done` carries `hasFunctionCall`:
    // when true, the model has decided to call a tool and the real answer
    // segment only arrives after the tool runs (measured 8–16 s — well past
    // both segment-gap windows above). A pending tool call therefore arms this
    // dedicated window instead of letting the ordinary idle window close the
    // turn while the tool is still in flight. 30 s ≈ 1.9x the 16 s maximum,
    // and still ends before the Watch's own 45 s hard thinking timeout, so a
    // lost tool result cannot hold the turn open past the client budget.
    toolCallWindowMs = 30_000,
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
    this.multiSegmentMode = multiSegmentMode
    this.segmentGapMs = segmentGapMs
    this.segmentGapBusyMs = segmentGapBusyMs
    this.toolCallWindowMs = toolCallWindowMs
    this.takeover = takeover
    this.clientLabel = clientLabel
    this.log = log
    this.turns = new Map()
    // ESS-974: an upstream supersede can produce a delayed ownership broadcast
    // after the replacement socket is already active. Remember the exact
    // retired instance identities so that broadcast cannot fence its successor.
    // The queue bounds process-lifetime memory without relying on timers.
    this.retiredClientInstanceIds = new Set()
    this.retiredClientInstanceOrder = []
    // ESS-1068: cross-turn task book-keeping, keyed by conversation (device +
    // session) so a background task spawned by a closed turn can still have its
    // result attributed and consumed-once on a LATER turn of the same
    // conversation. Per-turn state alone loses the taskId→identity mapping when
    // the acceptance turn closes before the task terminal (measured 30–70 s).
    // Bounded per conversation to keep process-lifetime memory flat.
    this.conversationTaskIdentity = new Map() // conversationKey → Map<taskId, identity>
    this.conversationDelivered = new Map()    // conversationKey → Set<taskId>
  }

  // ESS-1068: shared per-conversation task identity / delivered dedup tables,
  // created lazily and bounded (oldest conversation evicted on overflow).
  #conversationTaskTables(conversation) {
    let identity = this.conversationTaskIdentity.get(conversation)
    if (!identity) {
      identity = new Map()
      this.conversationTaskIdentity.set(conversation, identity)
      while (this.conversationTaskIdentity.size > 256) {
        this.conversationTaskIdentity.delete(this.conversationTaskIdentity.keys().next().value)
      }
    }
    let delivered = this.conversationDelivered.get(conversation)
    if (!delivered) {
      delivered = new Set()
      this.conversationDelivered.set(conversation, delivered)
      while (this.conversationDelivered.size > 256) {
        this.conversationDelivered.delete(this.conversationDelivered.keys().next().value)
      }
    }
    return { identity, delivered }
  }

  #retireClientInstance(clientInstanceId) {
    if (this.retiredClientInstanceIds.has(clientInstanceId)) return
    this.retiredClientInstanceIds.add(clientInstanceId)
    this.retiredClientInstanceOrder.push(clientInstanceId)
    while (this.retiredClientInstanceOrder.length > 64) {
      this.retiredClientInstanceIds.delete(this.retiredClientInstanceOrder.shift())
    }
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

  // ESS-1068: attribute a background announcement to THIS turn's conversation.
  // A background task result (origin=announcement) belongs to the same user/device
  // as this turn, not to whoever happens to share the WSS. Attribution is
  // decided by the task's session/device identity, read in this order:
  //   1. the announcement's own `task` object / top-level sessionId/deviceId;
  //   2. the taskId → identity table built from `task.*` events on this turn.
  // No identity evidence ⇒ unattributed ⇒ isolated (the ESS-849 safe default),
  // because a cross-session broadcast must never be spoken as this user's answer.
  #attributeAnnouncement(turn, event, taskKey) {
    const task = event.task ?? {}
    const sessionId = event.sessionId ?? task.sessionId ?? null
    const deviceId = event.deviceId ?? task.deviceId ?? null
    if (sessionId != null || deviceId != null) {
      if (sessionId != null && String(sessionId) !== String(turn.sessionId)) return false
      // ESS-1068 复审第2点（fail-closed）：当 turn 有 device 身份时，
      // announcement 必须提供匹配的 deviceId 才能归属；缺 deviceId 的
      // 广播不能靠 sessionId 单边放行——两个设备共享一个 sessionId 时会
      // 双双接受同一广播。
      if (turn.deviceId != null) {
        if (deviceId == null) return false
        if (String(deviceId) !== String(turn.deviceId)) return false
      }
      return true
    }
    if (taskKey != null) {
      const identity = turn.taskIdentity.get(taskKey)
      if (identity) {
        if (identity.sessionId != null && String(identity.sessionId) !== String(turn.sessionId)) return false
        if (turn.deviceId != null) {
          if (identity.deviceId == null) return false
          if (String(identity.deviceId) !== String(turn.deviceId)) return false
        }
        return true
      }
    }
    return false
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
    const blockingTurn = [...this.turns.values()].find(prior =>
      prior.conversation === conversation && prior.toolGateActive?.())
    if (blockingTurn) {
      this.log('upstream_supersede_decision', {
        request_id: requestId, session_id: sessionId, device_id: deviceId, generation,
        decision: 'rejected_tool_turn_active',
        blocking_request_id: blockingTurn.requestId,
        blocking_generation: blockingTurn.generation,
        outstanding_tasks: blockingTurn.outstandingTasks.size,
        tool_call_pending: blockingTurn.pendingToolCall,
      })
      queueMicrotask(() => onEvent({
        type: 'agent.error', response_id: responseId, code: 'ERR_TURN_BUSY',
        detail: 'a tool turn is still active for this conversation', retriable: true,
      }))
      return {
        appendAudio: () => {}, commit: () => {}, cancel: () => {}, close: () => {},
        playbackStarted: () => {}, playbackEnded: () => {},
      }
    }
    for (const prior of this.turns.values()) {
      if (prior.conversation === conversation) {
        this.log('upstream_supersede_decision', {
          request_id: requestId, session_id: sessionId, device_id: deviceId, generation,
          decision: 'supersede', blocking_request_id: prior.requestId,
          blocking_generation: prior.generation,
        })
        prior.supersede?.(requestId)
      }
    }
    const upstreamSessionId = `watch-direct-${sessionId}-${generation}`
    const url = new URL(this.gatewayUrl)
    url.searchParams.set('sessionId', upstreamSessionId)
    // ESS-842: our own client identity on the upstream, kept on the turn so an
    // ownership event can be compared against it. The upstream reports the
    // holder of the single voice slot; without knowing who WE are, a `busy`
    // frame cannot be told apart from an echo of our own ownership.
    const clientInstanceId = `gateway_${randomUUID()}`
    // ESS-1068: task identity and delivered dedup are per-CONVERSATION, not
    // per-turn — a background task spawned by a closed turn still resolves on
    // a later turn of the same conversation.
    const taskTables = this.#conversationTaskTables(conversation)
    const turn = {
      key, conversation,
      requestId, sessionId, deviceId, generation, responseId, onEvent,
      taskIdentity: taskTables.identity,
      deliveredAnnouncements: taskTables.delivered,
      ws: null, ready: false, terminal: false, committed: false,
      pending: [], pendingBytes: 0, nextOutputSequence: 0,
      downlinkFrames: 0, downlinkBytes: 0,
      connectTimer: null,
      doneTimer: null, pendingDone: false, recentUpstreamFrames: new Map(),
      expectedUpstream: 0, anchored: false, reorderBuffer: new Map(), gapTimer: null,
      clientInstanceId, ownershipState: null, ownershipHolderLabel: null,
      ownershipHolderInstanceId: null, takeoverAttempted: false,
      responseTimer: null, responded: false, commitSentAt: null,
      taskTerminalTimer: null, toolAudioTimer: null,
      // ESS-969 segment book-keeping. `closedSegment` holds a segment whose
      // `audio.done` has settled but whose meaning is not decided yet: it is
      // a SEGMENT boundary if the turn goes on to produce more, and the TURN
      // boundary if it does not (ESS-990: decided by the idle window below,
      // NOT by `voice.state idle`). Deferring the choice is what keeps a plain
      // one-segment turn from emitting a spurious interim.
      segmentIndex: 0, closedSegment: null, segmentsClosed: 0,
      sawVoiceState: false, multiSegment: null,
      turnEnded: false,
      // ESS-990: the parked segment's idle window. `segmentGapTimer` is the
      // ONLY thing that can turn a closed segment into a turn terminal now
      // (besides the unambiguous ones: a new segment, socket close, error,
      // supersede). `segmentGapWindowMs` records which of the two calibrated
      // windows is armed so a late piece of evidence can widen it once.
      segmentGapTimer: null, segmentGapWindowMs: 0, segmentClosedAt: 0,
      // ESS-990 corroborating signals (`outstandingTasks` first added by
      // ESS-1004 as evidence-only). Neither can decide the terminal on its
      // own (see `noteTurnBusy`), they only widen the window.
      outstandingTasks: new Set(), announcementResponseIds: new Set(),
      turnBusy: false,
      // ESS-1111: 最近一次**上游任务活动**的时刻（生命周期帧、进展帧、答案
      // 增量帧都算）。ESS-1109 的验收把「不得按固定 12 s / 30 s 退出」写成了
      // 硬约束：一个 24 s 的 Codex 任务每秒都在报进展，却因为窗口从段落收口
      // 那一刻起表而被判成「没动静」。有了这条时间戳，两个窗口量的都是
      // **静默时长**而不是总时长——任务还在说话就不收口，任务真的哑了才收。
      lastTaskActivityAt: 0,
      // ESS-1068: `activeAnnouncements` tracks announcement responses that
      // have started but not finished — they are the busy cause that must be
      // cleared when the announcement ends. `taskIdentity` maps a taskId to
      // its source session/device (built from `task.*` events) so a background
      // announcement can be attributed to this conversation instead of being
      // isolated as a cross-session leak. `deliveredAnnouncements` is the
      // exactly-once book-keeping keyed by taskId; `deliverAnnouncementIds`
      // marks the responseIds whose audio/transcript is attributed and must
      // be forwarded rather than dropped.
      activeAnnouncements: new Set(),
      // ESS-1107: stale/unattributed announcements may be replayed as soon as
      // a fresh Watch socket opens. They are not a busy cause for this turn;
      // retain their ids only long enough to acknowledge and preempt them.
      isolatedAnnouncements: new Set(),
      preemptedAnnouncements: new Set(),
      deliverAnnouncementIds: new Set(),
      // ESS-1068 复审第3点：`deliveredAnnouncements` 是「已完整下发并消费」
      // 的 dedup，只能在 audio.done 完整下发后记录，不能在 response.started
      // 就记——否则 disconnect/cancel/截断会永久抑制后续 turn 的重投。
      // 本映射记录 responseId → taskKey 的待交付关系，response.started 入，
      // audio.done 下发后转 delivered 并出。
      pendingAnnouncementTaskIds: new Map(),
      // ESS-849 announcement isolation book-keeping. `announcementDropped`
      // counts what the voice channel threw away per announcement response;
      // `forwardedResponseIds` is what makes a 「先 delta 后 started」 leak
      // visible instead of silent (see `announcementResponseIdOf`).
      announcementDropped: new Map(), forwardedResponseIds: new Set(),
      // ESS-1043: qwen `response.done` carries `hasFunctionCall`. When true,
      // the model has decided to call a tool and at least one more response
      // segment (the tool result) is coming — the ordinary segment-gap window
      // must not end the turn while the tool runs. When the final segment's
      // `response.done` (hasFunctionCall=false) lands after a pending tool
      // call, `endAfterDone` marks it so `flushDone` ends the turn as soon as
      // that segment's audio settles instead of waiting out the idle window.
      pendingToolCall: false, endAfterDone: false,
      pendingToolTerminal: null, awaitingToolAudioTerminal: false,
    }
    turn.toolGateActive = () => !turn.terminal && !turn.turnEnded
      && (turn.pendingToolCall || turn.outstandingTasks.size > 0
        || turn.pendingToolTerminal !== null || turn.awaitingToolAudioTerminal)
    const scopeLog = { request_id: requestId, session_id: sessionId, device_id: deviceId, generation }
    turn.supersede = nextRequestId => {
      if (turn.terminal) return
      turn.terminal = true
      this.#retireClientInstance(turn.clientInstanceId)
      clearTimeout(turn.connectTimer)
      clearTimeout(turn.doneTimer)
      clearTimeout(turn.gapTimer)
      clearTimeout(turn.responseTimer)
      clearTimeout(turn.segmentGapTimer)
      clearTimeout(turn.taskTerminalTimer)
      clearTimeout(turn.toolAudioTimer)
      this.log('upstream_turn_superseded', {
        ...scopeLog, superseded_by_request_id: nextRequestId,
      })
      if (turn.ws?.readyState === WebSocket.OPEN) {
        // qwen-audio-agent's client-facing realtime contract calls this
        // `interrupt`. `response.cancel` is the provider-facing OpenAI frame
        // and is intentionally not accepted by the gateway websocket. Sending
        // it here used to be a silent no-op: the old tool turn survived a
        // barge-in and could race the replacement turn with late task/audio
        // events.
        try { turn.ws.send(JSON.stringify({ type: 'interrupt' })) } catch { /* closing */ }
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
      clearTimeout(turn.segmentGapTimer)
      clearTimeout(turn.taskTerminalTimer)
      clearTimeout(turn.toolAudioTimer)
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
      // A frame observed before THIS turn's audio.commit cannot satisfy THIS
      // turn's response deadline. Persisted startup announcements used to set
      // `responded=true` here and silently disabled the fail-closed timeout.
      if (!turn.committed || turn.commitSentAt === null) {
        this.log('upstream_precommit_response_ignored', scopeLog)
        return
      }
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
    //
    // ESS-969 makes the *meaning* of that settled done conditional. An
    // upstream `audio.done` closes one RESPONSE; whether that is also the end
    // of the turn is decided by what happens next:
    //   • more output (`response.started` / a new delta)   → `agent.audio.segment_done`
    //     for the segment that just closed, and the turn continues
    //   • nothing for a bounded window (ESS-990)           → `agent.audio.done`
    // so the closed segment is PARKED in `turn.closedSegment` until one of
    // those happens. Parking is what stops a plain one-segment turn from ever
    // emitting a spurious segment boundary. ESS-990 removed `voice.state idle`
    // from this decision entirely — it fires after EVERY segment (10/10 real
    // turns), so it carries no information about the turn being over.
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
      if (turn.multiSegment === null) {
        turn.multiSegment = this.multiSegmentMode === 'always' ? true
          : this.multiSegmentMode === 'off' ? false
          : turn.sawVoiceState
        // The single line that tells a real-device log which branch this
        // build actually took. `legacy` means the upstream never announced
        // `voice.state`, so the multi-segment path was NOT exercised — read
        // it before concluding anything about the fix.
        this.log('upstream_turn_terminal_mode', {
          ...scopeLog,
          mode: turn.multiSegment ? 'multi_segment' : 'legacy',
          configured: this.multiSegmentMode,
          saw_voice_state: turn.sawVoiceState,
        })
      }
      if (!turn.multiSegment) return endTurn('legacy_first_done', finalSequence)
      // ESS-1043: the final segment of a tool-call turn (`response.done`
      // hasFunctionCall=false after a pending tool call) ends the turn the
      // moment its audio settles. The settled segment below is the endpoint,
      // not another segment boundary to park and idle-window.
      if (turn.endAfterDone) {
        turn.endAfterDone = false
        turn.segmentsClosed += 1
        return endTurn('tool_result_done', finalSequence)
      }
      turn.closedSegment = { segmentIndex: turn.segmentIndex, finalSequence }
      turn.segmentsClosed += 1
      this.log('upstream_segment_closed', {
        ...scopeLog, segment_index: turn.segmentIndex, final_sequence: finalSequence,
      })
      // The window starts when the segment CLOSES (after the reorder hole is
      // filled and the settle window expires), so a healthy turn whose tail
      // delta merely arrived late is not penalised — that was ESS-969 B1
      // (毕玄 review on PR #365), and it no longer needs a latch because the
      // terminal is no longer an instantaneous upstream event.
      turn.segmentClosedAt = Date.now()
      armSegmentGap('segment_closed')
    }

    // The turn produced more output after a segment closed: that closed
    // segment was a boundary, not the end. Release it downstream before the
    // new segment's frames so the client sees them in order.
    const armToolAudioTimer = cause => {
      if (turn.turnEnded || !turn.awaitingToolAudioTerminal) return
      clearTimeout(turn.toolAudioTimer)
      if (this.toolCallWindowMs > 0) {
        this.log('upstream_tool_audio_terminal_window_armed', {
          ...scopeLog, cause, timeout_ms: this.toolCallWindowMs,
          final_sequence: turn.nextOutputSequence - 1,
        })
        turn.toolAudioTimer = setTimeout(() => {
          turn.toolAudioTimer = null
          if (turn.turnEnded || !turn.awaitingToolAudioTerminal) return
          this.log('upstream_tool_audio_terminal_timeout', {
            ...scopeLog, timeout_ms: this.toolCallWindowMs,
            final_sequence: turn.nextOutputSequence - 1,
          })
          fail('ERR_UPSTREAM_TOOL_AUDIO_TIMEOUT',
            `tool output did not reach audio.done within ${this.toolCallWindowMs}ms`)
        }, this.toolCallWindowMs)
        turn.toolAudioTimer.unref?.()
      }
    }

    const invalidateDeferredTerminal = cause => {
      if (turn.pendingToolTerminal) {
        const stale = turn.pendingToolTerminal
        turn.pendingToolTerminal = null
        turn.awaitingToolAudioTerminal = true
        clearTimeout(turn.taskTerminalTimer)
        turn.taskTerminalTimer = null
        this.log('upstream_turn_terminal_invalidated', {
          ...scopeLog, cause, stale_final_sequence: stale.finalSequence,
          current_final_sequence: turn.nextOutputSequence - 1,
          ui_state: 'thinking', turn_state: 'busy',
        })
      }
      // This is a silence watchdog, not a cap on total answer duration. Every
      // accepted response-start or audio frame proves the upstream is healthy,
      // so renew the window until the fresh audio.done arrives.
      armToolAudioTimer(cause)
    }

    const releaseClosedSegment = cause => {
      invalidateDeferredTerminal(cause)
      const closed = turn.closedSegment
      if (!closed) return
      turn.closedSegment = null
      turn.segmentIndex += 1
      clearTimeout(turn.segmentGapTimer)
      turn.segmentGapTimer = null
      turn.segmentGapWindowMs = 0
      this.log('upstream_segment_done', {
        ...scopeLog, segment_index: closed.segmentIndex,
        final_sequence: closed.finalSequence, cause,
      })
      onEvent({
        type: 'agent.audio.segment_done', response_id: responseId,
        segment_index: closed.segmentIndex, final_sequence: closed.finalSequence,
      })
    }

    // ESS-1097 的「任务在飞，终态先挂起」兜底窗口，ESS-1111 把它从**一次性
    // 总预算**改成**静默预算**：每收到一帧真实的上游任务活动就重新起表。
    //
    // 为什么必须改：原来的写法是 `if (!turn.taskTerminalTimer)` ——第一次挂起
    // 时武装 30 s，之后无论上游报多少进展都不顺延。ESS-1109 的真机取证里
    // Codex 任务跑 24 s、每秒都有 `task.running`，首个有内容的进展在 9.48 s，
    // 而窗口早在第一次挂起时就开始烧；任务越长越容易在**明明还在推进**的时候
    // 被判成超时。静默预算量的是「上游多久没说话」，这才是这条兜底真正想防的
    // 失败面（上游任务事件整段丢失 ⇒ 回合永远收不了口）。
    //
    // 上限没有消失，只是换了位置：客户端仍有 `SessionController.
    // toolTurnHardTimeoutSeconds = 180` 这条一轮只武装一次的绝对上限，
    // 所以「续期」在任何情况下都不会变成「永久锁死」。
    const armTaskTerminalTimer = cause => {
      if (turn.turnEnded || !turn.pendingToolTerminal) return
      if (!(this.toolCallWindowMs > 0)) return
      clearTimeout(turn.taskTerminalTimer)
      this.log('upstream_task_terminal_window_armed', {
        ...scopeLog, cause, timeout_ms: this.toolCallWindowMs,
        outstanding_tasks: turn.outstandingTasks.size,
        task_id: turn.outstandingTasks.values().next().value ?? null,
      })
      turn.taskTerminalTimer = setTimeout(() => {
        turn.taskTerminalTimer = null
        if (turn.turnEnded || !turn.pendingToolTerminal) return
        this.log('upstream_task_terminal_timeout', {
          ...scopeLog, task_id: turn.outstandingTasks.values().next().value ?? null,
          outstanding_tasks: turn.outstandingTasks.size,
          timeout_ms: this.toolCallWindowMs,
          idle_ms: turn.lastTaskActivityAt ? Date.now() - turn.lastTaskActivityAt : null,
          ui_state: 'error', turn_state: 'terminal',
        })
        endTurn('tool_task_timeout', turn.pendingToolTerminal.finalSequence)
      }, this.toolCallWindowMs)
      turn.taskTerminalTimer.unref?.()
    }

    // The one place a turn ends. `finalSequence` defaults to everything
    // forwarded so far, which is exactly the last segment's endpoint.
    const endTurn = (reason, finalSequence = turn.nextOutputSequence - 1) => {
      if (turn.turnEnded) return
      if (turn.outstandingTasks.size > 0 && reason !== 'tool_task_timeout') {
        turn.awaitingToolAudioTerminal = false
        clearTimeout(turn.toolAudioTimer)
        turn.toolAudioTimer = null
        turn.pendingToolTerminal = { reason, finalSequence }
        this.log('upstream_turn_terminal_deferred', {
          ...scopeLog, reason: 'task_in_flight', candidate_reason: reason,
          final_sequence: finalSequence, outstanding_tasks: turn.outstandingTasks.size,
          ui_state: 'thinking', turn_state: 'busy',
        })
        armTaskTerminalTimer('turn_terminal_deferred')
        return
      }
      turn.turnEnded = true
      turn.pendingToolTerminal = null
      turn.awaitingToolAudioTerminal = false
      clearTimeout(turn.taskTerminalTimer)
      turn.taskTerminalTimer = null
      clearTimeout(turn.toolAudioTimer)
      turn.toolAudioTimer = null
      turn.closedSegment = null
      clearTimeout(turn.segmentGapTimer)
      turn.segmentGapTimer = null
      // `gap_ms` / `window_ms` / `outstanding_tasks` are the ESS-990 calibration
      // feed: they are what a future run needs to re-derive the two windows
      // from production traffic instead of from this one 10-turn sample.
      this.log('upstream_turn_terminal', {
        ...scopeLog, reason, final_sequence: finalSequence,
        segments: turn.segmentsClosed || 1,
        gap_ms: turn.segmentClosedAt ? Date.now() - turn.segmentClosedAt : null,
        window_ms: turn.segmentGapWindowMs || null,
        outstanding_tasks: turn.outstandingTasks.size,
      })
      turn.segmentGapWindowMs = 0
      onEvent({
        type: 'agent.audio.done', response_id: responseId, final_sequence: finalSequence,
        segments: turn.segmentsClosed || 1,
      })
    }

    // ESS-990 THE terminal mechanism for a multi-segment turn: a parked
    // segment becomes the turn endpoint once the upstream has produced nothing
    // for `window` ms. Armed from the moment the segment closed, so widening
    // the window later never restarts the clock.
    const armSegmentGap = cause => {
      if (turn.terminal || turn.turnEnded || !turn.closedSegment) return
      const window = turn.pendingToolCall ? this.toolCallWindowMs
        : turn.turnBusy ? this.segmentGapBusyMs
        : this.segmentGapMs
      if (window <= 0) return endTurn('segment_gap_disabled', turn.closedSegment.finalSequence)
      // Re-arms only ever widen — except when a busy cause clears
      // (`turn_busy_cleared`), which may legitimately narrow the window back
      // to the base value so a direct-answer turn is not held open by a
      // background announcement that has already finished (ESS-1068).
      const mayShrink = cause === 'turn_busy_cleared'
      // ESS-1111: 一帧真实的上游任务活动**重新起表**，即使窗口宽度没变。
      // 这是本单验收「收到任何合法 task/progress/answer 帧都刷新活动时间」
      // 在网关侧的落点，也是唯一允许重启时钟的原因——其余 cause 仍然只能
      // 加宽、不能顺延（ESS-969 B1 的结论没有被推翻）。
      const mayRestart = cause === 'task_activity'
      if (turn.segmentGapWindowMs >= window && !mayShrink && !mayRestart) return
      clearTimeout(turn.segmentGapTimer)
      turn.segmentGapWindowMs = window
      // 起表基准：任务在飞时取「段落收口」与「最近一次任务活动」里更晚的那个。
      // 没有任务在飞时逐字节保持 ESS-990 的老口径（从段落收口起表）。
      const base = turn.outstandingTasks.size > 0
        ? Math.max(turn.segmentClosedAt, turn.lastTaskActivityAt)
        : turn.segmentClosedAt
      const remaining = Math.max(0, base + window - Date.now())
      this.log('upstream_segment_gap_armed', {
        ...scopeLog, cause, window_ms: window, remaining_ms: remaining,
        segment_index: turn.closedSegment.segmentIndex,
        outstanding_tasks: turn.outstandingTasks.size,
        base: base === turn.segmentClosedAt ? 'segment_closed' : 'task_activity',
      })
      turn.segmentGapTimer = setTimeout(() => {
        turn.segmentGapTimer = null
        if (turn.terminal || turn.turnEnded || !turn.closedSegment) return
        endTurn('segment_gap', turn.closedSegment.finalSequence)
      }, remaining)
      turn.segmentGapTimer.unref?.()
    }

    // ESS-990 corroborating evidence that this turn is NOT over: a background
    // task spawned by this turn has not reached a terminal status. It only
    // WIDENS the window, never ends or blocks a turn:
    //   • as a veto they are refuted by measurement — `task.accepted` lands
    //     795–8689 ms AFTER the first segment's `audio.done` (n=10), so it
    //     cannot protect the first segment, and tasks stay un-terminated 30–70 s
    //     past the last segment (`task.progress` still firing at 42.5 s in the
    //     南京 sample), so 「未终结 task ⇒ 不得收口」 would hold every
    //     tool-calling turn open until the client's own 45 s hard timeout;
    //   • as a widener they are exactly right: every measured segment gap
    //     longer than 1194.7 ms had one of these two in flight.
    // ESS-1111: 上游任务确实在推进的**证据帧**。生命周期帧、`task.stream` 的
    // 进展与答案增量都算，通知类事件（`task.notification.*`）不算——那是关于
    // 任务的通知，不是任务自己在动。收到即续期：挂起的终态窗口重新起表，
    // 停放的段落窗口从这一刻重算。
    const noteTaskActivity = cause => {
      turn.lastTaskActivityAt = Date.now()
      armTaskTerminalTimer(cause)
      armSegmentGap('task_activity')
    }

    const noteTurnBusy = cause => {
      if (turn.turnBusy) return
      turn.turnBusy = true
      this.log('upstream_turn_busy', { ...scopeLog, cause })
      armSegmentGap(cause)
    }

    // Clear the task-derived busy flag once every task has ended, and re-arm
    // the parked segment with the (possibly narrower) base window.
    const noteTurnIdle = cause => {
      if (!turn.turnBusy) return
      if (turn.outstandingTasks.size > 0) return
      turn.turnBusy = false
      this.log('upstream_turn_busy_cleared', {
        ...scopeLog, cause,
        active_announcements: turn.activeAnnouncements.size,
        outstanding_tasks: turn.outstandingTasks.size,
      })
      armSegmentGap('turn_busy_cleared')
    }

    // ESS-849 announcement isolation. 上游把「后台任务播报」和「本回合的回答」
    // 混在同一条 WSS 上，而**只有 `response.started` 带 `origin`**——实测
    // `audio.delta` / `audio.done` 94/94 条 `origin=null`
    // （2026-08-22 `smoke/upstream-turn-capture.mjs` 对真实上游取证）。
    // 所以归属只能靠 responseId → origin 映射，这张表只存在于本层：客户端
    // 拿不到 origin，过滤也就只能在这里做。
    //
    // 不过滤的后果已在真机实测（2026-08-22 13:59–14:00）：播报的 `audio.done`
    // 把本回合的下行闩死（`downlink_audio_done_accepted final_seq=51 gen=1`），
    // 随后真正的答案 4 帧被整段丢弃（`downlink_segment_dropped reason=post_done`），
    // 界面停在「思考中」直到 15 s 预算耗尽；播报内容还会串台（深圳那一轮
    // 播出「刚才查询的是杭州今天的天气情况」）。
    //
    // **映射缺失默认放行**（毕玄-cx 2026-08-22 拍板，正本见 ESS-849）：只有
    // responseId 明确登记在册才拦。上游若出现「先 delta 后 started」的乱序，
    // 那几帧会漏进本回合——宁可多播一段无关的，也不可吞掉用户的回答。
    // 漏网时 `upstream_announcement_started_late` 会留证；改这条口径前先看它。
    const announcementResponseIdOf = event => {
      if (event.responseId == null) return null
      const id = String(event.responseId)
      return turn.announcementResponseIds.has(id) ? id : null
    }

    // 播报音频不进入本回合的下行。语音通道按「只在当轮说、过期不补」允许丢弃
    // （白梦林定案），但丢弃必须留证——哪个 responseId、丢了多少帧/字节。
    // 非语音兜底（手表通知列表 / iPhone 侧）不在本单范围，另单跟进。
    const dropAnnouncementAudio = (id, event) => {
      let stat = turn.announcementDropped.get(id)
      if (!stat) {
        stat = { frames: 0, bytes: 0 }
        turn.announcementDropped.set(id, stat)
        // 逐帧记会把本回合真正的下行淹掉（一次播报实测 26 帧），所以只在第一
        // 帧留行级日志，总量交给 `audio.done` 的汇总。
        this.log('upstream_announcement_audio_dropped', {
          ...scopeLog, upstream_response_id: id,
        })
        while (turn.announcementDropped.size > MAX_ANNOUNCEMENT_RESPONSES) {
          turn.announcementDropped.delete(turn.announcementDropped.keys().next().value)
        }
      }
      stat.frames += 1
      stat.bytes += typeof event.audio === 'string' ? event.audio.length : 0
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
      // ESS-849: 播报帧走到这里，说明它的上游序号已经被 `enqueueOrdered` /
      // `drainContiguous` 消费掉了（连续性因此不断）。到此为止：不下发、不占
      // 下行契约序号、不释放已关闭的段落（播报不是「本回合又出声了」的证据）、
      // 不延长 `pendingDone` 的收口窗口。
      //
      if (frame.announcementId != null) {
        dropAnnouncementAudio(frame.announcementId, frame)
        return
      }
      // ESS-969: audio after a closed segment proves the turn went on. The
      // boundary must reach the client BEFORE the new segment's first frame,
      // otherwise the client attributes this audio to the previous segment.
      releaseClosedSegment('audio.delta')
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
        // ESS-1004：**所有非 audio.delta 的上游事件类型都要留证。**
        // 此前只有 audio.delta / audio.done 会落 `upstream_event_received`，
        // 于是真机日志里看不出 `voice.state` / `task.*` / `response.started`
        // 到底有没有到 —— ESS-969 的终态假设正是因此没能被证伪，
        // 我判 ESS-977 根因时也因此推错过一次。audio.delta 量太大不在此记，
        // 它已有 `upstream_audio_delta` 专线。
        if (event.type !== 'audio.delta') {
          this.log('upstream_event_seen', {
            ...scopeLog, upstream_event_type: event.type,
            origin: event.origin ?? null,
            state: event.state ?? null,
            task_status: event.task?.status ?? null,
          })
        }
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
          // ESS-974 fence, scoped to a turn that is already live (ESS-986).
          // A delayed broadcast naming one of OUR retired instances must not
          // kill the replacement — but the same guard must NOT swallow a
          // connect-time `busy` naming that retired instance: before
          // `voice.ready` that frame is what drives the ESS-978 two-step
          // takeover retry, and dropping it would strand the handshake until
          // `agent_connect_timeout_ms`.
          if (turn.ready && holder?.instanceId
            && this.retiredClientInstanceIds.has(holder.instanceId)) {
            this.log('upstream_ownership_ignored', {
              ...scopeLog, event_type: event.type,
              holder_label: holder?.label ?? null,
              reason: 'retired_client_instance',
            })
            return
          }
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
        // ESS-969 turn structure. `response.started` opens a response segment.
        // `origin` is `model` | `agent` | `announcement`; only `announcement`
        // is an unrelated background broadcast and must not steer this turn
        // (ESS-36) — but ESS-990 measured that an announcement occupying the
        // upstream voice slot is exactly what delays this turn's next segment
        // (5/5 of the gaps longer than 1.2 s had one), so it is recorded as
        // evidence that the turn is not over without ever becoming a segment.
        if (event.type === 'response.started') {
          if (event.origin === 'announcement') {
            const id = event.responseId == null ? null : String(event.responseId)
            const taskKey = event.taskId ?? event.task?.id ?? event.task?.workId ?? null
            const taskKeyStr = taskKey == null ? null : String(taskKey)
            if (id !== null) {
              turn.announcementResponseIds.add(id)
              while (turn.announcementResponseIds.size > MAX_ANNOUNCEMENT_RESPONSES) {
                turn.announcementResponseIds.delete(turn.announcementResponseIds.values().next().value)
              }
            }
            this.log('upstream_announcement_response_started', {
              ...scopeLog, upstream_response_id: event.responseId ?? null,
              upstream_task_id: taskKey,
            })
            // ESS-849 兜底口径的留证点：这条 `response.started` 来晚了，它的音频
            // 已经按「映射缺失默认放行」进了本回合。目前没有实测到这种乱序，
            // 若它真的发生，这条日志（而不是猜测）才是改口径的依据。
            if (id !== null && turn.forwardedResponseIds.has(id)) {
              this.log('upstream_announcement_started_late', {
                ...scopeLog, upstream_response_id: id,
              })
            }
            // Attribution is retained for audit, but an announcement is never
            // projected onto the foreground response stream. That stream owns
            // one request/generation-scoped sequence and done barrier.
            // Every announcement is tracked in `activeAnnouncements` so its
            // busy cause is cleared when it ends, attributed or not.
            if (id !== null) turn.activeAnnouncements.add(id)
            const attributed = this.#attributeAnnouncement(turn, event, taskKeyStr)
            if (attributed) {
              if (taskKeyStr !== null && turn.deliveredAnnouncements.has(taskKeyStr)) {
                // Duplicate delivery of an already-consumed result: isolate.
                this.log('upstream_announcement_duplicate', {
                  ...scopeLog, upstream_response_id: id, upstream_task_id: taskKeyStr,
                })
              } else {
                this.log('upstream_announcement_correlated', {
                  ...scopeLog, upstream_response_id: id, upstream_task_id: taskKeyStr,
                })
                this.log('upstream_announcement_isolated', {
                  ...scopeLog, upstream_response_id: id, upstream_task_id: taskKeyStr,
                  reason: 'foreground_turn_isolation',
                })
              }
            } else {
              if (id !== null) {
                turn.isolatedAnnouncements.add(id)
                if (!turn.committed && ws.readyState === WebSocket.OPEN) {
                  // Upstream confirms notification delivery on playback start.
                  // A following interrupt cancels the stale response occupying
                  // the realtime output slot, without deleting task history.
                  ws.send(JSON.stringify({ type: 'playback.started', responseId: id }))
                  ws.send(JSON.stringify({ type: 'interrupt' }))
                  turn.preemptedAnnouncements.add(id)
                  this.log('upstream_announcement_preempted', {
                    ...scopeLog, upstream_response_id: id,
                    reason: 'unattributed_before_commit',
                  })
                }
              }
              this.log('upstream_announcement_isolated', {
                ...scopeLog, upstream_response_id: id, upstream_task_id: taskKeyStr,
                reason: 'unattributed',
              })
            }
            // An announcement is a background delivery stream, never evidence
            // about the foreground user turn. It must not occupy or widen the
            // turn's busy/terminal window.
            return
          }
          this.log('upstream_response_started', {
            ...scopeLog, upstream_response_id: event.responseId ?? null,
            origin: event.origin ?? null, segment_index: turn.segmentIndex,
          })
          releaseClosedSegment('response.started')
          return
        }
        if (event.type === 'voice.state' && event.origin !== 'announcement') {
          turn.sawVoiceState = true
          if (event.state === 'idle') {
            // ESS-990: idle is a per-RESPONSE playback state, not a turn
            // terminal (upstream `realtime-gateway.mjs` emits it from
            // `finishPlayback` / `cancelPlayback`; measured 0.14–0.54 ms after
            // every segment's `audio.done`, n=10, with 10/10 turns producing
            // another segment afterwards). It therefore decides nothing here.
            //
            // 两件事必须一起读，否则会以为这里在防一个不存在的问题：
            // 上游的 `finishPlayback` 只由客户端的 `playback.ended` 回执触发
            // （upstream `realtime-gateway.mjs` 的 PLAYBACK_ENDED 分支），而本
            // 适配器**从不回 playback 回执**——所以真机 Watch 链路上，有音频的
            // 回答根本收不到 idle（与 ESS-1004 三轮真机 `downlink_done=0` 一致）；
            // ESS-990 的取证脚本按 Bridge 的方言回了回执，才把 idle 抓出来。
            // 两条证据指向同一个结论：idle 既不可靠、也不表示回合结束。
            //
            // 它仍然会 settle 一个挂起的 done（那是关于段落的真事实），
            // 也仍然是 `auto` 的方言指纹。
            if (turn.pendingDone) flushDone()
            this.log('upstream_voice_state_idle', {
              ...scopeLog, pending_done: turn.pendingDone,
              reorder_pending: turn.reorderBuffer.size,
              segments_closed: turn.segmentsClosed,
              parked_segment: turn.closedSegment ? turn.closedSegment.segmentIndex : null,
              suppressed: turn.toolGateActive(),
              suppressed_reason: turn.toolGateActive() ? 'tool_turn_active' : null,
              task_id: turn.outstandingTasks.values().next().value ?? null,
              outstanding_tasks: turn.outstandingTasks.size,
              tool_call_pending: turn.pendingToolCall,
              ui_state: turn.toolGateActive() ? 'thinking' : 'idle',
              turn_state: turn.toolGateActive() ? 'busy' : 'idle',
            })
          }
          return
        }
        if (event.type === 'audio.delta' && event.audio) {
          // ESS-849: 播报帧**照常走完排序机制，只在 `emitDelta` 最后一步不下发**。
          //
          // 这里曾经直接 `return`，被毕玄-cx 在 PR #391 复审时拦下——上游的
          // sequence **跨 response 连续**（真机 2026-08-22：播报占到 `final_seq=51`，
          // 答案是 `seq=52..55`），直接 return 不推进 `expectedUpstream`，会在
          // 51 之前留一串洞：答案全部被扣在重排缓冲里，`armGapTimer` 到点把整轮
          // 判成 ERR_UPSTREAM_SEQUENCE_GAP。本机复现（回合已锚定，播报占 1..51）：
          // 下行只有 `delta#0=seg1`，随后就是 `agent.error` / ERR_UPSTREAM_SEQUENCE_GAP，
          // 答案 4 帧一帧不到——比原 bug 更糟，原来只是播错，那样是全丢。
          //
          // 播报帧因此只跳过「与本回合语义有关」的三件事，序号该占的照占：
          //   • 不 `noteResponseProgress()` —— 播报不证明本回合有回答，让它解除
          //     commit 后的应答死线，客户端就再也拿不到可判定的
          //     ERR_UPSTREAM_NO_RESPONSE（用例实测：修复前只有播报的那一轮，
          //     10 s 内一条 `agent.error` 都没有）；
          //   • 不占下行契约序号、不 `releaseClosedSegment`、不延长 done 窗口
          //     —— 见 `emitDelta` 顶部。
          const announcementId = announcementResponseIdOf(event)
          if (announcementId === null) {
            if (event.responseId != null) {
              turn.forwardedResponseIds.add(String(event.responseId))
              while (turn.forwardedResponseIds.size > MAX_ANNOUNCEMENT_RESPONSES) {
                turn.forwardedResponseIds.delete(turn.forwardedResponseIds.values().next().value)
              }
            }
            noteResponseProgress()
          }
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
            // ESS-849: 非 null 表示这一帧属于播报——排序照做，下发不做。
            announcementId,
          }
          if (upstreamSequence === null) emitDelta(frame)
          else enqueueOrdered(frame)
          return
        }
        if (event.type === 'audio.done') {
          // ESS-849 的核心一条：播报的 `audio.done` 不是本回合的段落收口。
          // 真机 14:00 那次「界面停在思考中」就是它闩死了下行，答案随后到达
          // 却被客户端按 `post_done` 整段丢弃。不带 responseId 的 done 同样按
          // 「映射缺失默认放行」处理——它落到下面的正常收口路径。
          const doneAnnouncementId = announcementResponseIdOf(event)
          if (doneAnnouncementId !== null) {
            // ESS-1068: 归属明确的播报是「本用户的后台任务最终结果」，其 audio.done
            // 是一个真实段落收口（下发 segment 边界），且结束后要清除 busy 让后续
            // 直答回落到基础窗口。未归属的播报维持 ESS-849 隔离。
            const deliver = turn.deliverAnnouncementIds.has(doneAnnouncementId)
            turn.deliverAnnouncementIds.delete(doneAnnouncementId)
            turn.activeAnnouncements.delete(doneAnnouncementId)
            turn.isolatedAnnouncements.delete(doneAnnouncementId)
            turn.preemptedAnnouncements.delete(doneAnnouncementId)
            const stat = turn.announcementDropped.get(doneAnnouncementId) ?? { frames: 0, bytes: 0 }
            turn.announcementDropped.delete(doneAnnouncementId)
            if (deliver) {
              // Delivery may be attributed to this conversation, but it is
              // still not a response to this commit and cannot satisfy its
              // response deadline.
              // ESS-1068 复审第3点：完整下发（audio.done）才算 consumed，
              // 把 pending 转 delivered（exactly-once dedup 的落点后移）。
              const taskKey = turn.pendingAnnouncementTaskIds.get(doneAnnouncementId)
              if (taskKey !== undefined) {
                turn.deliveredAnnouncements.add(taskKey)
                while (turn.deliveredAnnouncements.size > MAX_TASKS_PER_CONVERSATION) {
                  turn.deliveredAnnouncements.delete(turn.deliveredAnnouncements.values().next().value)
                }
              }
              turn.pendingAnnouncementTaskIds.delete(doneAnnouncementId)
              this.log('upstream_announcement_audio_done_delivered', {
                ...scopeLog, upstream_response_id: doneAnnouncementId,
                upstream_task_id: taskKey ?? null,
                final_sequence: turn.nextOutputSequence - 1,
              })
            } else {
              this.log('upstream_announcement_audio_done_dropped', {
                ...scopeLog, upstream_response_id: doneAnnouncementId,
                dropped_frames: stat.frames, dropped_bytes: stat.bytes,
              })
            }
            noteTurnIdle('announcement_done')
            return
          }
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
          // 同一张表也管文本：播报的 transcript 走这条路会串台——实测深圳那一轮
          // 下行里出现「刚才查询的是杭州今天的天气情况，不是深圳的」。
          const transcriptAnnouncementId = announcementResponseIdOf(event)
          if (transcriptAnnouncementId !== null) {
            this.log('upstream_announcement_transcript_dropped', {
              ...scopeLog, upstream_response_id: transcriptAnnouncementId,
              content_length: typeof event.content === 'string' ? event.content.length : 0,
            })
            return
          }
          noteResponseProgress()
          onEvent({ type: 'agent.transcript.final', response_id: responseId,
            role: event.role, content: typeof event.content === 'string' ? event.content : '' })
          return
        }
        // ESS-1111（消费上游 ESS-1110 的加性契约）：`task.stream` 是上游按
        // **产生顺序**发的增量流，`server/src/voice/task-stream-protocol.mjs`
        // 定义。一帧的形状是
        //   `{type:'task.stream', protocolVersion, taskId, requestId, sessionId,
        //     generation, category:'progress'|'text'|'audio'|'terminal', seq, …}`
        // progress 带 `message`（+ 可选 `status`），text 带答案增量 `delta`。
        // 每个 category 有**独立**的 `seq`，同一 task 内单调。
        //
        // 必须在下面的通用 `task.` 分支之前拦截：那条分支会把 `task.stream`
        // 的 `event.type.slice(5)` 当成状态，客户端会收到一个字面量为
        // `'stream'` 的任务状态——既不是真实状态，也不在任何一侧的枚举里。
        //
        // 未知 category 一律忽略而不是报错：这条契约是加性的，上游加新 category
        // 时旧网关必须继续工作（本单验收「未知字段向前兼容」的网关侧落点）。
        if (event.type === 'task.stream') {
          const streamTaskId = String(event.taskId ?? event.requestId ?? '')
          if (!streamTaskId) return
          noteResponseProgress()
          const category = String(event.category ?? '')
          const streamStatus = typeof event.status === 'string' && event.status
            ? event.status : 'running'
          this.log('upstream_task_stream', {
            ...scopeLog, task_id: streamTaskId, category,
            seq: Number.isInteger(event.seq) ? event.seq : null,
            protocol_version: event.protocolVersion ?? null,
            status: streamStatus,
            // 增量文本本身不落日志：它是用户可见的答案内容，日志里只留长度。
            delta_length: typeof event.delta === 'string' ? event.delta.length : 0,
          })
          if (category !== 'progress' && category !== 'text') return
          if (TASK_TERMINAL_STATUSES.has(streamStatus)) return
          // 终态仍然只由 `task.completed/failed/cancelled` 裁决（`category:
          // 'terminal'` 帧上面已经被过滤掉）：两套终态真相并存，就等于给
          // 「终态只发一次」开了第二个入口。
          turn.outstandingTasks.add(streamTaskId)
          noteTurnBusy('task_in_flight')
          noteTaskActivity(`task_stream_${category}`)
          if (category === 'progress') {
            const progress = projectStreamProgress(event)
            if (!progress) return
            onEvent({
              type: 'agent.task', response_id: responseId,
              task: { id: streamTaskId, status: streamStatus }, progress,
            })
            return
          }
          const delta = typeof event.delta === 'string' ? event.delta : ''
          if (!delta) return
          onEvent({
            type: 'agent.task', response_id: responseId,
            task: { id: streamTaskId, status: streamStatus },
            answer: { delta },
          })
          return
        }
        // ESS-990 task lifecycle. Real captured frames carry the id on
        // `event.task.id` (`{type:'task.accepted', task:{id, workId, status,
        // sessionId, turnId, …}}`, 2026-08-22 capture) — `event.taskId` and
        // `task.workId` are accepted too so a shape change cannot silently
        // drop the signal. Terminal statuses are the `GatewayTaskEvent` ones
        // (`shared/realtime-events.mjs`); `task.accepted` is real but off-enum,
        // so membership is decided by「not terminal」rather than by a whitelist.
        if (event.type.startsWith('task.')) {
          const taskId = event.task?.id ?? event.task?.workId ?? event.taskId ?? null
          if (taskId === null) return
          noteResponseProgress()
          const id = String(taskId)
          const status = String(event.task?.status ?? event.type.slice(5))
          const terminal = TASK_TERMINAL_EVENTS.has(event.type) || TASK_TERMINAL_STATUSES.has(status)
          // ESS-1068: remember each task's source identity (session/device/turn)
          // so a later background announcement carrying only a taskId can be
          // attributed to this conversation instead of isolated as a leak.
          if (event.task?.sessionId != null || event.task?.deviceId != null || event.task?.turnId != null) {
            const prior = turn.taskIdentity.get(id)
            turn.taskIdentity.set(id, {
              sessionId: event.task?.sessionId ?? prior?.sessionId ?? null,
              deviceId: event.task?.deviceId ?? prior?.deviceId ?? null,
              turnId: event.task?.turnId ?? prior?.turnId ?? null,
            })
            while (turn.taskIdentity.size > MAX_TASKS_PER_CONVERSATION) {
              turn.taskIdentity.delete(turn.taskIdentity.keys().next().value)
            }
          }
          if (terminal) {
            turn.outstandingTasks.delete(id)
            noteTurnIdle('task_terminal')
            if (turn.outstandingTasks.size === 0 && turn.pendingToolTerminal) {
              const candidate = turn.pendingToolTerminal
              endTurn('task_terminal_audio_done', candidate.finalSequence)
            }
          } else if (!TASK_NON_LIFECYCLE_EVENTS.has(event.type)) {
            turn.outstandingTasks.add(id)
            noteTurnBusy('task_in_flight')
            noteTaskActivity('task_lifecycle')
          } else if (event.type === 'task.progress.check') {
            // ESS-1111: 进展检查不改变生命周期集合（它是通知，不是状态迁移），
            // 但它是上游「我还在推进」的**一等证据**，必须续期。
            noteTaskActivity('task_progress')
          }
          // ESS-1100：上游在同一帧里带着**阶段性进展**（`task.activity` /
          // `authorization` / 生命周期子状态）。此前这里只取 {id, status}，
          // 进展文字在这一跳被整段丢弃，客户端于是只能显示笼统的「正在思考」。
          // 投影规则见 `task-progress.mjs`（H5 `task-view.js` 的手表适配版）。
          const progress = projectTaskProgress(event.task, event.type)
          // ESS-1004 取证线，保留：真机日志靠它才看得出后台工作的起止。
          this.log('upstream_task_state', {
            ...scopeLog, task_id: id, status,
            outstanding: turn.outstandingTasks.size,
            progress_text: progress?.text ?? null,
            progress_category: progress?.category ?? null,
          })
          onEvent({
            type: 'agent.task', response_id: responseId, task: { id, status },
            ...(progress ? { progress } : {}),
          })
          return
        }
        // ESS-1043: qwen `response.done` is the response-level metadata that
        // carries `hasFunctionCall` — the signal the model is about to run a
        // tool and produce at least one more segment. The upstream only knows
        // this when the response completes, so this is the earliest reliable
        // place to learn「the turn is not over yet」. `hasFunctionCall` is read
        // from the qwen dialect's top-level field, with the OpenAI-style nested
        // `response.hasFunctionCall` and snake_case accepted too so a shape
        // change cannot silently drop the signal.
        if (event.type === 'response.done') {
          const rawHasFunctionCall = typeof event.hasFunctionCall === 'boolean'
            ? event.hasFunctionCall
            : typeof event.response?.hasFunctionCall === 'boolean'
              ? event.response.hasFunctionCall
              : typeof event.has_function_call === 'boolean'
                ? event.has_function_call
                : null
          const hasFunctionCall = rawHasFunctionCall === true
          const upstreamResponseId = event.responseId ?? event.response?.id ?? null
          const responseOrigin = event.origin ?? event.response?.origin ?? null
          const responseAnnouncementId = responseOrigin === 'announcement'
            ? String(upstreamResponseId ?? '') || null
            : announcementResponseIdOf({ responseId: upstreamResponseId })
          this.log('upstream_response_done', {
            ...scopeLog, upstream_response_id: upstreamResponseId,
            origin: responseOrigin,
            status: event.status ?? event.response?.status ?? null,
            has_function_call: rawHasFunctionCall,
          })
          // ESS-849/1052: response.done shares the same responseId→origin
          // ownership table as audio/transcript. A stale background completion
          // proves nothing about this turn and must neither cancel its response
          // deadline nor mutate the pending-tool latch.
          if (responseAnnouncementId !== null) {
            this.log('upstream_announcement_response_done_dropped', {
              ...scopeLog,
              upstream_response_id: responseAnnouncementId,
              has_function_call: rawHasFunctionCall,
            })
            // ESS-1068: the announcement finished; drop the busy cause it held.
            turn.deliverAnnouncementIds.delete(responseAnnouncementId)
            turn.activeAnnouncements.delete(responseAnnouncementId)
            turn.isolatedAnnouncements.delete(responseAnnouncementId)
            turn.preemptedAnnouncements.delete(responseAnnouncementId)
            noteTurnIdle('announcement_response_done')
            return
          }
          noteResponseProgress()
          if (hasFunctionCall) {
            if (!turn.pendingToolCall) {
              turn.pendingToolCall = true
              this.log('upstream_tool_call_pending', { ...scopeLog, upstream_response_id: upstreamResponseId })
              // ESS-1097: the client needs the latch too. Between here and the
              // first `task.*` frame the upstream emits `voice.state=idle` while
              // the tool is still being dispatched — a client that only sees
              // audio-side facts reads that gap as「turn over」and relistens.
              onEvent({
                type: 'agent.tool_call_state', response_id: responseId,
                status: 'tool_call_pending',
              })
            }
            // A parked segment must not close the turn while the tool runs:
            // re-arm its window with the dedicated tool-call window (the
            // re-arm only ever widens — see `armSegmentGap`).
            if (turn.closedSegment) armSegmentGap('tool_call_pending')
          } else if (turn.pendingToolCall
            && rawHasFunctionCall === false
            && responseOrigin === 'agent') {
            turn.pendingToolCall = false
            this.log('upstream_tool_call_resolved', { ...scopeLog, upstream_response_id: upstreamResponseId })
            // ESS-1097: covers the residual case「a tool call was announced but
            // no task id ever appeared」. A client that saw `tool_call_pending`
            // has nothing else that can release its latch, so this frame is a
            // server obligation, not an optimisation.
            onEvent({
              type: 'agent.tool_call_state', response_id: responseId,
              status: 'tool_call_resolved',
            })
            // The tool result is the final segment. End the turn as soon as its
            // audio settles — immediately if the segment already closed, or on
            // the pending `flushDone` otherwise.
            if (turn.closedSegment) {
              endTurn('tool_result_done', turn.closedSegment.finalSequence)
            } else {
              // The upstream gateway emits response.done before audio.done.
              // Remember the final response now; flushDone consumes this latch
              // once its audio barrier settles.
              turn.endAfterDone = true
            }
          } else if (turn.pendingToolCall) {
            // ESS-1052: one WSS also carries stale background announcements.
            // Missing metadata is not explicit false, and an announcement/model
            // completion is not the agent tool result. Neither may clear the
            // pending latch or the real answer will arrive after a false
            // tool_result_done terminal.
            this.log('upstream_tool_call_resolution_ignored', {
              ...scopeLog, upstream_response_id: upstreamResponseId,
              origin: responseOrigin, has_function_call: rawHasFunctionCall,
            })
          }
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
        // ESS-969: a close is an unambiguous turn terminal, so a segment that
        // `flushDone` parked here becomes the turn endpoint rather than
        // waiting on the backstop. `endTurn` is idempotent, so the legacy
        // branch (which ends inside `flushDone`) is unaffected.
        if ((turn.pendingDone || turn.closedSegment) && turn.reorderBuffer.size === 0) {
          flushDone()
          if (turn.closedSegment) endTurn('upstream_closed', turn.closedSegment.finalSequence)
          turn.terminal = true
          clearTimeout(turn.connectTimer)
          clearTimeout(turn.responseTimer)
          clearTimeout(turn.segmentGapTimer)
          clearTimeout(turn.taskTerminalTimer)
          clearTimeout(turn.toolAudioTimer)
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
        // Cover the narrow case where an isolated response was registered
        // while the socket was not writable. Already-preempted responses are
        // deliberately excluded: upstream interrupt advances a generation, so
        // emitting it twice would be a second state transition, not idempotency.
        const pendingPreemption = [...turn.isolatedAnnouncements]
          .filter(id => !turn.preemptedAnnouncements.has(id))
        if (pendingPreemption.length > 0 && turn.ws?.readyState === WebSocket.OPEN) {
          turn.ws.send(JSON.stringify({ type: 'interrupt' }))
          this.log('upstream_announcement_preempted_at_commit', {
            ...scopeLog, count: pendingPreemption.length,
          })
        }
        turn.responded = false
        turn.commitSentAt = null
        if (sendOrQueue({ type: 'audio.commit' })) armResponseDeadline()
      },
      cancel: () => {
        if (turn.terminal) return
        if (turn.ws?.readyState === WebSocket.OPEN) {
          turn.ws.send(JSON.stringify({ type: 'interrupt' }))
        }
        turn.terminal = true
        clearTimeout(turn.connectTimer)
        clearTimeout(turn.doneTimer)
        clearTimeout(turn.gapTimer)
        clearTimeout(turn.responseTimer)
        clearTimeout(turn.segmentGapTimer)
        clearTimeout(turn.taskTerminalTimer)
        clearTimeout(turn.toolAudioTimer)
        turn.ws?.close()
        this.#release(turn)
      },
      close: () => {
        // A completed turn can still own an open upstream socket. Session
        // teardown must close that handle even after endTurn marked the turn
        // terminal. Terminate after the best-effort mute instead of starting a
        // graceful close handshake: this is already final session teardown,
        // and an unresponsive peer otherwise keeps ws's 30 s close timer alive.
        turn.terminal = true
        clearTimeout(turn.connectTimer)
        clearTimeout(turn.doneTimer)
        clearTimeout(turn.gapTimer)
        clearTimeout(turn.responseTimer)
        clearTimeout(turn.segmentGapTimer)
        clearTimeout(turn.taskTerminalTimer)
        clearTimeout(turn.toolAudioTimer)
        if (turn.ws?.readyState === WebSocket.OPEN) {
          turn.ws.send(JSON.stringify({ type: 'mute' }))
        }
        turn.ws?.terminate()
        this.#release(turn)
      },
      // ESS-1068 复审第1点：把 Watch 的 playback 回执转发给 qwen，
      // 触发 qwen 的 `startPlayback` → `announcements.confirmMany`（ack）。
      // qwen 侧协议：`{ type: 'playback.started'|'playback.ended', responseId }`。
      playbackStarted: responseId => {
        if (turn.terminal || turn.ws?.readyState !== WebSocket.OPEN) return
        turn.ws.send(JSON.stringify({ type: 'playback.started', responseId: String(responseId ?? '') }))
      },
      playbackEnded: responseId => {
        if (turn.terminal || turn.ws?.readyState !== WebSocket.OPEN) return
        turn.ws.send(JSON.stringify({ type: 'playback.ended', responseId: String(responseId ?? '') }))
      },
    }
  }
}
