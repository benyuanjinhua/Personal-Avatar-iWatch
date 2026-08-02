import Combine
import Foundation
import WatchConnectivity
import os

@MainActor
final class WatchSettingsStore: NSObject, ObservableObject, WCSessionDelegate {
    /// ESS-41 L3 取证：结果语音「到没到手表、为何被丢」全部走这条日志。
    private static let speechLogger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "SpeechStore")
    @Published private(set) var configuration: AgentConfiguration = .demo
    /// 语音传输回调转发目标（WCSession 只允许一个 delegate）。
    weak var voiceTransport: WatchVoiceTransport?
    /// 状态/权限/结果事件入账目标（ESS-29）。
    weak var voiceJournal: VoiceTurnJournal?
    /// 结果语音的加密落盘仓（ESS-29）。
    weak var speechVault: EncryptedAudioVault?
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
        guard activationState == .activated else { return }
        Task { @MainActor in
            self.voiceTransport?.retryPending()
            WatchLogShipper.shared.ship(reason: "session_activated")
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in self.voiceTransport?.handleReachabilityChange(isReachable: isReachable) }
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
        guard let data = applicationContext[ConfigurationMessage.key] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data
    ) {
        Task { @MainActor in self.apply(messageData) }
    }

    // MARK: - iPhone Relay 回执（ESS-28）＋ 状态/权限/结果事件（ESS-29）
    // 同一 WCSession delegate 同时服务两条链路：payload 按各自的 key 分流。

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        forwardRelayPayloads(in: message)
        guard let data = message[VoiceStatusMessage.envelopeKey] as? Data else { return }
        Task { @MainActor in self.applyVoiceStatus(data) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        forwardRelayPayloads(in: userInfo)
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
        if envelope.state.isTerminal {
            WatchLogShipper.shared.ship(reason: "turn_terminal")
        }
        if envelope.state == .completed, envelope.result?.speechSha256 == nil {
            voiceTransport?.sendResultAck(requestId: envelope.requestId)
        }
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
            return
        }
        WatchLog.info(
            "turn", "speech_stored", requestId: envelope.requestId, detail: "bytes=\(audioData.count)"
        )
        guard voiceJournal?.attachSpeech(requestId: envelope.requestId, fileName: fileName) == true else {
            speechVault?.remove(name: fileName)
            WatchLog.error(
                "turn", "speech_attach_missing_turn", requestId: envelope.requestId,
                detail: "file=\(fileName)", code: "ERR_TURN_NOT_FOUND"
            )
            return
        }
        // interim 语音（ESS-46，非终态信封）落盘不算交付：ACK 只对终态结果发，
        // 否则 Bridge 会在回合转终态后接受这个早发的 ACK，final 丢失时不再重投（ESS-47）。
        if envelope.state.isTerminal {
            voiceTransport?.sendResultAck(requestId: envelope.requestId)
        }
        WatchLogShipper.shared.ship(reason: "speech_stored")
    }
}
