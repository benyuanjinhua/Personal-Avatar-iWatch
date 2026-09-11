import Combine
import Foundation
import OSLog
import os
import WatchConnectivity

@MainActor
final class PhoneConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    private static let logger = Logger(subsystem: "com.benyuan.wristagent.phone", category: "VoiceDownlink")
    @Published private(set) var status = "尚未连接 Apple Watch"
    @Published private(set) var history: [ConversationHistoryEntry] = []
    @Published private(set) var voiceEntries: [VoiceInboxEntry] = []
    @Published private(set) var voiceStatus = "尚未收到语音请求"
    /// 下行未送达条目数：iPhone UI 可见「还有 N 条没到手表」，不再无声无息。
    @Published private(set) var pendingDownlinkCount = 0
    /// ESS-28：加密 outbox + Tailscale 上送 + 结果回传编排器。
    let relay: WristAgentPhoneRelay
    /// ESS-321 real-time media session (Watch ↔ iPhone ↔ Bridge/Agent). Lazily
    /// constructed on the first uplink envelope so households that never
    /// enable streaming do not pay for the WSS setup.
    /// ESS-751：显式 storage 而不是 `lazy var`——连通性回调要能判断「会话是否
    /// 已经存在」再决定要不要重放，用 `lazy var` 光是查询就会触发 WSS 构造。
    private var realtimeSessionStorage: PhoneRealtimeSession?
    /// `ready` is a one-shot control message. WCSession can briefly report the
    /// Watch unreachable while the realtime WSS is already active; dropping
    /// it there leaves the Watch in `.connecting` until its timeout cancels
    /// recording. Keep the latest turn-scoped value and replay on reachability.
    private var pendingRealtimeChannelReady: RealtimeChannelReady?
    /// ESS-869: dedup markers so repeated activation/reachability/watch-state
    /// callbacks do not re-send (interactive) or re-enqueue (durable) the same
    /// ready. Both reset when a new turn supersedes `pendingRealtimeChannelReady`.
    private var interactiveReadyDelivered: RealtimeChannelReady?
    /// ESS-869 (architecture-review fix): bounded-retry state machine for the
    /// durable `transferUserInfo` path. The dedup marker lives here so a failed
    /// system receipt can clear it and re-enqueue instead of being blocked
    /// forever; after `maxAttempts` failures it gives up (no infinite retry).
    private var durableTracker = RealtimeChannelReadyDurableTracker()
    private var realtimeSession: PhoneRealtimeSession {
        if let existing = realtimeSessionStorage { return existing }
        let session = PhoneRealtimeSession(transportFactory: { [weak self] requestId, sessionId in
            self?.makeRealtimeTransport(requestId: requestId, sessionId: sessionId)
        })
        session.onDownlink = { [weak self] envelope in
            self?.forwardRealtimeDownlink(envelope) ?? .deferred
        }
        session.onStateChange = { [weak self] state in
            guard case .active(let requestId, let sessionId) = state else { return }
            self?.sendRealtimeChannelReady(requestId: requestId, sessionId: sessionId)
        }
        realtimeSessionStorage = session
        return session
    }
    /// ESS-391: feature flag controlling the Agent direct path.
    private let agentFlag = AudioRealtimeAgentFeatureFlag()
    /// ESS-391: cached Agent session — created once, reused across turns.
    /// The session is re-connected per turn with fresh token + requestId.
    private var agentSession: AudioRealtimeAgentSession?
    /// ESS-391: cached token for current turn (ephemeral, memory-only).
    private var agentEphemeralToken: String?
    /// Envelopes are held only while the per-turn token request is in flight.
    /// A failed mint drains them through the legacy Bridge exactly once.
    private var pendingAgentEnvelopes = AgentEnvelopeBuffer()
    private var agentTokenTask: Task<Void, Never>?
    private var agentTokenState = AgentTokenMintState()
    private var pendingConfiguration: AgentConfiguration?
    private let historyStorageKey = "wristagent.phone.conversation.history"
    private let voiceInbox: VoiceRequestInbox?
    /// ESS-21 B1：iPhone → Watch 下行持久化队列。会话未激活时排队重投，不静默丢弃。
    private let downlink: WatchDownlinkOutbox?
    private var downlinkFlushTask: Task<Void, Never>?
    private static let downlinkLogger = Logger(
        subsystem: "beer.workspace.wristagent", category: "watch-downlink"
    )
    /// ESS-525: iPhone-side structured client log → bridge.log shipper. Lets
    /// downlink evidence for a given request_id land next to Watch entries.
    private let phoneClientLog: PhoneClientLog

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        voiceInbox = try? VoiceRequestInbox(directory: base.appendingPathComponent("VoiceInbox", isDirectory: true))
        downlink = try? WatchDownlinkOutbox(
            directory: base.appendingPathComponent("WatchDownlink", isDirectory: true),
            log: { event in PhoneConnectivity.logDownlink(event) }
        )
        relay = WristAgentPhoneRelay()
        // Uplink is nil until pairing succeeds; PhoneClientLog stores locally
        // in the meantime and drains once `WristAgentPhoneRelay` has a client.
        let logDirectory = base.appendingPathComponent("PhoneClientLogs", isDirectory: true)
        let relayRef = relay
        phoneClientLog = PhoneClientLog(
            directory: logDirectory,
            uplink: { relayRef.clientLogUplink }
        )
        super.init()
        relay.watchChannel = self
        pendingDownlinkCount = downlink?.pendingCount() ?? 0
        voiceEntries = voiceInbox?.entries ?? []
        if
            let data = UserDefaults.standard.data(forKey: historyStorageKey),
            let saved = try? JSONDecoder().decode([ConversationHistoryEntry].self, from: data)
        {
            history = saved
        }
    }

    /// Watch 端 transferFile 落地：sha256 校验 + request_id 幂等去重，失败不送往 Mac。
    private func ingestVoiceFile(envelopeData: Data, audioData: Data) {
        guard let inbox = voiceInbox else {
            voiceStatus = "收件箱不可用"
            return
        }
        switch inbox.ingest(envelopeData: envelopeData, audioData: audioData) {
        case .accepted(let envelope, let fileURL):
            voiceEntries = inbox.entries
            voiceStatus = "已接收 \(envelope.requestId.prefix(8))…（\(envelope.audio.durationMs) ms）"
            // 交给 Relay：加密入队 + 回执 Watch + 异步上送 Mac。
            relay.handleAccepted(envelope: envelope, audioData: audioData)
            // 明文副本删除；音频仅以 outbox 密文形式保留（§8）。
            try? FileManager.default.removeItem(at: fileURL)
        case .duplicate(let requestId):
            voiceStatus = "重复请求 \(requestId.prefix(8))…，已幂等丢弃"
            // 幂等重发：不产生第二个请求，由 Relay 重发当前状态。
            if let envelope = try? VoiceRequestEnvelope.decode(from: envelopeData) {
                relay.handleAccepted(envelope: envelope, audioData: audioData)
            }
        case .rejected(let error):
            voiceStatus = "已拒收：\(error.description)"
        }
    }

    func activate() {
        guard WCSession.isSupported() else {
            status = "此设备不支持 Watch Connectivity"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
        relay.start()
        // ESS-525: install the phone client-log sink AFTER relay.start so
        // `clientLogUplink` has already been constructed. Any preceding
        // downlink event still lands (PhoneAgentClientLog no-ops without a
        // sink), just doesn't ship to bridge.log until this point.
        phoneClientLog.start()
        // ESS-539 v2: purge stale realtime downlink envelopes from previous
        // sessions before flushing anything to the Watch.
        if let purged = downlink?.purgeRealtimeDownlink(), purged > 0 {
            Self.logger.info(
                "purged \(purged) stale realtime downlink envelopes on cold start"
            )
            pendingDownlinkCount = downlink?.pendingCount() ?? 0
        }
        // 冷启动补投：上次进程排队/在途未确认的下行，App 一打开就重投。
        flushDownlink(trigger: "activate")
    }

    /// ESS-1008: correlate iPhone scene changes with the Agent WSS turn.
    /// This is evidence only; entering background does not proactively close
    /// the socket and therefore cannot manufacture the failure it observes.
    func recordLifecycle(_ phase: String) {
        let identity = realtimeSessionStorage?.currentTurnIdentity
        PhoneAgentClientLog.info(
            module: "phone_lifecycle", event: "scene_phase",
            requestId: identity?.requestId,
            sessionId: identity?.sessionId,
            detail: "phase=\(phase) has_active_turn=\(identity != nil)"
        )
    }

    func send(_ configuration: AgentConfiguration) {
        let watchConfiguration = configuration.watchSafe
        pendingConfiguration = watchConfiguration
        guard WCSession.default.activationState == .activated else { return }
        do {
            let data = try JSONEncoder().encode(watchConfiguration)
            try WCSession.default.updateApplicationContext([ConfigurationMessage.key: data])
            if WCSession.default.isReachable {
                WCSession.default.sendMessageData(data, replyHandler: nil) { [weak self] error in
                    Task { @MainActor in self?.status = "同步失败：\(error.localizedDescription)" }
                }
            }
            status = WCSession.default.isWatchAppInstalled ? "设置已同步到 Apple Watch" : "尚未安装 Watch App"
        } catch {
            status = "无法保存设置：\(error.localizedDescription)"
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.status = "连接失败：\(error.localizedDescription)"
            } else {
                self.status = activationState == .activated ? "已连接" : "正在连接"
                if let configuration = self.pendingConfiguration {
                    self.send(configuration)
                }
            }
            // 会话刚激活正是此前静默丢弃的时刻，这里必须补投。
            self.replayRealtimeChannelReady(trigger: "activation")
            self.replayRealtimeDownlink(trigger: "activation")
            self.flushDownlink(trigger: "activation")
            self.relay.resumeEvents(trigger: "wc-activation")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.replayRealtimeChannelReady(trigger: "reachability")
            self.replayRealtimeDownlink(trigger: "reachability")
            self.flushDownlink(trigger: "reachability")
            self.relay.resumeEvents(trigger: "wc-reachability")
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.replayRealtimeChannelReady(trigger: "watch-state")
            self.replayRealtimeDownlink(trigger: "watch-state")
            self.flushDownlink(trigger: "watch-state")
            self.relay.resumeEvents(trigger: "wc-watch-state")
        }
    }

    /// 系统回执：userInfo 队列条目已交付 Watch（或最终失败）。
    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        // ESS-869: the reliable-channel delivery receipt for a deferred channel
        // ready. This is the success event that pairs with
        // `channel_ready_deferred` by request_id (acceptance §2), and the
        // bounded-retry / give-up decision on a failed receipt.
        if let readyData = userInfoTransfer.userInfo[RealtimeMediaMessage.channelReadyEnvelopeKey] as? Data,
           let ready = try? JSONDecoder().decode(RealtimeChannelReady.self, from: readyData) {
            Task { @MainActor in
                self.handleChannelReadyDurableReceipt(ready, error: error)
            }
            return
        }
        let itemId = userInfoTransfer.userInfo[Self.downlinkItemIdKey] as? String
        Task { @MainActor in
            self.completeDownlink(itemId: itemId, error: error)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        if let ackData = message[ResultDeliveryAckMessage.envelopeKey] as? Data,
           let ack = ResultDeliveryAck.decode(from: ackData) {
            Task { @MainActor in self.relay.acknowledgeResult(requestId: ack.requestId) }
            return
        }
        // ESS-184/207 探针回执（sendMessage 快路径）：即时通道优先，两路（含
        // transferUserInfo）都到时靠 postProbeAck 内的 in-flight 去重挡住。
        if let ackData = message[ProbeAckMessage.envelopeKey] as? Data,
           let ack = ProbeAckEnvelope.decode(from: ackData) {
            Task { @MainActor in self.relay.postProbeAck(ack) }
            return
        }
        if let summaryData = message[WatchClientLogMessage.selfCheckSummaryKey] as? Data {
            Task { @MainActor in self.ingestSelfCheckSummary(data: summaryData) }
            return
        }
        if let realtimeUplink = message[RealtimeMediaMessage.uplinkEnvelopeKey] as? Data {
            Task { @MainActor in self.handleRealtimeUplink(data: realtimeUplink) }
            return
        }
        guard
            let envelopeData = message[VoiceMessage.envelopeKey] as? Data,
            let envelope = try? VoiceRequestEnvelope.decode(from: envelopeData)
        else { return }
        Task { @MainActor in
            self.voiceStatus = "收到元数据预告 \(envelope.requestId.prefix(8))…，等待音频文件"
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let chunk = try? JSONDecoder().decode(VoiceStreamChunk.self, from: messageData),
              VoiceStreamValidator().validate(chunk) == nil,
              chunk.direction == .uplink else { return }
        Task { @MainActor in self.relay.forwardStreamChunk(chunk) }
    }

    /// ESS-321 real-time uplink dispatch. Called from `didReceiveMessage`
    /// when the payload carries a `RealtimeUplinkEnvelope`.
    @MainActor
    private func handleRealtimeUplink(data: Data) {
        guard let envelope = try? JSONDecoder().decode(RealtimeUplinkEnvelope.self, from: data),
              envelope.protocolVersion == RealtimeWireVersion.uplink else { return }
        // ESS-843 降级：万能 token 模式下跳过 token 铸造/缓冲，直接转发。
        // token 铸造的异步时序正是丢帧根因——绕过它，让音频帧即刻直达 WSS。
        if !AudioRealtimeAgentFeatureFlag.devUniversalToken.isEmpty {
            forwardRealtimeEnvelope(envelope)
            return
        }
        guard agentFlag.isDirectPathEnabled else {
            forwardRealtimeEnvelope(envelope)
            return
        }
        guard let identity = Self.turnIdentity(for: envelope) else {
            forwardRealtimeEnvelope(envelope)
            return
        }

        let turn = AgentTokenMintState.Turn(requestId: identity.requestId, sessionId: identity.sessionId)
        if agentTokenState.turn == turn,
           agentEphemeralToken != nil {
            forwardRealtimeEnvelope(envelope)
            return
        }
        if agentTokenState.failedTurn == turn {
            // Minting already failed for this turn. Keep the entire turn on
            // Bridge; never retry mid-turn and create a second execution.
            forwardRealtimeEnvelope(envelope)
            return
        }

        if agentTokenState.activate(turn) {
            agentTokenTask?.cancel()
            agentTokenTask = nil
            agentEphemeralToken = nil
            _ = pendingAgentEnvelopes.drain()
        }
        switch pendingAgentEnvelopes.append(envelope, encodedByteCount: data.count) {
        case .buffered:
            break
        case .overflow(let buffered, let incoming, let snapshot):
            agentTokenTask?.cancel()
            agentEphemeralToken = nil
            guard agentTokenState.markCurrentTurnFailed(turn) else { return }
            Self.logAgentFallback(reason: "buffer_overflow", snapshot: snapshot, degradedCount: buffered.count + 1)
            for item in buffered { forwardRealtimeEnvelope(item) }
            forwardRealtimeEnvelope(incoming)
            return
        }
        guard agentTokenTask == nil else { return }
        guard let taskID = agentTokenState.registerTask() else { return }
        agentTokenTask = Task { [weak self] in
            await self?.mintAgentTokenAndDrain(turn: turn, taskID: taskID)
        }
    }

    /// The ACK closes Watch-side flow control only after the selected WSS
    /// transport reports the append sent. Delivery failure tears down the
    /// realtime session; a lost ACK leaves the 256 KB safety limit intact.
    private func forwardRealtimeEnvelope(_ envelope: RealtimeUplinkEnvelope) {
        realtimeSession.forward(envelope) { [weak self] forwarded in
            guard forwarded else { return }
            self?.acknowledgeRealtimeAppendIfNeeded(envelope)
        }
    }

    private func acknowledgeRealtimeAppendIfNeeded(_ envelope: RealtimeUplinkEnvelope) {
        guard envelope.kind == .audioAppend,
              let chunk = envelope.append,
              !chunk.payload.isEmpty,
              VoiceStreamValidator().validate(chunk) == nil,
              let data = try? JSONEncoder().encode(RealtimeUplinkAck(
                requestId: chunk.requestId,
                sessionId: chunk.streamId,
                sequence: chunk.sequence,
                byteCount: chunk.payload.count
              )) else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(
            [RealtimeMediaMessage.uplinkAckEnvelopeKey: data],
            replyHandler: nil,
            errorHandler: { error in
                Self.logger.info(
                    "realtime uplink ack lost request=\(chunk.requestId.prefix(8), privacy: .public) sequence=\(chunk.sequence, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        )
    }

    private func sendRealtimeChannelReady(requestId: String, sessionId: String) {
        let ready = RealtimeChannelReady(requestId: requestId, sessionId: sessionId)
        pendingRealtimeChannelReady = ready
        interactiveReadyDelivered = nil
        durableTracker.reset()
        deliverRealtimeChannelReady(ready, trigger: "session_active")
    }

    private func replayRealtimeChannelReady(trigger: String) {
        guard let ready = pendingRealtimeChannelReady else { return }
        deliverRealtimeChannelReady(ready, trigger: trigger)
    }

    private func deliverRealtimeChannelReady(_ ready: RealtimeChannelReady, trigger: String) {
        guard let data = try? JSONEncoder().encode(ready) else { return }
        let session = WCSession.default
        switch RealtimeChannelReadyDeliveryPolicy.action(
            isActivated: session.activationState == .activated,
            isReachable: session.isReachable,
            isWatchAppInstalled: session.isWatchAppInstalled
        ) {
        case .interactive:
            // Repeated reachability callbacks must not emit duplicates.
            guard interactiveReadyDelivered != ready else { return }
            interactiveReadyDelivered = ready
            session.sendMessage(
                [RealtimeMediaMessage.channelReadyEnvelopeKey: data],
                replyHandler: nil,
                errorHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.handleChannelReadyInteractiveFailure(ready, data: data, trigger: trigger, error: error)
                    }
                }
            )
            PhoneAgentClientLog.info(
                module: "agent_transport", event: "channel_ready_sent",
                requestId: ready.requestId, sessionId: ready.sessionId,
                detail: "trigger=\(trigger)"
            )
        case .durable:
            // ESS-869: the Watch is unreachable. Do NOT drop the ready — hand it
            // to the system-managed reliable `transferUserInfo` queue, which
            // delivers when the Watch is reachable without relying on the phone
            // app observing a reachability change. The pending value is also
            // kept so the interactive fast path can still fire on replay.
            PhoneAgentClientLog.info(
                module: "agent_transport", event: "channel_ready_deferred",
                requestId: ready.requestId, sessionId: ready.sessionId,
                detail: "reason=watch_unreachable trigger=\(trigger)"
            )
            enqueueRealtimeChannelReadyDurable(ready, data: data, trigger: trigger)
        case .none:
            // Not activated / Watch app missing: nothing can be handed to the
            // system yet. Keep the pending value; activation replay delivers it.
            PhoneAgentClientLog.info(
                module: "agent_transport", event: "channel_ready_deferred",
                requestId: ready.requestId, sessionId: ready.sessionId,
                detail: "reason=session_unavailable trigger=\(trigger)"
            )
        }
    }

    /// System-managed reliable delivery for a deferred/failed interactive ready.
    /// `transferUserInfo` is FIFO and acknowledged via `didFinish userInfoTransfer`,
    /// which emits the `channel_ready_durable_delivered` success event that pairs
    /// with `channel_ready_deferred` by request_id (ESS-869 acceptance §2).
    private func enqueueRealtimeChannelReadyDurable(
        _ ready: RealtimeChannelReady, data: Data, trigger: String
    ) {
        guard case .enqueue(let attempt) = durableTracker.requestEnqueue(ready) else {
            return
        }
        WCSession.default.transferUserInfo([RealtimeMediaMessage.channelReadyEnvelopeKey: data])
        PhoneAgentClientLog.info(
            module: "agent_transport", event: "channel_ready_durable_enqueued",
            requestId: ready.requestId, sessionId: ready.sessionId,
            detail: "trigger=\(trigger) attempt=\(attempt)"
        )
    }

    /// System receipt for a durable channel-ready delivery. Clears the in-flight
    /// dedup marker on every terminal receipt, then either marks delivered,
    /// retries (bounded), or records a terminal give-up — a failed receipt must
    /// never leave the marker set and block the same request_id forever.
    private func handleChannelReadyDurableReceipt(
        _ ready: RealtimeChannelReady, error: Error?
    ) {
        guard let outcome = durableTracker.recordReceipt(ready, delivered: error == nil) else {
            // Delivered (nil outcome) or a stale receipt for another turn.
            if error == nil {
                PhoneAgentClientLog.info(
                    module: "agent_transport", event: "channel_ready_durable_delivered",
                    requestId: ready.requestId, sessionId: ready.sessionId
                )
            }
            return
        }
        PhoneAgentClientLog.error(
            module: "agent_transport", event: "channel_ready_durable_failed",
            requestId: ready.requestId, sessionId: ready.sessionId,
            detail: error?.localizedDescription ?? "unknown",
            code: "ERR_CHANNEL_READY_DURABLE"
        )
        switch outcome {
        case .retry:
            guard let data = try? JSONEncoder().encode(ready) else { return }
            enqueueRealtimeChannelReadyDurable(ready, data: data, trigger: "durable_retry")
        case .giveUp:
            // Terminal for the durable path; the interactive path can still
            // deliver on a later reachability callback. Log a definite defect.
            PhoneAgentClientLog.error(
                module: "agent_transport", event: "channel_ready_durable_gave_up",
                requestId: ready.requestId, sessionId: ready.sessionId,
                detail: "attempts=\(durableTracker.attempts)",
                code: "ERR_CHANNEL_READY_DURABLE"
            )
        }
    }

    private func handleChannelReadyInteractiveFailure(
        _ ready: RealtimeChannelReady, data: Data, trigger: String, error: Error
    ) {
        PhoneAgentClientLog.error(
            module: "agent_transport", event: "channel_ready_send_failed",
            requestId: ready.requestId, sessionId: ready.sessionId,
            detail: "trigger=\(trigger) \(error.localizedDescription)",
            code: "ERR_CHANNEL_READY_SEND"
        )
        // The interactive send failed despite the session reporting reachable;
        // fall back to the reliable channel rather than dropping the ready.
        enqueueRealtimeChannelReadyDurable(ready, data: data, trigger: trigger)
    }

    private static func turnIdentity(for envelope: RealtimeUplinkEnvelope) -> (requestId: String, sessionId: String)? {
        switch envelope.kind {
        case .streamStart:
            return envelope.start.map { ($0.requestId, $0.sessionId) }
        case .audioAppend:
            return envelope.append.map { ($0.requestId, $0.streamId) }
        case .audioCommit:
            return envelope.commit.map { ($0.requestId, $0.sessionId) }
        case .playbackStarted, .playbackEnded:
            return envelope.playback.map { ($0.requestId, $0.sessionId) }
        case .bargeInRequest:
            return envelope.bargeIn.map { ($0.requestId, $0.sessionId) }
        case .fallback:
            return nil
        }
    }

    private func mintAgentTokenAndDrain(turn: AgentTokenMintState.Turn, taskID: UUID) async {
        defer {
            if agentTokenState.finish(taskId: taskID, turn: turn) {
                agentTokenTask = nil
            }
        }
        guard let credentials = RelayCredentialsStore.read(),
              let gatewayURL = URL(string: agentFlag.gatewayURLString) else {
            drainPendingAgentEnvelopesToBridge(
                reason: "missing_credentials_or_gateway", turn: turn, taskID: taskID
            )
            return
        }
        do {
            let issued = try await AgentSessionTokenClient(
                gatewayURL: gatewayURL,
                credentials: credentials
            ).mint(requestId: turn.requestId, sessionId: turn.sessionId, generation: 1)
            guard agentTokenState.owns(taskId: taskID, turn: turn) else { return }
            agentEphemeralToken = issued.token
            let (buffered, _) = pendingAgentEnvelopes.drain()
            Self.logger.info(
                "agent ephemeral token minted request=\(turn.requestId.prefix(8), privacy: .public) session=\(turn.sessionId.prefix(8), privacy: .public) ttl_ms=\(issued.ttlMs, privacy: .public)"
            )
            for envelope in buffered { forwardRealtimeEnvelope(envelope) }
        } catch {
            guard agentTokenState.owns(taskId: taskID, turn: turn) else { return }
            Self.logger.error(
                "agent token mint failed request=\(turn.requestId.prefix(8), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            drainPendingAgentEnvelopesToBridge(
                reason: AgentTokenFallbackReason.reason(for: error), turn: turn, taskID: taskID
            )
        }
    }

    private func drainPendingAgentEnvelopesToBridge(
        reason: String, turn: AgentTokenMintState.Turn, taskID: UUID
    ) {
        guard agentTokenState.markFailed(taskId: taskID, turn: turn) else { return }
        agentEphemeralToken = nil
        let (buffered, snapshot) = pendingAgentEnvelopes.drain()
        Self.logAgentFallback(reason: reason, snapshot: snapshot, degradedCount: buffered.count)
        for envelope in buffered { forwardRealtimeEnvelope(envelope) }
    }

    private static func logAgentFallback(
        reason: String,
        snapshot: AgentEnvelopeBuffer.Snapshot,
        degradedCount: Int
    ) {
        logger.notice(
            "agent direct fallback reason=\(reason, privacy: .public) buffered_count=\(snapshot.envelopeCount, privacy: .public) buffered_bytes=\(snapshot.byteCount, privacy: .public) waited_ms=\(snapshot.waitedMilliseconds, privacy: .public) degraded_count=\(degradedCount, privacy: .public)"
        )
    }

    /// Agent/Bridge → iPhone → Watch realtime downlink.
    ///
    /// ESS-773：realtime envelope 在 Watch 可达时必须**只走一条投递路径**。
    /// 通用 outbox 故意双发（`transferUserInfo` 保底 + `sendMessage` 低延迟），
    /// 这对幂等状态消息是对的，对有序媒体流是错的：持久副本可能在
    /// `audio.done` 之后才到并重放 seq 0…N，Watch 会把它当成第二条乱序流
    /// 直接按 `sessionEnded` 丢弃。
    ///
    /// ESS-751：返回值告诉 `PhoneRealtimeSession` 这条能不能忘掉——只有**持久
    /// 队列真正接手**（或永久不可投递且已留痕）才是 `.handled`；只走了尽力而为
    /// 通道时必须 `.deferred`，留给断连重放。
    ///
    /// 两者合起来的口径：可达 → 交互通道单发，投递结果未知，故 `.deferred`
    /// （由 Watch 侧回执/重连重放收口）；不可达或交互通道报错 → 进持久队列，
    /// 由 `enqueueDownlink` 的返回值决定。
    @MainActor
    private func forwardRealtimeDownlink(
        _ envelope: RealtimeDownlinkEnvelope
    ) -> RealtimeDownlinkDisposition {
        guard let data = try? JSONEncoder().encode(envelope) else {
            // 编码是确定性的，重放只会再失败一次；缓存它只会漏内存，但要留痕。
            Self.downlinkLogger.error(
                "realtime downlink encode failed request_id=\(envelope.requestId, privacy: .public) kind=\(envelope.kind.rawValue, privacy: .public)"
            )
            return .handled
        }
        let session = WCSession.default
        guard RealtimeDownlinkDeliveryPolicy.route(
            isActivated: session.activationState == .activated,
            isReachable: session.isReachable
        ) == .interactiveOnly else {
            return enqueueRealtimeDownlinkFallback(
                envelope: envelope, data: data, reason: "unreachable"
            )
        }
        session.sendMessage(
            [RealtimeMediaMessage.downlinkEnvelopeKey: data],
            replyHandler: nil
        ) { [weak self] error in
            Task { @MainActor in
                _ = self?.enqueueRealtimeDownlinkFallback(
                    envelope: envelope,
                    data: data,
                    reason: "interactive_failed:\(error.localizedDescription)"
                )
            }
        }
        // 交互通道是尽力而为：`sendMessage` 无回执即成功未知。保守记 `.deferred`，
        // 让断连缓冲留一份，由重连重放兜底——ESS-751 的整条链路正是为此存在。
        return .deferred
    }

    @MainActor
    @discardableResult
    private func enqueueRealtimeDownlinkFallback(
        envelope: RealtimeDownlinkEnvelope,
        data: Data,
        reason: String
    ) -> RealtimeDownlinkDisposition {
        Self.downlinkLogger.notice(
            "realtime downlink durable fallback request_id=\(envelope.requestId, privacy: .public) kind=\(envelope.kind.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
        return enqueueDownlink(
            requestId: envelope.requestId,
            kind: .relayStatus,
            key: RealtimeMediaMessage.downlinkEnvelopeKey,
            data: data
        )
    }

    /// ESS-751：断连重放的真实触发点。WCSession activation / reachability /
    /// watch-state 恢复时调用；会话还没构造或缓冲为空时是空操作。
    private func replayRealtimeDownlink(trigger: String) {
        guard let session = realtimeSessionStorage, session.pendingDownlinkStats.count > 0 else { return }
        session.replayPendingDownlink(trigger: trigger)
    }

    /// Transport factory that selects Bridge or Agent path based on the
    /// `AudioRealtimeAgentFeatureFlag`. Returns `nil` if neither path is
    /// available (watch side treats that as a transport failure and falls
    /// back to the full-file relay flow).
    ///
    /// **Agent path**: creates a `PhoneRealtimeAgentTransport` wrapping an
    /// `AudioRealtimeAgentSession`. The token must already be obtained via
    /// `POST /v1/realtime/session-token` (ESS-401 integration). Currently
    /// the token is passed via `agentEphemeralToken` — a downstream
    /// ESS-401 integration must refresh it per turn.
    ///
    /// **Bridge path**: the existing `PhoneRealtimeWebSocketTransport` using
    /// the relay's signed WSS endpoint (PR #113).
    @MainActor
    private func makeRealtimeTransport(requestId: String, sessionId: String) -> PhoneRealtimeSession.Transport? {
        // ESS-391: try Agent direct path first when feature flag is enabled.
        if let credentials = RelayCredentialsStore.read(),
           let agentConfig = agentFlag.resolveConfig(
               ephemeralToken: agentEphemeralToken ?? "", deviceId: credentials.deviceId
           ) {
            // Gateway tokens are single-upgrade. Never reuse a session whose
            // transport was configured with the preceding turn's token.
            let session = AudioRealtimeAgentSession(config: agentConfig, sessionId: sessionId)
            agentSession = session
            let transport = PhoneRealtimeAgentTransport(
                config: agentConfig,
                agentSession: session,
                requestId: requestId,
                sessionId: sessionId,
                generation: 1,
                replacementSession: { [agentFlag] generation in
                    guard let credentials = RelayCredentialsStore.read(),
                          let gatewayURL = URL(string: agentFlag.gatewayURLString) else {
                        throw AgentSessionTokenError.invalidGatewayURL
                    }
                    // ESS-843 降级：万能 token 模式直接复用，不再铸造。
                    let token: String
                    if !AudioRealtimeAgentFeatureFlag.devUniversalToken.isEmpty {
                        token = AudioRealtimeAgentFeatureFlag.devUniversalToken
                    } else {
                        let issued = try await AgentSessionTokenClient(
                            gatewayURL: gatewayURL, credentials: credentials
                        ).mint(requestId: requestId, sessionId: sessionId, generation: generation)
                        token = issued.token
                    }
                    guard let freshConfig = agentFlag.resolveConfig(
                        ephemeralToken: token, deviceId: credentials.deviceId
                    ) else {
                        throw AgentSessionTokenError.invalidGatewayURL
                    }
                    return AudioRealtimeAgentSession(config: freshConfig, sessionId: sessionId)
                }
            )
            transport.onDownlink = { [weak self, weak transport] envelope in
                guard let self, let transport else { return }
                self.realtimeSession.receiveAgentDownlink(envelope, from: transport)
            }
            transport.onStateChange = { [weak self, weak transport] state in
                guard let self, let transport else { return }
                Self.logger.info("agent transport state → \(String(describing: state), privacy: .public)")
                self.realtimeSession.agentTransportDidChangeState(state, from: transport)
            }
            realtimeSession.isAgentTransport = true
            Self.logger.info(
                "agent transport created for rid=\(requestId.prefix(8), privacy: .public)"
            )
            return transport
        }

        // Fallback to Bridge path
        guard let credentials = RelayCredentialsStore.read(),
              var components = URLComponents(string: relay.bridgeURLString) else { return nil }
        components.scheme = "wss"
        components.path = "/v1/voice/realtime"
        components.queryItems = [
            URLQueryItem(name: "request_id", value: requestId),
            URLQueryItem(name: "session_id", value: sessionId)
        ]
        guard let url = components.url else { return nil }
        let builder = RelaySignedRequestBuilder(
            baseURL: url.deletingLastPathComponent(), credentials: credentials
        )
        var request = builder.request(
            method: "GET", path: "/v1/voice/realtime",
            requestId: requestId, body: nil
        )
        request.url = url
        let task = URLSession.shared.webSocketTask(with: request)
        realtimeSession.isAgentTransport = false
        return PhoneRealtimeWebSocketTransport(task: task)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        if let ackData = userInfo[ResultDeliveryAckMessage.envelopeKey] as? Data,
           let ack = ResultDeliveryAck.decode(from: ackData) {
            Task { @MainActor in self.relay.acknowledgeResult(requestId: ack.requestId) }
            return
        }
        if let ackData = userInfo[ProbeAckMessage.envelopeKey] as? Data,
           let ack = ProbeAckEnvelope.decode(from: ackData) {
            Task { @MainActor in self.relay.postProbeAck(ack) }
            return
        }
        if let summaryData = userInfo[WatchClientLogMessage.selfCheckSummaryKey] as? Data {
            Task { @MainActor in self.ingestSelfCheckSummary(data: summaryData) }
            return
        }
    }

    /// ESS-137：Watch 端 selfcheck_finished 的快速旁路 microchunk 落地。
    /// 同一 chunk_id 可能通过 sendMessage 与 transferUserInfo 两条子路径
    /// 各到一次（Watch 侧不可达期间只入 transferUserInfo，reachable 恢复
    /// 后补发 sendMessage）——`ClientLogUplink.enqueue` 以 chunkId 为文件名，
    /// 覆盖写幂等，交给 Bridge 后 `/v1/client-logs` 再按 chunk_id 幂等窗
    /// 去重，`bridge.log` 里只会出现一条。旁路与主路径 chunk_id 各自独立、
    /// 不跨路去重，详见 `SelfCheckSummaryPayload` 类型注释。
    @MainActor
    private func ingestSelfCheckSummary(data: Data) {
        guard let payload = SelfCheckSummaryPayload.decode(from: data) else {
            Self.logger.error("watch selfcheck summary 无法解码（bytes=\(data.count, privacy: .public)）")
            return
        }
        guard let jsonlData = payload.jsonl.data(using: .utf8) else { return }
        relay.clientLogUplink.enqueue(chunkId: payload.chunkId, data: jsonlData)
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 系统会在本方法返回后删除临时文件，必须同步读出。
        guard let fileData = try? Data(contentsOf: file.fileURL) else { return }
        // Watch 交互日志 chunk（ESS-42）：入上送队列，异步转发 Bridge。
        if let chunkId = file.metadata?[WatchClientLogMessage.fileKey] as? String {
            Task { @MainActor in
                self.relay.clientLogUplink.enqueue(chunkId: chunkId, data: fileData)
            }
            return
        }
        guard let envelopeData = file.metadata?[VoiceMessage.envelopeKey] as? Data else { return }
        Task { @MainActor in
            self.ingestVoiceFile(envelopeData: envelopeData, audioData: fileData)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let stagedName = fileTransfer.file.fileURL.lastPathComponent
        let itemId = fileTransfer.file.metadata?[Self.downlinkItemIdKey] as? String
        let envelope = (fileTransfer.file.metadata?[VoiceSpeechMessage.envelopeKey] as? Data)
            .flatMap { try? VoiceStatusEnvelope.decode(from: $0) }
        let requestId = envelope?.requestId ?? "unknown"
        Self.logger.log("l2_transfer_finished request_id=\(requestId, privacy: .public) success=\(error == nil) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        Task { @MainActor in
            self.completeDownlink(itemId: itemId, error: error)
            // Relay 侧仍按原始文件名清理它自己的临时副本（暂存名形如 "<id>__<原名>"）。
            let originalName = stagedName.components(separatedBy: "__").last ?? stagedName
            self.relay.handleResultAudioTransferFinished(fileName: originalName, error: error)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext[HistoryMessage.key] as? Data else { return }
        Task { @MainActor in
            guard let entries = try? JSONDecoder().decode([ConversationHistoryEntry].self, from: data) else {
                return
            }
            self.history = entries
            UserDefaults.standard.set(data, forKey: self.historyStorageKey)
        }
    }
}

// MARK: - Relay → Watch 回执通道（ESS-28）

extension PhoneConnectivity: WatchFeedbackChannel {
    /// 下行条目 ID 随载荷同行，用于把 WCSession 的 didFinish 回执映射回队列条目。
    static let downlinkItemIdKey = "wristagent_downlink_item_id"

    func notifyWatch(status: RelayStatusUpdate) {
        guard let data = try? status.jsonData() else { return }
        enqueueDownlink(
            requestId: status.requestId, kind: .relayStatus,
            key: VoiceMessage.relayStatusKey, data: data
        )
    }

    func notifyWatch(progress: RelayStatusUpdate) {
        guard let data = try? progress.jsonData() else { return }
        enqueueDownlink(
            requestId: progress.requestId, kind: .progress,
            key: VoiceMessage.progressKey, data: data
        )
    }

    func notifyWatch(result: VoiceRelayResultPayload) {
        guard let data = try? result.jsonData() else { return }
        enqueueDownlink(
            requestId: result.requestId, kind: .result,
            key: VoiceMessage.resultKey, data: data
        )
    }

    /// 状态/权限/结果信封 → Watch VoiceTurnJournal（ESS-29 时间线；ESS-38 接通）。
    func notifyWatch(voiceStatus envelope: VoiceStatusEnvelope) {
        guard let data = try? envelope.jsonData() else { return }
        enqueueDownlink(
            requestId: envelope.requestId, kind: .voiceStatus,
            key: VoiceStatusMessage.envelopeKey, data: data
        )
    }

    func notifyWatch(resultAudioDegradation envelope: VoiceResultAudioDegradationEnvelope) {
        guard let data = try? envelope.jsonData() else { return }
        enqueueDownlink(
            requestId: envelope.requestId, kind: .resultAudioDegradation,
            key: VoiceResultAudioDegradationMessage.envelopeKey, data: data
        )
    }

    /// 结果语音走系统托管 transferFile；metadata 带含 speechSha256 的信封，
    /// Watch 端（WatchSettingsStore.storeSpeech）校验通过才加密入库并挂到回合。
    ///
    /// ESS-21 B1：音频先复制进下行队列自持有的目录再投递——调用方的临时文件
    /// 随时可能被清理，且会话未激活时本条必须留在队列里等重投，不能像原先那样直接 return。
    @discardableResult
    func transferSpeech(fileURL: URL, envelope: VoiceStatusEnvelope) -> Bool {
        guard let data = try? envelope.jsonData() else { return false }
        guard let downlink else {
            Self.downlinkLogger.error(
                "下行队列不可用，语音无法保证送达 request_id=\(envelope.requestId, privacy: .public)"
            )
            return false
        }
        guard let audio = try? Data(contentsOf: fileURL) else {
            Self.downlinkLogger.error(
                "结果语音读取失败 request_id=\(envelope.requestId, privacy: .public)"
            )
            return false
        }
        do {
            _ = try downlink.enqueueSpeech(
                requestId: envelope.requestId,
                messageKey: VoiceSpeechMessage.envelopeKey,
                envelope: data,
                audio: audio,
                fileName: fileURL.lastPathComponent
            )
        } catch {
            Self.downlinkLogger.error(
                "语音入队失败 request_id=\(envelope.requestId, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
        refreshDownlinkCount()
        flushDownlink(trigger: "speech-enqueue")
        return true
    }

    /// Bridge 仍回放 completed turn 说明业务 ACK 未到。WCSession 的 didFinish 不能作为
    /// 业务送达判据：先撤销已 delivered 的 speech tombstone，让紧随其后的 projection
    /// 能重新下载并入队；queued / inFlight 条目保持原样，由 flush 正常恢复。
    func retryPendingDownlinks(requestIds: [String], trigger: String) {
        requestIds.forEach { _ = downlink?.invalidateDeliveredSpeech(requestId: $0) }
        flushDownlink(trigger: trigger)
    }

    /// ESS-184/207 探针语音下行：与 transferSpeech 走同一 outbox 通道
    /// （transferFile + 系统托管队列），但用独立 kind/messageKey 让 Watch 端
    /// 走探针分支。不消耗结果链路的 ledger、不入 EncryptedAudioVault。
    @discardableResult
    func transferProbe(fileURL: URL, envelope: VoiceStatusEnvelope) -> Bool {
        guard let data = try? envelope.jsonData() else { return false }
        guard let downlink else {
            Self.downlinkLogger.error(
                "下行队列不可用，探针无法保证送达 request_id=\(envelope.requestId, privacy: .public)"
            )
            return false
        }
        guard let audio = try? Data(contentsOf: fileURL) else {
            Self.downlinkLogger.error(
                "探针语音读取失败 request_id=\(envelope.requestId, privacy: .public)"
            )
            return false
        }
        do {
            _ = try downlink.enqueueProbe(
                requestId: envelope.requestId,
                messageKey: VoiceProbeMessage.envelopeKey,
                envelope: data,
                audio: audio,
                fileName: fileURL.lastPathComponent
            )
        } catch {
            Self.downlinkLogger.error(
                "探针入队失败 request_id=\(envelope.requestId, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
        refreshDownlinkCount()
        flushDownlink(trigger: "probe-enqueue")
        return true
    }

    /// ESS-324 B4：Bridge WSS downlink stream chunk → Watch `sendMessageData`。
    ///
    /// **返回值语义（ESS-351）**：
    /// - `true` = `sendMessageData` 已提交至 WCSession 发送队列，**不等于 chunk 已送达 Watch**；
    /// - `false` = 同步守卫未通过（方向非 downlink、会话未激活/不可达、编码失败）。
    ///
    /// `WCSession.sendMessageData` 的失败经由异步 `errorHandler` 回调抵达；
    /// 此时函数早已返回 `true`。异步失败时 `errorHandler` 通过
    /// `relay.handleStreamChunkDeliveryFailed` 补偿降级信号，调用方不得仅凭
    /// 返回值决定是否回退整段 m4a（ESS-351）。
    @discardableResult
    func forwardStreamChunkToWatch(_ chunk: VoiceStreamChunk) -> Bool {
        guard chunk.direction == .downlink else {
            Self.downlinkLogger.warning("forwardStreamChunkToWatch: non-downlink chunk ignored")
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            Self.downlinkLogger.info("forwardStreamChunkToWatch: unreachable, fallback")
            return false
        }
        guard let data = try? JSONEncoder().encode(chunk) else {
            Self.downlinkLogger.error("forwardStreamChunkToWatch: encode failed")
            return false
        }
        session.sendMessageData(data, replyHandler: nil) { [weak self] error in
            Self.downlinkLogger.error("forwardStreamChunkToWatch: send failed error=\(error.localizedDescription)")
            // ESS-351：异步投递失败——补偿降级信号，让 relay 将此 request_id
            // 标记为需要整段 m4a 降级。不在此处自建重试/对账链路。
            self?.relay.handleStreamChunkDeliveryFailed(requestId: chunk.requestId)
        }
        Self.downlinkLogger.debug("forwardStreamChunkToWatch: sent seq=\(chunk.sequence) request_id=\(chunk.requestId)")
        return true
    }

    /// 返回值表示持久队列是否接手：`.handled` 才允许调用方忘掉这条下行；
    /// `.deferred` 说明只走了尽力而为通道，调用方需自行保留重投（ESS-751）。
    @discardableResult
    private func enqueueDownlink(
        requestId: String, kind: WatchDownlinkKind, key: String, data: Data
    ) -> RealtimeDownlinkDisposition {
        guard let downlink else {
            // 队列不可用时退回旧的尽力而为通道，但明确留痕，不假装成功。
            Self.downlinkLogger.error(
                "下行队列不可用，退回尽力而为通道 request_id=\(requestId, privacy: .public)"
            )
            bestEffortSend(key: key, data: data)
            return .deferred
        }
        do {
            _ = try downlink.enqueue(
                requestId: requestId, kind: kind, messageKey: key, payload: data
            )
        } catch {
            Self.downlinkLogger.error(
                "下行入队失败 request_id=\(requestId, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            bestEffortSend(key: key, data: data)
            return .deferred
        }
        refreshDownlinkCount()
        flushDownlink(trigger: "enqueue")
        return .handled
    }

    /// 排空下行队列。会话未激活/未安装 Watch App 时**不投递也不丢弃**，
    /// 条目留在队列里，等 activation / reachability / watch-state 变化再来。
    func flushDownlink(trigger: String) {
        guard let downlink else { return }
        let session = WCSession.default
        let due = downlink.dueItems()
        guard !due.isEmpty else {
            refreshDownlinkCount()
            return
        }
        guard WCSession.isSupported(), session.activationState == .activated else {
            due.forEach { downlink.markDeferred(id: $0.id, reason: "session-not-activated:\(trigger)") }
            refreshDownlinkCount()
            return
        }
        guard session.isWatchAppInstalled else {
            due.forEach { downlink.markDeferred(id: $0.id, reason: "watch-app-not-installed:\(trigger)") }
            refreshDownlinkCount()
            return
        }

        for item in due {
            guard let payload = try? downlink.payload(for: item.id) else {
                downlink.markFailed(id: item.id, reason: "payload-missing")
                continue
            }
            switch item.kind {
            case .speech, .probe:
                guard let audioURL = downlink.stagedAudioURL(for: item.id) else {
                    downlink.markFailed(id: item.id, reason: "staged-audio-missing")
                    continue
                }
                downlink.markInFlight(id: item.id)
                session.transferFile(audioURL, metadata: [
                    item.messageKey: payload,
                    Self.downlinkItemIdKey: item.id
                ])
            case .relayStatus, .progress, .result, .voiceStatus, .resultAudioDegradation:
                downlink.markInFlight(id: item.id)
                // transferUserInfo 是系统托管的可靠队列，且有 didFinish 回执——
                // 它、而不是 sendMessage，才是「送达」的判据。
                session.transferUserInfo([
                    item.messageKey: payload,
                    Self.downlinkItemIdKey: item.id
                ])
                // Realtime fallback is already here because the interactive
                // send was unavailable/failed. Sending it on BOTH channels
                // would reintroduce the duplicate/out-of-order stream that
                // ESS-773 removes. Other idempotent status payloads retain
                // the latency optimization.
                if session.isReachable,
                   RealtimeDownlinkDeliveryPolicy.shouldAddInteractiveCopyToDurable(
                       messageKey: item.messageKey
                   ) {
                    session.sendMessage([item.messageKey: payload], replyHandler: nil, errorHandler: { _ in })
                }
            }
        }
        refreshDownlinkCount()
        scheduleDownlinkRetry()
    }

    /// 系统回执落地：成功转 delivered 并删载荷，失败退避重投。
    private func completeDownlink(itemId: String?, error: Error?) {
        guard let downlink else { return }
        if let itemId {
            if let error {
                downlink.markFailed(id: itemId, reason: error.localizedDescription)
            } else {
                downlink.markDelivered(id: itemId)
            }
        }
        refreshDownlinkCount()
        scheduleDownlinkRetry()
    }

    private func scheduleDownlinkRetry() {
        guard let downlink, let next = downlink.earliestNextAttempt() else { return }
        let delay = max(0.5, next.timeIntervalSinceNow)
        downlinkFlushTask?.cancel()
        downlinkFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushDownlink(trigger: "retry") }
        }
    }

    private func refreshDownlinkCount() {
        downlink?.purgeExpired()
        pendingDownlinkCount = downlink?.pendingCount() ?? 0
        pushDownlinkBacklog()
    }

    /// ESS-307：将下行队列积压信息推送到 Watch，让用户可见「还有 N 条结果没到」。
    private func pushDownlinkBacklog() {
        guard let downlink else { return }
        let queuedIds = downlink.items
            .filter { $0.state != .delivered }
            .map { $0.requestId }
        let payload = DownlinkBacklogPayload(
            pendingCount: pendingDownlinkCount,
            queuedRequestIds: queuedIds,
            updatedAt: Date()
        )
        guard let data = try? payload.jsonData() else { return }
        do {
            try WCSession.default.updateApplicationContext([
                DownlinkBacklogMessage.contextKey: data
            ])
        } catch {
            Self.downlinkLogger.error("下行积压推送失败: \(error.localizedDescription)")
        }
    }

    /// 队列不可用时的降级路径（尽力而为，无回执）。
    private func bestEffortSend(key: String, data: Data) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage([key: data], replyHandler: nil) { _ in
                session.transferUserInfo([key: data])
            }
        } else {
            session.transferUserInfo([key: data])
        }
    }

    fileprivate static func logDownlink(_ event: WatchDownlinkLogEvent) {
        switch event {
        case .enqueued(let requestId, let kind, let itemId):
            downlinkLogger.info("downlink enqueued request_id=\(requestId, privacy: .public) kind=\(kind.rawValue, privacy: .public) item=\(itemId, privacy: .public)")
        case .duplicate(let requestId, let kind, let itemId):
            downlinkLogger.debug("downlink duplicate request_id=\(requestId, privacy: .public) kind=\(kind.rawValue, privacy: .public) item=\(itemId, privacy: .public)")
        case .deferred(let requestId, let kind, let itemId, let reason):
            downlinkLogger.notice("downlink deferred request_id=\(requestId, privacy: .public) kind=\(kind.rawValue, privacy: .public) item=\(itemId, privacy: .public) reason=\(reason, privacy: .public)")
        case .attempted(let requestId, let kind, let itemId, let attempt):
            downlinkLogger.info("downlink attempt request_id=\(requestId, privacy: .public) kind=\(kind.rawValue, privacy: .public) item=\(itemId, privacy: .public) attempt=\(attempt)")
        case .delivered(let requestId, let kind, let itemId, let attempt):
            downlinkLogger.info("downlink delivered request_id=\(requestId, privacy: .public) kind=\(kind.rawValue, privacy: .public) item=\(itemId, privacy: .public) attempt=\(attempt)")
        case .failed(let requestId, let kind, let itemId, let attempt, let reason):
            downlinkLogger.error("downlink failed request_id=\(requestId, privacy: .public) kind=\(kind.rawValue, privacy: .public) item=\(itemId, privacy: .public) attempt=\(attempt) reason=\(reason, privacy: .public)")
        case .expired(let requestId, let kind, let itemId):
            downlinkLogger.error("downlink expired request_id=\(requestId, privacy: .public) kind=\(kind.rawValue, privacy: .public) item=\(itemId, privacy: .public)")
        case .speechBacklogSuppressed(let suppressed, let kept, let requestId):
            // ESS-306：下行语音积压超上限时抑制旧条目，只留最新一条。
            // 抑制是有意为之而非故障，用 notice 级别——但必须可见，
            // 否则用户会遇到「有几轮结果没播」而日志里查不到原因。
            downlinkLogger.notice("downlink speech backlog suppressed request_id=\(requestId, privacy: .public) suppressed=\(suppressed) kept=\(kept, privacy: .public)")
        case .persistFailed(let operation, let reason):
            downlinkLogger.fault("downlink index persist failed operation=\(operation, privacy: .public) reason=\(reason, privacy: .public)")
        }
    }
}
