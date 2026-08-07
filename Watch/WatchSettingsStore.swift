import Combine
import Foundation
import WatchConnectivity
import os

@MainActor
final class WatchSettingsStore: NSObject, ObservableObject, WCSessionDelegate {
    /// ESS-41 L3 取证：结果语音「到没到手表、为何被丢」全部走这条日志。
    private static let speechLogger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "SpeechStore")
    @Published private(set) var configuration: AgentConfiguration = .demo
    /// ESS-307：iPhone 下行队列积压数。Watch 主界面据此显示「还有 N 条结果没送到」。
    @Published private(set) var downlinkBacklogCount: Int = 0
    /// ESS-307：当前排队中的 requestId 列表，供时间线与 Gap-6 对齐。
    @Published private(set) var downlinkQueuedRequestIds: [String] = []
    /// ESS-419：WCSession 连接状态，供设置页「当前链路」只读状态行展示。
    @Published private(set) var wcSessionActivationState: WCSessionActivationState = .notActivated
    @Published private(set) var wcIsReachable: Bool = false
    /// 语音传输回调转发目标（WCSession 只允许一个 delegate）。
    weak var voiceTransport: WatchVoiceTransport?
    /// 状态/权限/结果事件入账目标（ESS-29）。
    weak var voiceJournal: VoiceTurnJournal?
    /// 结果语音的加密落盘仓（ESS-29）。
    weak var speechVault: EncryptedAudioVault?
    /// ESS-321 real-time downlink dispatch target. `PushToTalkController` sets
    /// this when the streaming gate is on so `audio.delta` envelopes arriving
    /// from iPhone can be routed into the real playback engine.
    weak var realtimeAdapter: WatchRealtimeMediaAdapter?
    /// ESS-324 B4：下行流式 chunk 接收器。
    weak var streamReceiver: WatchStreamReceiver?
    private let defaults = UserDefaults.standard
    private let storageKey = "wristagent.watch.configuration"

    override init() {
        super.init()
        if
            let data = defaults.data(forKey: storageKey),
            var saved = try? JSONDecoder().decode(AgentConfiguration.self, from: data)
        {
            saved.bearerToken = SecureTokenStore.read()
            configuration = saved
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()

        if let data = WCSession.default.receivedApplicationContext[ConfigurationMessage.key] as? Data {
            apply(data)
        }
        // ESS-307：冷启动恢复下行积压状态
        applyDownlinkBacklog(from: WCSession.default.receivedApplicationContext)
    }

    private func apply(_ data: Data) {
        guard let value = try? JSONDecoder().decode(AgentConfiguration.self, from: data) else { return }
        configuration = value
        SecureTokenStore.save(value.bearerToken)
        var redacted = value
        redacted.bearerToken = ""
        if let redactedData = try? JSONEncoder().encode(redacted) {
            defaults.set(redactedData, forKey: storageKey)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            WatchLog.error("wcsession", "activation_failed", error: error)
        } else {
            WatchLog.info("wcsession", "activation_completed", detail: "state=\(activationState.rawValue)")
        }
        Task { @MainActor in
            self.wcSessionActivationState = activationState
            self.wcIsReachable = session.isReachable
        }
        guard activationState == .activated else { return }
        Task { @MainActor in
            self.voiceTransport?.retryPending()
            WatchLogShipper.shared.ship(reason: "session_activated")
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.wcIsReachable = isReachable
            self.wcSessionActivationState = session.activationState
            self.voiceTransport?.handleReachabilityChange(isReachable: isReachable)
            // ESS-137：reachable 变 true 时补发 selfcheck_finished 快速旁路的
            // pending sendMessage，把不可达期间只入 transferUserInfo 的载荷
            // 升级到即时通道，满足「reachable 恢复后 5 秒内到 Bridge」契约。
            WatchLogShipper.shared.handleReachabilityChange(isReachable: isReachable)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let fileName = fileTransfer.file.fileURL.lastPathComponent
        // 日志 chunk 与语音上行共用 transferFile 回执，按 metadata 分流。
        let isLogChunk = fileTransfer.file.metadata?[WatchClientLogMessage.fileKey] != nil
        Task { @MainActor in
            if isLogChunk {
                WatchLogShipper.shared.handleTransferFinished(fileName: fileName, error: error)
            } else {
                self.voiceTransport?.handleTransferFinished(fileName: fileName, error: error)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        if let data = applicationContext[ConfigurationMessage.key] as? Data {
            Task { @MainActor in self.apply(data) }
        }
        applyDownlinkBacklog(from: applicationContext)
    }

    /// ESS-307：接收 iPhone 推送的下行队列积压信息。
    nonisolated func applyDownlinkBacklog(from applicationContext: [String: Any]) {
        guard let data = applicationContext[DownlinkBacklogMessage.contextKey] as? Data,
              let payload = try? DownlinkBacklogPayload.decode(from: data) else { return }
        Task { @MainActor in
            self.downlinkBacklogCount = payload.pendingCount
            self.downlinkQueuedRequestIds = payload.queuedRequestIds
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data
    ) {
        // ESS-324 B4：优先尝试 VoiceStreamChunk（downlink 方向）；命中后不进配置路径。
        if let chunk = try? JSONDecoder().decode(VoiceStreamChunk.self, from: messageData),
           chunk.direction == .downlink {
            Task { @MainActor in self.streamReceiver?.receive(chunk: chunk) }
            return
        }
        Task { @MainActor in self.apply(messageData) }
    }

    // MARK: - iPhone Relay 回执（ESS-28）＋ 状态/权限/结果事件（ESS-29）
    // 同一 WCSession delegate 同时服务两条链路：payload 按各自的 key 分流。

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        forwardRelayPayloads(in: message)
        if let data = message[VoiceResultAudioDegradationMessage.envelopeKey] as? Data {
            Task { @MainActor in self.applyAudioDegradation(data) }
        }
        if let data = message[RealtimeMediaMessage.downlinkEnvelopeKey] as? Data {
            Task { @MainActor in self.applyRealtimeDownlink(data) }
        }
        if let data = message[RealtimeMediaMessage.uplinkAckEnvelopeKey] as? Data,
           let ack = try? JSONDecoder().decode(RealtimeUplinkAck.self, from: data) {
            Task { @MainActor in self.realtimeAdapter?.receiveUplinkAck(ack) }
        }
        guard let data = message[VoiceStatusMessage.envelopeKey] as? Data else { return }
        Task { @MainActor in self.applyVoiceStatus(data) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        forwardRelayPayloads(in: userInfo)
        if let data = userInfo[VoiceResultAudioDegradationMessage.envelopeKey] as? Data {
            Task { @MainActor in self.applyAudioDegradation(data) }
        }
        if let data = userInfo[RealtimeMediaMessage.downlinkEnvelopeKey] as? Data {
            Task { @MainActor in self.applyRealtimeDownlink(data) }
        }
        guard let data = userInfo[VoiceStatusMessage.envelopeKey] as? Data else { return }
        Task { @MainActor in self.applyVoiceStatus(data) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 系统会在本方法返回后删除临时文件，必须同步读出/搬移。
        let size = (try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        if let payloadData = file.metadata?[VoiceMessage.resultKey] as? Data {
            WatchLog.info("wcsession", "file_received", detail: "kind=result_audio bytes=\(size)")
            let stagedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-result-\(UUID().uuidString).m4a")
            try? FileManager.default.moveItem(at: file.fileURL, to: stagedURL)
            Task { @MainActor in
                self.voiceTransport?.handleResultAudioFile(tempURL: stagedURL, payloadData: payloadData)
                try? FileManager.default.removeItem(at: stagedURL)
            }
            return
        }
        // ESS-184/207：kind=probe 走独立文件通道；Watch 端严格按 metadata key
        // 分流，避免探针误入 storeSpeech（vault + journal）。probe 分支需要
        // request_id 观测（H2 严格匹配 request_id 不再依赖邻近推断）。
        if let envelopeData = file.metadata?[VoiceProbeMessage.envelopeKey] as? Data {
            guard let audioData = try? Data(contentsOf: file.fileURL) else {
                WatchLog.error(
                    "wcsession", "file_received_unreadable", detail: "kind=probe", code: "ERR_FILE_READ"
                )
                return
            }
            let envelope = try? VoiceStatusEnvelope.decode(from: envelopeData)
            WatchLog.info(
                "wcsession", "file_received", requestId: envelope?.requestId,
                detail: "kind=probe bytes=\(audioData.count)"
            )
            Task { @MainActor in self.playProbe(envelopeData: envelopeData, audioData: audioData) }
            return
        }
        guard let envelopeData = file.metadata?[VoiceSpeechMessage.envelopeKey] as? Data else {
            WatchLog.error(
                "wcsession", "file_received_unknown", detail: "bytes=\(size)", code: "ERR_UNKNOWN_FILE"
            )
            return
        }
        guard let audioData = try? Data(contentsOf: file.fileURL) else {
            WatchLog.error("wcsession", "file_received_unreadable", detail: "kind=speech", code: "ERR_FILE_READ")
            return
        }
        WatchLog.info("wcsession", "file_received", detail: "kind=speech bytes=\(audioData.count)")
        Task { @MainActor in self.storeSpeech(envelopeData: envelopeData, audioData: audioData) }
    }

    /// ESS-184/207 探针接收：sha 校验 → 转发给 transport 起播 → 播完发 probe_ack。
    /// 绝不触碰 journal / vault / ledger；本函数是 Watch 侧「探针分身」的入口。
    @MainActor
    private func playProbe(envelopeData: Data, audioData: Data) {
        guard
            let envelope = try? VoiceStatusEnvelope.decode(from: envelopeData),
            envelope.validate() == nil
        else {
            WatchLog.error("probe", "envelope_invalid", code: "ERR_DECODE")
            return
        }
        guard envelope.audioKind == .probe else {
            WatchLog.error(
                "probe", "wrong_kind", requestId: envelope.requestId,
                detail: "kind=\(envelope.audioKind?.rawValue ?? "missing")",
                code: "ERR_AUDIO_KIND_MISMATCH"
            )
            return
        }
        voiceTransport?.playProbe(envelope: envelope, audioData: audioData)
    }

    private nonisolated func forwardRelayPayloads(in userInfo: [String: Any]) {
        let statusData = userInfo[VoiceMessage.relayStatusKey] as? Data
        let progressData = userInfo[VoiceMessage.progressKey] as? Data
        let resultData = userInfo[VoiceMessage.resultKey] as? Data
        guard statusData != nil || progressData != nil || resultData != nil else { return }
        Task { @MainActor in
            if let statusData { self.voiceTransport?.handleRelayStatus(data: statusData) }
            if let progressData { self.voiceTransport?.handleProgress(data: progressData) }
            if let resultData { self.voiceTransport?.handleResultPayload(data: resultData) }
        }
    }

    @MainActor
    private func applyVoiceStatus(_ data: Data) {
        guard let envelope = try? VoiceStatusEnvelope.decode(from: data) else {
            WatchLog.error("turn", "status_envelope_undecodable", detail: "bytes=\(data.count)", code: "ERR_DECODE")
            return
        }
        let applied = voiceJournal?.apply(envelope) ?? false
        // 每次请求的状态机变迁取证：accepted/processing/failed + 失败环节；
        // 被状态机拒绝的乱序/重复事件也留痕（applied=false）。
        let failure = envelope.failureStage.map { " failure_stage=\($0.rawValue)" } ?? ""
        let detailText = envelope.detail.map { " detail=\($0)" } ?? ""
        WatchLog.info(
            "turn", "state_event", requestId: envelope.requestId,
            detail: "state=\(envelope.state.rawValue) applied=\(applied)\(failure)\(detailText)"
        )
        if applied, envelope.state == .completed,
           let turn = voiceJournal?.turn(withId: envelope.requestId),
           let textTTFTMs = VoiceTurnLatency.measure(turn).textTTFTMs {
            WatchLog.info(
                "latency", "text_ttft", requestId: envelope.requestId,
                detail: "ttft_ms=\(textTTFTMs) clock=watch_turn"
            )
        }
        if envelope.state.isTerminal {
            WatchLogShipper.shared.ship(reason: "turn_terminal")
        }
        if envelope.state == .completed, envelope.result?.speechSha256 == nil {
            voiceTransport?.sendResultAck(requestId: envelope.requestId)
        }
    }

    /// ESS-321: decode a `RealtimeDownlinkEnvelope` arriving from iPhone via
    /// `WatchDownlinkOutbox` and dispatch to the adapter. Envelopes for
    /// requests other than the currently-active turn are dropped by the
    /// adapter's session-isolated buffer.
    @MainActor
    private func applyRealtimeDownlink(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(RealtimeDownlinkEnvelope.self, from: data),
              envelope.protocolVersion == RealtimeWireVersion.downlink else {
            WatchLog.error(
                "turn", "realtime_downlink_undecodable",
                detail: "bytes=\(data.count)", code: "ERR_DECODE"
            )
            return
        }
        guard let adapter = realtimeAdapter else {
            WatchLog.info(
                "turn", "realtime_downlink_no_adapter",
                requestId: envelope.requestId,
                detail: "kind=\(envelope.kind.rawValue)"
            )
            return
        }
        WatchLog.info(
            "turn", "realtime_downlink_dispatch",
            requestId: envelope.requestId,
            detail: "kind=\(envelope.kind.rawValue) session=\(envelope.sessionId)"
        )
        switch envelope.kind {
        case .ready:
            // ESS-329: Bridge handshake ack. Just proves the socket accepted
            // `start`; nothing to do at the adapter layer.
            break
        case .audioDelta:
            if let chunk = envelope.audio {
                adapter.ingestDownlink(
                    chunk,
                    responseId: envelope.responseId,
                    generation: envelope.generation
                )
            }
        case .audioDone:
            adapter.markDownlinkComplete(
                responseId: envelope.responseId,
                generation: envelope.generation,
                finalSequence: envelope.finalSequence
            )
        case .playbackClear, .responseInterrupted:
            adapter.bargeIn()
        case .bridgeFallback:
            adapter.markDownlinkBridgeFallback()
        case .transcriptDelta, .transcriptFinal:
            // Text-only events are handled by the transcript layer, not the
            // playback engine — leave them to `applyVoiceStatus` for now.
            break
        case .generationOpen:
            if let generation = envelope.generation {
                adapter.openGeneration(generation)
            }
        case .bargeInFailed:
            adapter.markBargeInFailed(reason: envelope.reason ?? "unspecified")
        }
    }

    @MainActor
    func applyAudioDegradation(_ data: Data) {
        guard let envelope = try? VoiceResultAudioDegradationEnvelope.decode(from: data),
              envelope.validate() == nil else {
            WatchLog.error("turn", "audio_degradation_invalid", code: "ERR_DECODE")
            return
        }
        let applied = voiceJournal?.recordAudioDegradation(
            requestId: envelope.requestId, errorCode: envelope.errorCode
        ) ?? false
        WatchLog.info(
            "turn", "result_audio_degraded", requestId: envelope.requestId,
            detail: "code=\(envelope.errorCode) applied=\(applied) text_available=true"
        )
    }

    /// 结果语音入库：sha256 校验通过才加密落盘；校验失败整体丢弃（数据不可信）。
    /// ESS-41 L3 取证：每个丢弃分支必须留 request_id + 原因，禁止静默 return。
    @MainActor
    private func storeSpeech(envelopeData: Data, audioData: Data) {
        guard
            let envelope = try? VoiceStatusEnvelope.decode(from: envelopeData),
            envelope.validate() == nil
        else {
            WatchLog.error("turn", "speech_envelope_invalid", code: "ERR_DECODE")
            return
        }
        guard AudioDownlinkPolicy.allows(envelope.audioKind, expected: [.interim, .result]) else {
            WatchLog.error(
                "audio", "l1_audio_rejected", requestId: envelope.requestId,
                detail: "reason=unknown_or_missing_kind kind=\(envelope.audioKind?.rawValue ?? "missing") source=watch_entry",
                code: "ERR_AUDIO_KIND_REJECTED"
            )
            return
        }
        if let expected = envelope.result?.speechSha256,
           VoiceDigest.sha256Hex(of: audioData) != expected.lowercased() {
            WatchLog.error(
                "turn", "speech_sha_mismatch", requestId: envelope.requestId,
                detail: "bytes=\(audioData.count)", code: "ERR_SHA_MISMATCH"
            )
            return
        }
        voiceJournal?.apply(envelope)
        let digest = envelope.result?.speechSha256?.lowercased()
            ?? VoiceDigest.sha256Hex(of: audioData)
        // interim and final share request_id but are different generations.
        // Version the vault name by content so an old playback callback cannot
        // delete a newly arrived final file with the same request_id.
        let fileName = "\(envelope.requestId)-\(digest).m4a"
        guard let vault = speechVault, (try? vault.store(audioData, name: fileName)) != nil else {
            WatchLog.error(
                "turn", "speech_vault_store_failed", requestId: envelope.requestId, code: "ERR_VAULT_STORE"
            )
            _ = voiceJournal?.recordAudioDegradation(
                requestId: envelope.requestId, errorCode: "ERR_VAULT_STORE"
            )
            return
        }
        WatchLog.info(
            "turn", "speech_stored", requestId: envelope.requestId, detail: "bytes=\(audioData.count)"
        )
        let hadAudioMilestone = voiceJournal?.turn(withId: envelope.requestId)?.speechAttachedAt != nil
        guard voiceJournal?.attachSpeech(requestId: envelope.requestId, fileName: fileName) == true else {
            speechVault?.remove(name: fileName)
            WatchLog.error(
                "turn", "speech_attach_missing_turn", requestId: envelope.requestId,
                detail: "file=\(fileName)", code: "ERR_TURN_NOT_FOUND"
            )
            return
        }
        if !hadAudioMilestone,
           let turn = voiceJournal?.turn(withId: envelope.requestId),
           let audioTTFTMs = VoiceTurnLatency.measure(turn).audioTTFTMs {
            WatchLog.info(
                "latency", "audio_ttft", requestId: envelope.requestId,
                detail: "ttft_ms=\(audioTTFTMs) bytes=\(audioData.count) clock=watch_turn"
            )
        }
        // interim 语音（ESS-46，非终态信封）落盘不算交付：ACK 只对终态结果发，
        // 否则 Bridge 会在回合转终态后接受这个早发的 ACK，final 丢失时不再重投（ESS-47）。
        if envelope.state.isTerminal {
            voiceTransport?.sendResultAck(requestId: envelope.requestId)
        }
        WatchLogShipper.shared.ship(reason: "speech_stored")
    }
}
