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
    private lazy var realtimeSession: PhoneRealtimeSession = {
        let session = PhoneRealtimeSession(transportFactory: { [weak self] requestId, sessionId in
            self?.makeRealtimeTransport(requestId: requestId, sessionId: sessionId)
        })
        session.onDownlink = { [weak self] envelope in
            self?.forwardRealtimeDownlink(envelope)
        }
        return session
    }()
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
    private var agentTokenTaskID: UUID?
    private var agentTokenTurn: (requestId: String, sessionId: String)?
    private var agentTokenFailedTurn: (requestId: String, sessionId: String)?
    private var pendingConfiguration: AgentConfiguration?
    private let historyStorageKey = "wristagent.phone.conversation.history"
    private let voiceInbox: VoiceRequestInbox?
    /// ESS-21 B1：iPhone → Watch 下行持久化队列。会话未激活时排队重投，不静默丢弃。
    private let downlink: WatchDownlinkOutbox?
    private var downlinkFlushTask: Task<Void, Never>?
    private static let downlinkLogger = Logger(
        subsystem: "beer.workspace.wristagent", category: "watch-downlink"
    )

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        voiceInbox = try? VoiceRequestInbox(directory: base.appendingPathComponent("VoiceInbox", isDirectory: true))
        downlink = try? WatchDownlinkOutbox(
            directory: base.appendingPathComponent("WatchDownlink", isDirectory: true),
            log: { event in PhoneConnectivity.logDownlink(event) }
        )
        relay = WristAgentPhoneRelay()
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
        // 冷启动补投：上次进程排队/在途未确认的下行，App 一打开就重投。
        flushDownlink(trigger: "activate")
    }

    func send(_ configuration: AgentConfiguration) {
        pendingConfiguration = configuration
        guard WCSession.default.activationState == .activated else { return }
        do {
            let data = try JSONEncoder().encode(configuration)
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
            self.flushDownlink(trigger: "reachability")
            self.relay.resumeEvents(trigger: "wc-reachability")
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
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
        guard agentFlag.isDirectPathEnabled else {
            realtimeSession.forward(envelope)
            return
        }
        guard let identity = Self.turnIdentity(for: envelope) else {
            realtimeSession.forward(envelope)
            return
        }

        if agentTokenTurn?.requestId == identity.requestId,
           agentTokenTurn?.sessionId == identity.sessionId,
           agentEphemeralToken != nil {
            realtimeSession.forward(envelope)
            return
        }
        if agentTokenFailedTurn?.requestId == identity.requestId,
           agentTokenFailedTurn?.sessionId == identity.sessionId {
            // Minting already failed for this turn. Keep the entire turn on
            // Bridge; never retry mid-turn and create a second execution.
            realtimeSession.forward(envelope)
            return
        }

        if agentTokenTurn?.requestId != identity.requestId || agentTokenTurn?.sessionId != identity.sessionId {
            agentTokenTask?.cancel()
            agentTokenTask = nil
            agentTokenTaskID = nil
            agentEphemeralToken = nil
            agentTokenFailedTurn = nil
            _ = pendingAgentEnvelopes.drain()
            agentTokenTurn = identity
        }
        switch pendingAgentEnvelopes.append(envelope, encodedByteCount: data.count) {
        case .buffered:
            break
        case .overflow(let buffered, let incoming, let snapshot):
            agentTokenTask?.cancel()
            agentEphemeralToken = nil
            agentTokenFailedTurn = agentTokenTurn
            Self.logAgentFallback(reason: "buffer_overflow", snapshot: snapshot, degradedCount: buffered.count + 1)
            for item in buffered { realtimeSession.forward(item) }
            realtimeSession.forward(incoming)
            return
        }
        guard agentTokenTask == nil else { return }
        let taskID = UUID()
        agentTokenTaskID = taskID
        agentTokenTask = Task { [weak self] in
            await self?.mintAgentTokenAndDrain(
                requestId: identity.requestId,
                sessionId: identity.sessionId,
                taskID: taskID
            )
        }
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

    private func mintAgentTokenAndDrain(requestId: String, sessionId: String, taskID: UUID) async {
        defer {
            if agentTokenTaskID == taskID {
                agentTokenTask = nil
                agentTokenTaskID = nil
            }
        }
        guard let credentials = RelayCredentialsStore.read(),
              credentials.deviceId == agentFlag.deviceId,
              let gatewayURL = URL(string: agentFlag.gatewayURLString) else {
            drainPendingAgentEnvelopesToBridge(reason: "missing_credentials_or_gateway")
            return
        }
        do {
            let issued = try await AgentSessionTokenClient(
                gatewayURL: gatewayURL,
                credentials: credentials
            ).mint(requestId: requestId, sessionId: sessionId, generation: 1)
            guard agentTokenTurn?.requestId == requestId,
                  agentTokenTurn?.sessionId == sessionId,
                  agentTokenFailedTurn?.requestId != requestId || agentTokenFailedTurn?.sessionId != sessionId else { return }
            agentEphemeralToken = issued.token
            let (buffered, _) = pendingAgentEnvelopes.drain()
            Self.logger.info(
                "agent ephemeral token minted request=\(requestId.prefix(8), privacy: .public) session=\(sessionId.prefix(8), privacy: .public) ttl_ms=\(issued.ttlMs, privacy: .public)"
            )
            for envelope in buffered { realtimeSession.forward(envelope) }
        } catch {
            guard agentTokenTurn?.requestId == requestId,
                  agentTokenTurn?.sessionId == sessionId,
                  agentTokenFailedTurn?.requestId != requestId || agentTokenFailedTurn?.sessionId != sessionId else { return }
            Self.logger.error(
                "agent token mint failed request=\(requestId.prefix(8), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            drainPendingAgentEnvelopesToBridge(reason: AgentTokenFallbackReason.reason(for: error))
        }
    }

    private func drainPendingAgentEnvelopesToBridge(reason: String) {
        agentEphemeralToken = nil
        agentTokenFailedTurn = agentTokenTurn
        let (buffered, snapshot) = pendingAgentEnvelopes.drain()
        Self.logAgentFallback(reason: reason, snapshot: snapshot, degradedCount: buffered.count)
        for envelope in buffered { realtimeSession.forward(envelope) }
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

    /// Bridge → iPhone → Watch: enqueue a decoded downlink envelope onto the
    /// existing WatchDownlinkOutbox so it flows through the same durable
    /// queue that carries status envelopes.
    @MainActor
    private func forwardRealtimeDownlink(_ envelope: RealtimeDownlinkEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        enqueueDownlink(
            requestId: envelope.requestId,
            kind: .relayStatus,
            key: RealtimeMediaMessage.downlinkEnvelopeKey,
            data: data
        )
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
        if let agentConfig = agentFlag.resolveConfig(ephemeralToken: agentEphemeralToken ?? "") {
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
                          credentials.deviceId == agentFlag.deviceId,
                          let gatewayURL = URL(string: agentFlag.gatewayURLString) else {
                        throw AgentSessionTokenError.invalidGatewayURL
                    }
                    let issued = try await AgentSessionTokenClient(
                        gatewayURL: gatewayURL, credentials: credentials
                    ).mint(requestId: requestId, sessionId: sessionId, generation: generation)
                    guard let freshConfig = agentFlag.resolveConfig(ephemeralToken: issued.token) else {
                        throw AgentSessionTokenError.invalidGatewayURL
                    }
                    return AudioRealtimeAgentSession(config: freshConfig, sessionId: sessionId)
                }
            )
            transport.onDownlink = { [weak self] envelope in
                self?.forwardRealtimeDownlink(envelope)
            }
            transport.onStateChange = { [weak self] state in
                Self.logger.info("agent transport state → \(String(describing: state), privacy: .public)")
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

    private func enqueueDownlink(
        requestId: String, kind: WatchDownlinkKind, key: String, data: Data
    ) {
        guard let downlink else {
            // 队列不可用时退回旧的尽力而为通道，但明确留痕，不假装成功。
            Self.downlinkLogger.error(
                "下行队列不可用，退回尽力而为通道 request_id=\(requestId, privacy: .public)"
            )
            bestEffortSend(key: key, data: data)
            return
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
            return
        }
        refreshDownlinkCount()
        flushDownlink(trigger: "enqueue")
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
                // 可达时额外走一次即时通道降低延迟；失败无所谓，可靠性由上面那条兜底。
                if session.isReachable {
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
