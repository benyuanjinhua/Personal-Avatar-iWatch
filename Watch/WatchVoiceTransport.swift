import Foundation
import WatchConnectivity

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
    @Published private(set) var lastResult: VoiceResultPayload?

    private let outboxDirectory: URL
    let resultsDirectory: URL
    private let fileManager = FileManager.default

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        outboxDirectory = base.appendingPathComponent("VoiceOutbox", isDirectory: true)
        resultsDirectory = base.appendingPathComponent("VoiceResults", isDirectory: true)
        try? fileManager.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        refreshPendingCount()
    }

    // MARK: - iPhone Relay 回执（ESS-28）

    func handleRelayStatus(data: Data) {
        guard let update = RelayStatusUpdate.decode(from: data) else { return }
        remoteStatus = update
    }

    func handleResultPayload(data: Data) {
        guard let payload = VoiceResultPayload.decode(from: data) else { return }
        lastResult = payload
    }

    /// 结果音频 transferFile 落地：sha256 校验通过才保留。
    func handleResultAudioFile(tempURL: URL, payloadData: Data?) {
        guard
            let payloadData,
            let payload = VoiceResultPayload.decode(from: payloadData),
            let audioData = try? Data(contentsOf: tempURL),
            payload.audioSha256?.lowercased() == VoiceDigest.sha256Hex(of: audioData)
        else { return }
        let destination = resultsDirectory.appendingPathComponent("\(payload.requestId).m4a")
        try? fileManager.removeItem(at: destination)
        guard (try? audioData.write(to: destination, options: .atomic)) != nil else { return }
        lastResult = payload
    }

    func send(envelope: VoiceRequestEnvelope, recording: AudioRecorder.Recording) {
        do {
            let audioURL = outboxDirectory.appendingPathComponent("\(envelope.requestId).m4a")
            try fileManager.moveItem(at: recording.fileURL, to: audioURL)
            try envelope.jsonData().write(to: sidecarURL(for: envelope.requestId), options: .atomic)
            refreshPendingCount()
            submit(envelope: envelope, audioURL: audioURL)
        } catch {
            phase = .failed("保存录音失败：\(error.localizedDescription)")
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
            submit(envelope: envelope, audioURL: outboxDirectory.appendingPathComponent("\(requestId).m4a"))
        }
    }

    func handleTransferFinished(fileName: String, error: Error?) {
        if let error {
            phase = .failed("发送失败，将自动重试：\(error.localizedDescription)")
            return
        }
        let requestId = (fileName as NSString).deletingPathExtension
        try? fileManager.removeItem(at: outboxDirectory.appendingPathComponent(fileName))
        try? fileManager.removeItem(at: sidecarURL(for: requestId))
        refreshPendingCount()
        phase = pendingCount == 0 ? .delivered : .sending
    }

    func handleReachabilityChange(isReachable: Bool) {
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
            return
        }
        guard let envelopeData = try? envelope.jsonData() else {
            phase = .failed("信封编码失败")
            return
        }
        if session.isReachable {
            session.sendMessage([VoiceMessage.envelopeKey: envelopeData], replyHandler: nil, errorHandler: nil)
            phase = .sending
        } else {
            phase = .waitingForPhone
        }
        session.transferFile(audioURL, metadata: [VoiceMessage.envelopeKey: envelopeData])
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
