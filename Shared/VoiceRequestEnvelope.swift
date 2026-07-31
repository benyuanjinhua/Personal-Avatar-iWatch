import Foundation

/// Watch → iPhone 语音请求的版本化信封（ESS-22）。
/// 两端只交换本结构的 JSON 编码，不传任意字典。
struct VoiceAudioDescriptor: Codable, Equatable {
    let codec: String
    let sampleRate: Int
    let channels: Int
    let durationMs: Int
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case codec
        case sampleRate = "sample_rate"
        case channels
        case durationMs = "duration_ms"
        case sha256
    }
}

struct VoiceRequestEnvelope: Codable, Equatable {
    static let currentProtocolVersion = "1.0"
    static let voiceRequestType = "voice_request"

    let protocolVersion: String
    let requestId: String
    let type: String
    let createdAt: Date
    let audio: VoiceAudioDescriptor

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case type
        case createdAt = "created_at"
        case audio
    }

    static func voiceRequest(
        requestId: UUID = UUIDv7.generate(),
        createdAt: Date = Date(),
        audio: VoiceAudioDescriptor
    ) -> VoiceRequestEnvelope {
        VoiceRequestEnvelope(
            protocolVersion: currentProtocolVersion,
            requestId: requestId.uuidString.lowercased(),
            type: voiceRequestType,
            createdAt: createdAt,
            audio: audio
        )
    }

    func jsonData() throws -> Data {
        try Self.encoder.encode(self)
    }

    static func decode(from data: Data) throws -> VoiceRequestEnvelope {
        try decoder.decode(VoiceRequestEnvelope.self, from: data)
    }

    /// 结构合法性校验；接收端在落盘/转发前必须先通过。
    func validate() -> VoiceEnvelopeValidationError? {
        guard protocolVersion == Self.currentProtocolVersion else { return .unsupportedProtocolVersion(protocolVersion) }
        guard type == Self.voiceRequestType else { return .unsupportedType(type) }
        guard UUID(uuidString: requestId) != nil else { return .invalidRequestId }
        guard audio.channels == 1 else { return .invalidAudio("channels 必须为 1") }
        guard audio.durationMs > 0, audio.durationMs <= 60_000 else { return .invalidAudio("duration_ms 超出 (0, 60000]") }
        guard audio.sha256.count == 64, audio.sha256.allSatisfy(\.isHexDigit) else { return .invalidAudio("sha256 不是 64 位十六进制") }
        return nil
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum VoiceEnvelopeValidationError: Error, Equatable, CustomStringConvertible {
    case unsupportedProtocolVersion(String)
    case unsupportedType(String)
    case invalidRequestId
    case invalidAudio(String)

    var description: String {
        switch self {
        case .unsupportedProtocolVersion(let version): return "不支持的协议版本：\(version)"
        case .unsupportedType(let type): return "不支持的消息类型：\(type)"
        case .invalidRequestId: return "request_id 不是合法 UUID"
        case .invalidAudio(let reason): return "音频元数据非法：\(reason)"
        }
    }
}

/// WatchConnectivity 消息/文件元数据里承载信封 JSON 的键。
enum VoiceMessage {
    static let envelopeKey = "voice_request_envelope"
}
