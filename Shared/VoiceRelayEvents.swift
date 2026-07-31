import Foundation

/// §6 跨设备共享的最小公共状态机。rawValue 即 wire 上的状态字符串。
enum VoiceTurnPhase: String, Codable, CaseIterable {
    case recorded
    case waitingForPhone = "waiting_for_phone"
    case waitingForMac = "waiting_for_mac"
    case accepted
    case realtimeProcessing = "realtime_processing"
    case backgroundAccepted = "background_accepted"
    case backgroundProcessing = "background_processing"
    case permissionRequired = "permission_required"
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    var displayText: String {
        switch self {
        case .recorded: return "已录音"
        case .waitingForPhone: return "等待手机连接"
        case .waitingForMac: return "已到手机，等待 Mac"
        case .accepted: return "Mac 已受理"
        case .realtimeProcessing: return "正在处理"
        case .backgroundAccepted: return "后台任务已受理"
        case .backgroundProcessing: return "后台任务执行中"
        case .permissionRequired: return "需要确认权限"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

/// WSS /v1/voice/events 下行事件（§7）。防御性解码：
/// 未知 kind / 未知 status 保留原始字符串，未知字段忽略，坏 JSON 返回 nil。
struct VoiceTurnEvent: Codable, Equatable {
    let requestId: String
    /// "status" | "permission_required" | "result"；未知类型原样保留由上层忽略。
    let event: String
    let status: String?
    let text: String?
    let audioBase64: String?
    let errorCode: String?
    let occurredAt: Date?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case event
        case status
        case text
        case audioBase64 = "audio_base64"
        case errorCode = "error_code"
        case occurredAt = "occurred_at"
    }

    var phase: VoiceTurnPhase? {
        status.flatMap(VoiceTurnPhase.init(rawValue:))
    }

    static func decode(from data: Data) -> VoiceTurnEvent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VoiceTurnEvent.self, from: data)
    }
}

/// iPhone → Watch 的状态回执（sendMessage / transferUserInfo 承载）。
struct RelayStatusUpdate: Codable, Equatable {
    let protocolVersion: String
    let requestId: String
    let phase: VoiceTurnPhase
    /// 面向用户的补充说明（如失败原因、权限摘要）；不含凭据与内部路径。
    let detail: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case phase
        case detail
        case updatedAt = "updated_at"
    }

    init(requestId: String, phase: VoiceTurnPhase, detail: String? = nil, updatedAt: Date = Date()) {
        self.protocolVersion = VoiceRequestEnvelope.currentProtocolVersion
        self.requestId = requestId
        self.phase = phase
        self.detail = detail
        self.updatedAt = updatedAt
    }

    func jsonData() throws -> Data {
        try RelayEventCoding.encoder.encode(self)
    }

    static func decode(from data: Data) -> RelayStatusUpdate? {
        try? RelayEventCoding.decoder.decode(RelayStatusUpdate.self, from: data)
    }
}

/// iPhone → Watch 的最终结果。短文本随本载荷走 sendMessage / transferUserInfo；
/// 结果音频单独 transferFile，metadata 里带同一载荷用于关联与校验。
struct VoiceResultPayload: Codable, Equatable {
    let protocolVersion: String
    let requestId: String
    let text: String?
    /// 结果音频的 sha256；Watch 收到 transferFile 后校验一致性。nil 表示纯文本结果。
    let audioSha256: String?
    let completedAt: Date

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case text
        case audioSha256 = "audio_sha256"
        case completedAt = "completed_at"
    }

    init(requestId: String, text: String?, audioSha256: String? = nil, completedAt: Date = Date()) {
        self.protocolVersion = VoiceRequestEnvelope.currentProtocolVersion
        self.requestId = requestId
        self.text = text
        self.audioSha256 = audioSha256
        self.completedAt = completedAt
    }

    func jsonData() throws -> Data {
        try RelayEventCoding.encoder.encode(self)
    }

    static func decode(from data: Data) -> VoiceResultPayload? {
        try? RelayEventCoding.decoder.decode(VoiceResultPayload.self, from: data)
    }
}

enum RelayEventCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension VoiceMessage {
    /// iPhone → Watch 状态回执的消息键。
    static let relayStatusKey = "voice_relay_status"
    /// iPhone → Watch 结果载荷的消息键（文本消息与结果音频 transferFile 的 metadata 共用）。
    static let resultKey = "voice_result"
}
