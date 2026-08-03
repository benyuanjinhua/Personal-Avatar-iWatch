import Foundation

/// §6 跨设备共享的最小公共状态机。rawValue 即 wire 上的状态字符串。
enum VoiceRelayPhase: String, Codable, CaseIterable {
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
struct VoiceRelayEvent: Codable, Equatable {
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

    var phase: VoiceRelayPhase? {
        status.flatMap(VoiceRelayPhase.init(rawValue:))
    }

    static func decode(from data: Data) -> VoiceRelayEvent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VoiceRelayEvent.self, from: data)
    }
}

/// iPhone → Watch 的状态回执（sendMessage / transferUserInfo 承载）。
struct RelayStatusUpdate: Codable, Equatable {
    let protocolVersion: String
    let requestId: String
    let phase: VoiceRelayPhase
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

    init(requestId: String, phase: VoiceRelayPhase, detail: String? = nil, updatedAt: Date = Date()) {
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
struct VoiceRelayResultPayload: Codable, Equatable {
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

    static func decode(from data: Data) -> VoiceRelayResultPayload? {
        try? RelayEventCoding.decoder.decode(VoiceRelayResultPayload.self, from: data)
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
    /// ESS-59 真实进展专用键；与通用状态分离，避免后续状态快照覆盖步骤文案。
    static let progressKey = "voice_progress"
    /// iPhone → Watch 结果载荷的消息键（文本消息与结果音频 transferFile 的 metadata 共用）。
    static let resultKey = "voice_result"
}

/// Watch → iPhone → Bridge 的最终交付确认。仅在纯文本结果已入内存账本，或
/// 结果语音通过 sha256 校验并持久落盘后发送。
struct ResultDeliveryAck: Codable, Equatable {
    let protocolVersion: String
    let requestId: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
    }

    init(requestId: String) {
        protocolVersion = VoiceRequestEnvelope.currentProtocolVersion
        self.requestId = requestId
    }

    func jsonData() throws -> Data { try RelayEventCoding.encoder.encode(self) }
    static func decode(from data: Data) -> ResultDeliveryAck? {
        try? RelayEventCoding.decoder.decode(ResultDeliveryAck.self, from: data)
    }
}

enum ResultDeliveryAckMessage {
    static let envelopeKey = "result_delivery_ack"
}

/// ESS-184 门禁探针的播放成功回执。Watch → iPhone → Bridge。
/// **与 ResultDeliveryAck 分家的关键**：ResultDeliveryAck 是「音频已安全落盘」的
/// 交付 ACK（storeSpeech 成功即发），本探针 ACK 是「音频真的从扬声器出来了」的
/// 播放完成 ACK（SpeechPlayer.onFinish(true) 才发）。这个语义差别正是 ESS-184
/// H5 的存在理由 —— 用户耳朵和 Bridge 之间那最后一步，缺 H5 就等于门禁没关严。
struct ProbePlaybackAck: Codable, Equatable {
    let protocolVersion: String
    let requestId: String
    /// 播完的 sha256（Watch 端从入手的音频算出来，与 envelope 中声明的对齐）；
    /// 上游据此断言 Watch 播的是 Bridge 发的字节，防止「播了但播的是别的」。
    let sha256: String
    /// SpeechPlayer.onFinish(true) 的时刻（Watch 时钟，ms epoch）——仅统计用途，
    /// H5 判定只看是否收到本 ACK，不比对时钟。
    let playedAtMs: Int64
    /// 音频实际播放时长（毫秒）；便于诊断截断。可选：早期版本可能没上报。
    let durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case sha256
        case playedAtMs = "played_at_ms"
        case durationMs = "duration_ms"
    }

    init(requestId: String, sha256: String, playedAtMs: Int64, durationMs: Int?) {
        protocolVersion = VoiceRequestEnvelope.currentProtocolVersion
        self.requestId = requestId
        self.sha256 = sha256.lowercased()
        self.playedAtMs = playedAtMs
        self.durationMs = durationMs
    }

    func jsonData() throws -> Data { try RelayEventCoding.encoder.encode(self) }
    static func decode(from data: Data) -> ProbePlaybackAck? {
        try? RelayEventCoding.decoder.decode(ProbePlaybackAck.self, from: data)
    }
}

enum ProbePlaybackAckMessage {
    /// WCSession sendMessage / transferUserInfo 键；与 result_delivery_ack 分家。
    static let envelopeKey = "probe_playback_ack"
}
