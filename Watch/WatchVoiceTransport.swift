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
    /// Mac 返回的最新结果；音频落在 resultsDirectory/<request_id>.m4a。
    @Published private(set) var lastResult: VoiceRelayResultPayload?

    /// 语音回合日志：发送各阶段状态写入其中，UI 时间线由它驱动（ESS-29）。
    private weak var journal: VoiceTurnJournal?
    private let outboxDirectory: URL
    let resultsDirectory: URL
    private let fileManager = FileManager.default

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
    }

    func send(envelope: VoiceRequestEnvelope, recording: AudioRecorder.Recording) {
        journal?.begin(requestId: envelope.requestId)
        WatchLog.info(
            "transport", "send_begin", requestId: envelope.requestId,
            detail: "duration_ms=\(recording.durationMs) bytes=\(recording.data.count)"
        )
        do {
            let audioURL = outboxDirectory.appendingPathComponent("\(envelope.requestId).m4a")
            try fileManager.moveItem(at: recording.fileURL, to: audioURL)
            try envelope.jsonData().write(to: sidecarURL(for: envelope.requestId), options: .atomic)
            refreshPendingCount()
            submit(envelope: envelope, audioURL: audioURL)
        } catch {
            phase = .failed("保存录音失败：\(error.localizedDescription)")
            journal?.recordLocal(.failed, requestId: envelope.requestId, detail: "保存录音失败")
            WatchLog.error("transport", "outbox_save_failed", requestId: envelope.requestId, error: error)
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
}
