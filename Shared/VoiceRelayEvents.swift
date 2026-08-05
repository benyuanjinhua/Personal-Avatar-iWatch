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
        // ESS-386：容错策略，兼容 Bridge 下行的 `.000Z` 毫秒时间戳。
        decoder.dateDecodingStrategy = VoiceDateDecoding.strategy
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
    /// ESS-253 / D2 C1：iPhone 本地终态失败也必须携带稳定短码，不能只塞进 detail。
    let errorCode: String?
    /// ESS-253 / D2 C2：失败发生在等待手机、等待 Mac 或执行阶段。
    let failureStage: VoiceFailureStage?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case phase
        case detail
        case errorCode = "error_code"
        case failureStage = "failure_stage"
        case updatedAt = "updated_at"
    }

    init(
        requestId: String,
        phase: VoiceRelayPhase,
        detail: String? = nil,
        errorCode: String? = nil,
        failureStage: VoiceFailureStage? = nil,
        updatedAt: Date = Date()
    ) {
        self.protocolVersion = VoiceRequestEnvelope.currentProtocolVersion
        self.requestId = requestId
        self.phase = phase
        self.detail = detail
        self.errorCode = errorCode
        self.failureStage = failureStage
        self.updatedAt = updatedAt
    }

    func jsonData() throws -> Data {
        try RelayEventCoding.encoder.encode(self)
    }

    static func decode(from data: Data) -> RelayStatusUpdate? {
        try? RelayEventCoding.decoder.decode(RelayStatusUpdate.self, from: data)
    }

    /// D1 S-THINK → S-FAIL：旧 caption 通道收到带码失败时，转换成 journal 的
    /// 标准信封，复用现有错误卡片、触觉和幂等终态处理。非失败状态仍只作 caption。
    var terminalFailureEnvelope: VoiceStatusEnvelope? {
        guard phase == .failed else { return nil }
        return .status(
            requestId: requestId,
            state: .failed,
            occurredAt: updatedAt,
            detail: detail,
            failureStage: failureStage,
            errorCode: errorCode
        )
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
        // ESS-386：容错策略，兼容 Bridge 下行的 `.000Z` 毫秒时间戳。
        decoder.dateDecodingStrategy = VoiceDateDecoding.strategy
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

/// ESS-184/207 下行链路探针的播放回执。Watch 播完（成功或失败）都发一条，
/// iPhone 收到即经 `POST /v1/probe/ack` 转发给 Bridge，落 `evt=probe_acked`
/// 触发 CLI 判定 H5。字段保持最小、跨设备可对账：
/// - `requestId` 与 Bridge 侧探针 turn 的 request_id 一致（H1..H5 关联主键）；
/// - `playedAtMs` / `durationMs` 是 Watch 侧的观测；
/// - `sha256` 便于跨端确认播放的是收到的字节，不是别的。
struct ProbeAckEnvelope: Codable, Equatable {
    let protocolVersion: String
    let requestId: String
    let playedOk: Bool
    /// Watch 侧起播时刻的 epoch 毫秒；用于跨端对齐延迟统计。
    let playedAtMs: Int64
    let durationMs: Int?
    let sha256: String
    /// 播放失败时的原因短码（如 `ERR_PROBE_SHA_MISMATCH` / `ERR_PLAYBACK_ACTIVATION`）。
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case playedOk = "played_ok"
        case playedAtMs = "played_at_ms"
        case durationMs = "duration_ms"
        case sha256
        case errorCode = "error_code"
    }

    init(
        requestId: String,
        playedOk: Bool,
        playedAtMs: Int64,
        durationMs: Int?,
        sha256: String,
        errorCode: String? = nil
    ) {
        self.protocolVersion = VoiceRequestEnvelope.currentProtocolVersion
        self.requestId = requestId
        self.playedOk = playedOk
        self.playedAtMs = playedAtMs
        self.durationMs = durationMs
        self.sha256 = sha256
        self.errorCode = errorCode
    }

    func jsonData() throws -> Data { try RelayEventCoding.encoder.encode(self) }
    static func decode(from data: Data) -> ProbeAckEnvelope? {
        try? RelayEventCoding.decoder.decode(ProbeAckEnvelope.self, from: data)
    }
}

/// WatchConnectivity 消息键；Watch → iPhone 走 sendMessage + transferUserInfo，
/// iPhone → Bridge 由 `WristAgentPhoneRelay` 承接后走 HTTPS。
enum ProbeAckMessage {
    static let envelopeKey = "probe_playback_ack"
}
