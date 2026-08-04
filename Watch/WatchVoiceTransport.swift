import Foundation
import WatchConnectivity
import os

/// Watch → iPhone 语音请求传输（ESS-22 策略）：
/// - 双端活跃且 isReachable：先 sendMessage 送信封元数据，再 transferFile 送音频；
/// - iPhone 不可达：直接 transferFile 进系统托管队列，UI 显示“等待手机连接”；
/// - 重发同一文件复用 outbox 里保存的信封（request_id 不变，接收端幂等去重）。
@MainActor
final class WatchVoiceTransport: ObservableObject {
    enum DeliveryPhase: Equatable {
        case idle
        case sending
        case waitingForPhone
        case delivered
        case failed(String)

        var displayText: String {
            switch self {
            case .idle: return "按住说话"
            case .sending: return "正在发送到 iPhone…"
            case .waitingForPhone: return "等待手机连接"
            case .delivered: return "已送达 iPhone"
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var phase: DeliveryPhase = .idle
    @Published private(set) var pendingCount = 0
    /// iPhone Relay 回执的最新链路状态（ESS-28；完整时间线 UI 归 ESS-29）。
    @Published private(set) var remoteStatus: RelayStatusUpdate?
    /// 最新服务端真实步骤；独立于通用状态，后者不可覆盖它。
    @Published private(set) var progressStatus: RelayStatusUpdate?
    /// Mac 返回的最新结果；音频落在 resultsDirectory/<request_id>.m4a。
    @Published private(set) var lastResult: VoiceRelayResultPayload?
    /// ESS-231 兜底告警：send_begin 后 15s 未收到 iPhone Relay 的 `.accepted`
    /// 状态时，request_id 加入本集合并触发触觉；UI 层订阅并显示"iPhone
    /// WristAgent 未活跃，请手动打开一次"。收到任一非初始 phase 即移除。
    @Published private(set) var iphoneRelayStuckRequestIds: Set<String> = []

    /// ESS-231：per-request 兜底 watchdog，等待 15s 无 iPhone 回执即报警。
    /// send() 时启动；handleRelayStatus 收到任何 phase >= accepted 即取消。
    private var iphoneRelayWatchdogs: [String: Task<Void, Never>] = [:]
    /// ESS-231 阈值：iPhone 后台 WristAgent 若能被拉起，通常 5-10s 内会走
    /// PhoneConnectivity → RelayClient POST 到 Bridge 得到回执；15s 尚未
    /// 拿到 accepted 视为 iPhone 端不可用（app 被杀 / helper 崩溃 / 系统
    /// 后台限流）。可通过 PushToTalkController 覆盖用于测试。
    static let iphoneRelayStuckThreshold: TimeInterval = 15

    /// 语音回合日志：发送各阶段状态写入其中，UI 时间线由它驱动（ESS-29）。
    private weak var journal: VoiceTurnJournal?
    private let outboxDirectory: URL
    let resultsDirectory: URL
    private let fileManager = FileManager.default
    /// ESS-184/207 探针专用播放器；与 PushToTalkController 里的结果/错误
    /// player 完全隔离，避免探针挤占用户结果播放的会话/上下文。
    private let probePlayer = SpeechPlayer()

    init(journal: VoiceTurnJournal? = nil) {
        self.journal = journal
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        outboxDirectory = base.appendingPathComponent("VoiceOutbox", isDirectory: true)
        resultsDirectory = base.appendingPathComponent("VoiceResults", isDirectory: true)
        try? fileManager.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        refreshPendingCount()
    }

    // MARK: - iPhone Relay 回执（ESS-28）

    func handleRelayStatus(data: Data) {
        guard let update = RelayStatusUpdate.decode(from: data) else {
            WatchLog.error("transport", "relay_status_undecodable", detail: "bytes=\(data.count)", code: "ERR_DECODE")
            return
        }
        WatchLog.info(
            "turn", "relay_status", requestId: update.requestId,
            detail: "phase=\(update.phase.rawValue)\(update.detail.map { " detail=\($0)" } ?? "")"
        )
        remoteStatus = update
        if let envelope = update.failedStatusEnvelope() {
            _ = journal?.apply(envelope)
        }
        // ESS-231：任何 phase >= accepted 都算 iPhone 已把 turn 转到 Bridge，
        // 取消兜底 watchdog；同时清除 UI 告警状态。
        if update.phase != .recorded && update.phase != .waitingForPhone && update.phase != .waitingForMac {
            cancelIphoneRelayWatchdog(requestId: update.requestId, reason: "phase=\(update.phase.rawValue)")
        }
    }

    func handleProgress(data: Data) {
        guard let update = RelayStatusUpdate.decode(from: data),
              update.phase == .backgroundProcessing else {
            WatchLog.error("transport", "progress_undecodable", detail: "bytes=\(data.count)", code: "ERR_DECODE")
            return
        }
        progressStatus = update
        WatchLog.info("turn", "real_progress", requestId: update.requestId, detail: update.detail)
    }

    func handleResultPayload(data: Data) {
        guard let payload = VoiceRelayResultPayload.decode(from: data) else {
            WatchLog.error("transport", "result_payload_undecodable", detail: "bytes=\(data.count)", code: "ERR_DECODE")
            return
        }
        WatchLog.info(
            "turn", "result_received", requestId: payload.requestId,
            detail: "text_chars=\(payload.text?.count ?? 0) audio=\(payload.audioSha256 != nil)"
        )
        lastResult = payload
    }

    /// ESS-41 L3 取证：relay-result 音频「到没到手表、为何被丢」。
    private static let speechLogger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "SpeechStore")

    /// 结果音频 transferFile 落地：sha256 校验通过才保留。
    /// ESS-41 L3 取证：每个丢弃分支必须留 request_id + 原因，禁止静默 return。
    func handleResultAudioFile(tempURL: URL, payloadData: Data?) {
        guard
            let payloadData,
            let payload = VoiceRelayResultPayload.decode(from: payloadData)
        else {
            WatchLog.error("transport", "result_audio_payload_undecodable", code: "ERR_DECODE")
            return
        }
        guard let audioData = try? Data(contentsOf: tempURL) else {
            WatchLog.error(
                "transport", "result_audio_unreadable", requestId: payload.requestId, code: "ERR_FILE_READ"
            )
            return
        }
        guard payload.audioSha256?.lowercased() == VoiceDigest.sha256Hex(of: audioData) else {
            WatchLog.error(
                "transport", "result_audio_sha_mismatch", requestId: payload.requestId,
                detail: "bytes=\(audioData.count)", code: "ERR_SHA_MISMATCH"
            )
            return
        }
        let destination = resultsDirectory.appendingPathComponent("\(payload.requestId).m4a")
        try? fileManager.removeItem(at: destination)
        guard (try? audioData.write(to: destination, options: .atomic)) != nil else {
            WatchLog.error(
                "transport", "result_audio_write_failed", requestId: payload.requestId,
                detail: destination.lastPathComponent, code: "ERR_FILE_WRITE"
            )
            return
        }
        WatchLog.info(
            "transport", "result_audio_stored", requestId: payload.requestId,
            detail: "bytes=\(audioData.count)"
        )
        lastResult = payload
        sendResultAck(requestId: payload.requestId)
    }

    func send(envelope: VoiceRequestEnvelope, recording: AudioRecorder.Recording) {
        journal?.begin(requestId: envelope.requestId)
        WatchLog.info(
            "transport", "send_begin", requestId: envelope.requestId,
            detail: "duration_ms=\(recording.durationMs) bytes=\(recording.data.count)"
        )
        armIphoneRelayWatchdog(requestId: envelope.requestId)
        do {
            let audioURL = outboxDirectory.appendingPathComponent("\(envelope.requestId).m4a")
            try fileManager.moveItem(at: recording.fileURL, to: audioURL)
            try envelope.jsonData().write(to: sidecarURL(for: envelope.requestId), options: .atomic)
            refreshPendingCount()
            submit(envelope: envelope, audioURL: audioURL)
        } catch {
            cancelIphoneRelayWatchdog(requestId: envelope.requestId, reason: "outbox_save_failed")
            phase = .failed("保存录音失败：\(error.localizedDescription)")
            journal?.recordLocal(.failed, requestId: envelope.requestId, detail: "保存录音失败")
            WatchLog.error("transport", "outbox_save_failed", requestId: envelope.requestId, error: error)
        }
    }

    // MARK: - ESS-231 iPhone Relay stuck 兜底告警

    /// send_begin 时启动，15s 内没收到 iPhone 的 accepted+ phase 就触发告警。
    /// 幂等：同一 requestId 已有 watchdog 时不重复起。
    private func armIphoneRelayWatchdog(requestId: String) {
        guard iphoneRelayWatchdogs[requestId] == nil else { return }
        let threshold = Self.iphoneRelayStuckThreshold
        iphoneRelayWatchdogs[requestId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(threshold * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.iphoneRelayWatchdogs[requestId] != nil else { return }
                self.iphoneRelayWatchdogs[requestId] = nil
                self.iphoneRelayStuckRequestIds.insert(requestId)
                WatchLog.info(
                    "transport", "iphone_relay_stuck", requestId: requestId,
                    detail: "threshold_s=\(Int(threshold)) phase=\(self.remoteStatus?.phase.rawValue ?? "none")"
                )
                WatchHaptics.play(.turnFailed, requestId: requestId)
            }
        }
    }

    /// 收到任何有效 iPhone 回执或 turn 进终态即调用。
    func cancelIphoneRelayWatchdog(requestId: String, reason: String) {
        if let task = iphoneRelayWatchdogs.removeValue(forKey: requestId) {
            task.cancel()
            WatchLog.info(
                "transport", "iphone_relay_watchdog_cancelled", requestId: requestId,
                detail: "reason=\(reason)"
            )
        }
        if iphoneRelayStuckRequestIds.remove(requestId) != nil {
            WatchLog.info(
                "transport", "iphone_relay_stuck_cleared", requestId: requestId,
                detail: "reason=\(reason)"
            )
        }
    }

    /// 激活完成 / 重新可达后调用：把 outbox 中没有在途传输的文件重新提交（request_id 复用）。
    func retryPending() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let inFlight = Set(session.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        for requestId in outboxRequestIds() where !inFlight.contains("\(requestId).m4a") {
            guard
                let envelopeData = try? Data(contentsOf: sidecarURL(for: requestId)),
                let envelope = try? VoiceRequestEnvelope.decode(from: envelopeData)
            else { continue }
            WatchLog.info("transport", "retry_pending", requestId: requestId)
            submit(envelope: envelope, audioURL: outboxDirectory.appendingPathComponent("\(requestId).m4a"))
        }
    }

    func handleTransferFinished(fileName: String, error: Error?) {
        let requestId = (fileName as NSString).deletingPathExtension
        if let error {
            phase = .failed("发送失败，将自动重试：\(error.localizedDescription)")
            WatchLog.error("transport", "transfer_failed", requestId: requestId, detail: fileName, error: error)
            return
        }
        // 音频已交付 iPhone：删除 Watch 侧临时副本（交付后删除），状态推进到“等待 Mac”。
        try? fileManager.removeItem(at: outboxDirectory.appendingPathComponent(fileName))
        try? fileManager.removeItem(at: sidecarURL(for: requestId))
        refreshPendingCount()
        phase = pendingCount == 0 ? .delivered : .sending
        WatchLog.info("transport", "transfer_delivered", requestId: requestId, detail: "pending=\(pendingCount)")
        journal?.recordLocal(.waitingForMac, requestId: requestId, detail: "语音已到手机")
    }

    /// 用户对权限请求的决定：可达时即时发送，否则进系统托管队列（transferUserInfo）。
    /// Watch 不持有签名密钥；由 iPhone Relay 签名后回传 Mac（§5.3）。
    func send(decision: PermissionDecisionEnvelope) {
        guard let data = try? decision.jsonData() else { return }
        deliver(payload: [PermissionDecisionMessage.envelopeKey: data])
    }

    /// 请求取消当前回合；iPhone 转发 Mac 北向 cancel。
    func send(cancel: VoiceCancelEnvelope) {
        guard let data = try? cancel.jsonData() else { return }
        deliver(payload: [VoiceCancelMessage.envelopeKey: data])
    }

    private func deliver(payload: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            WatchLog.error("transport", "deliver_session_not_activated", code: "ERR_WC_NOT_ACTIVATED")
            return
        }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                WatchLog.error("transport", "send_message_failed_fallback_queue", error: error)
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    // MARK: - ESS-184/207 下行链路探针

    /// 探针语音入口：sha 校验 → 起播 → 播完组装 ProbeAck 走 sendMessage +
    /// transferUserInfo 双通道回执。绝不入 journal/vault/ledger——探针 turn
    /// 与用户结果链路完全隔离，确保「不污染生产数据」（ESS-65 铁律 1）。
    func playProbe(envelope: VoiceStatusEnvelope, audioData: Data) {
        let requestId = envelope.requestId
        let expectedSha = envelope.result?.speechSha256?.lowercased()
        let actualSha = VoiceDigest.sha256Hex(of: audioData)
        if let expected = expectedSha, expected != actualSha {
            WatchLog.error(
                "probe", "sha_mismatch", requestId: requestId,
                detail: "bytes=\(audioData.count) expected=\(expected) actual=\(actualSha)",
                code: "ERR_PROBE_SHA_MISMATCH"
            )
            // sha 不匹配：不播，也不发 played_ok=true 的 ack；发一个失败 ack
            // 让 Bridge H5 收到明确的失败信号（否则 CLI 会停在 H3 而非报 sha 问题）。
            sendProbeAck(ProbeAckEnvelope(
                requestId: requestId, playedOk: false,
                playedAtMs: Self.milliseconds(Date()),
                durationMs: envelope.result?.speechDurationMs,
                sha256: actualSha,
                errorCode: "ERR_PROBE_SHA_MISMATCH"
            ))
            return
        }
        // H3 落盘事件复用既有 `turn/speech_stored`（parser 无需改事件名）；
        // detail 里除了 kind/bytes 还带 sha256——ESS-207 复审 §2 修复：
        // downlink-probe.mjs 会做 H1↔H3↔H5 三处 sha 相等断言，缺 sha 时
        // 该断言退化成向前兼容窗（跳过），带上让 CLI 能真正把关。
        // 探针不真的落盘（EncryptedAudioVault 是结果链路的东西），日志只是
        // 让 parser 的 H3 匹配到。
        WatchLog.info(
            "turn", "speech_stored", requestId: requestId,
            detail: "kind=probe bytes=\(audioData.count) sha256=\(actualSha)"
        )
        WatchLogShipper.shared.ship(reason: "probe_received")
        let startedAtMs = Self.milliseconds(Date())
        _ = probePlayer.play(data: audioData, context: requestId) { [weak self] finished in
            guard let self else { return }
            let ack = ProbeAckEnvelope(
                requestId: requestId,
                playedOk: finished,
                playedAtMs: startedAtMs,
                durationMs: envelope.result?.speechDurationMs,
                sha256: actualSha,
                errorCode: finished ? nil : "ERR_PROBE_PLAYBACK_TRUNCATED"
            )
            self.sendProbeAck(ack)
            WatchLogShipper.shared.ship(reason: "probe_ack")
        }
    }

    /// probe_ack 走 sendMessage + transferUserInfo 双通道：即时到不了时
    /// 系统托管队列兜底，iPhone 端靠 postProbeAck 的 in-flight 去重挡重复。
    private func sendProbeAck(_ ack: ProbeAckEnvelope) {
        guard let data = try? ack.jsonData() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            WatchLog.error(
                "probe", "ack_session_not_activated",
                requestId: ack.requestId, code: "ERR_WC_NOT_ACTIVATED"
            )
            return
        }
        let payload = [ProbeAckMessage.envelopeKey: data]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                Task { @MainActor in
                    WCSession.default.transferUserInfo(payload)
                }
            })
        }
        // 无论 sendMessage 成不成，都进系统托管队列。iPhone 侧 postProbeAck
        // 的 probeAckTasks[requestId] 会做 in-flight 去重，重复不会翻倍成两条
        // POST /v1/probe/ack；顶多是同一 evt=probe_acked 在 bridge.log 里出现
        // 一次（H5 判定用 first-of，不受影响）。
        session.transferUserInfo(payload)
        WatchLog.info(
            "probe", "ack_enqueued", requestId: ack.requestId,
            detail: "played_ok=\(ack.playedOk) reachable=\(session.isReachable)"
        )
    }

    func sendResultAck(requestId: String) {
        guard let data = try? ResultDeliveryAck(requestId: requestId).jsonData() else { return }
        deliver(payload: [ResultDeliveryAckMessage.envelopeKey: data])
        WatchLog.info("transport", "result_ack_enqueued", requestId: requestId)
    }

    func handleReachabilityChange(isReachable: Bool) {
        WatchLog.info("wcsession", "reachability_changed", detail: "reachable=\(isReachable) pending=\(pendingCount)")
        if isReachable {
            if phase == .waitingForPhone { phase = .sending }
            retryPending()
        } else if pendingCount > 0 {
            phase = .waitingForPhone
        }
    }

    private func submit(envelope: VoiceRequestEnvelope, audioURL: URL) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            phase = .waitingForPhone
            journal?.recordLocal(.waitingForPhone, requestId: envelope.requestId)
            WatchLog.info(
                "transport", "submit_deferred", requestId: envelope.requestId,
                detail: "session_not_activated"
            )
            return
        }
        guard let envelopeData = try? envelope.jsonData() else {
            phase = .failed("信封编码失败")
            journal?.recordLocal(.failed, requestId: envelope.requestId, detail: "信封编码失败")
            WatchLog.error("transport", "envelope_encode_failed", requestId: envelope.requestId, code: "ERR_ENCODE")
            return
        }
        if session.isReachable {
            session.sendMessage([VoiceMessage.envelopeKey: envelopeData], replyHandler: nil, errorHandler: nil)
            phase = .sending
        } else {
            phase = .waitingForPhone
            journal?.recordLocal(.waitingForPhone, requestId: envelope.requestId)
        }
        session.transferFile(audioURL, metadata: [VoiceMessage.envelopeKey: envelopeData])
        WatchLog.info(
            "transport", "transfer_enqueued", requestId: envelope.requestId,
            detail: "reachable=\(session.isReachable) file=\(audioURL.lastPathComponent)"
        )
    }

    private func outboxRequestIds() -> [String] {
        let files = (try? fileManager.contentsOfDirectory(atPath: outboxDirectory.path)) ?? []
        return files.filter { $0.hasSuffix(".m4a") }.map { ($0 as NSString).deletingPathExtension }
    }

    private func sidecarURL(for requestId: String) -> URL {
        outboxDirectory.appendingPathComponent("\(requestId).json")
    }

    private func refreshPendingCount() {
        pendingCount = outboxRequestIds().count
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }
}
