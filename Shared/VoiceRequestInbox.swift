import CryptoKit
import Foundation

enum VoiceDigest {
    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum VoiceIngestOutcome: Equatable {
    /// 校验通过并已落盘，允许继续转发给 Mac。
    case accepted(VoiceRequestEnvelope, fileURL: URL)
    /// 同一 request_id + sha256 已收到过：幂等丢弃，不产生第二个请求。
    case duplicate(requestId: String)
    /// 校验失败：不落盘、不转发。
    case rejected(VoiceIngestError)
}

enum VoiceIngestError: Error, Equatable, CustomStringConvertible {
    case invalidEnvelope(VoiceEnvelopeValidationError)
    case checksumMismatch(expected: String, actual: String)
    case requestIdConflict(requestId: String)
    case storageFailure(String)

    var description: String {
        switch self {
        case .invalidEnvelope(let error): return error.description
        case .checksumMismatch: return "音频 sha256 与信封不一致"
        case .requestIdConflict(let id): return "request_id \(id) 已存在但内容不同"
        case .storageFailure(let reason): return "写入失败：\(reason)"
        }
    }
}

struct VoiceInboxEntry: Codable, Equatable, Identifiable {
    let requestId: String
    let sha256: String
    let durationMs: Int
    let sizeBytes: Int
    let receivedAt: Date

    var id: String { requestId }
}

/// iPhone 端语音请求收件箱：sha256 完整性校验 + request_id 幂等去重 + 落盘。
/// 纯 Foundation 实现，便于在 macOS 上做单元测试。
final class VoiceRequestInbox {
    private let directory: URL
    private let indexURL: URL
    private(set) var entries: [VoiceInboxEntry]

    init(directory: URL) throws {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if
            let data = try? Data(contentsOf: indexURL),
            let saved = try? JSONDecoder().decode([VoiceInboxEntry].self, from: data)
        {
            entries = saved
        } else {
            entries = []
        }
    }

    func ingest(envelopeData: Data, audioData: Data) -> VoiceIngestOutcome {
        guard let envelope = try? VoiceRequestEnvelope.decode(from: envelopeData) else {
            return .rejected(.invalidEnvelope(.invalidAudio("信封 JSON 无法解析")))
        }
        return ingest(envelope: envelope, audioData: audioData)
    }

    func ingest(envelope: VoiceRequestEnvelope, audioData: Data) -> VoiceIngestOutcome {
        if let validationError = envelope.validate() {
            return .rejected(.invalidEnvelope(validationError))
        }

        let actualDigest = VoiceDigest.sha256Hex(of: audioData)
        guard actualDigest == envelope.audio.sha256.lowercased() else {
            return .rejected(.checksumMismatch(expected: envelope.audio.sha256, actual: actualDigest))
        }

        if let existing = entries.first(where: { $0.requestId == envelope.requestId }) {
            return existing.sha256 == actualDigest
                ? .duplicate(requestId: envelope.requestId)
                : .rejected(.requestIdConflict(requestId: envelope.requestId))
        }

        let audioURL = directory.appendingPathComponent("\(envelope.requestId).m4a")
        do {
            try audioData.write(to: audioURL, options: .atomic)
            try envelope.jsonData().write(
                to: directory.appendingPathComponent("\(envelope.requestId).json"),
                options: .atomic
            )
        } catch {
            return .rejected(.storageFailure(error.localizedDescription))
        }

        let entry = VoiceInboxEntry(
            requestId: envelope.requestId,
            sha256: actualDigest,
            durationMs: envelope.audio.durationMs,
            sizeBytes: audioData.count,
            receivedAt: Date()
        )
        entries.append(entry)
        persistIndex()
        return .accepted(envelope, fileURL: audioURL)
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
