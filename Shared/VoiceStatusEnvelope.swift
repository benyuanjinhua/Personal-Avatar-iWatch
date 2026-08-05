import Foundation

enum AudioDownlinkKind: String, Codable, Equatable, CaseIterable {
    case welcome
    case interim
    case result
    /// ESS-184/207：下行链路端到端探针。不入 journal、不入结果播放账本、不入
    /// EncryptedAudioVault，Watch 收到即播、播完发 probe_ack。生产音频白名单
    /// 契约与 result/interim 相同（`AudioDownlinkPolicy.allows(.probe, ...)`）。
    case probe
    /// 仅用于 fail-closed 解码和落拒绝日志，永不属于播放白名单。
    case unknown
}

enum AudioDownlinkPolicy {
    static func allows(_ kind: AudioDownlinkKind?, expected: Set<AudioDownlinkKind>) -> Bool {
        guard let kind else { return false }
        return expected.contains(kind)
    }
}

/// iPhone → Watch 状态/权限/结果事件，以及 Watch → iPhone 权限决定/取消请求的版本化信封（ESS-29）。
/// 与 VoiceRequestEnvelope 一样，两端只交换本文件结构的 JSON 编码，不传任意字典。
enum VoiceProtocolJSON {
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

/// permission_required 附带的权限请求载荷：“允许修改 X 文件？”
struct VoicePermissionPayload: Codable, Equatable {
    let id: String
    let action: String
    let target: String
    let summary: String
}

/// completed 附带的结果载荷；长文本由 Mac 侧裁剪成摘要，Watch 只展示摘要。
struct VoiceResultPayload: Codable, Equatable {
    /// Watch 端摘要展示的最大字符数（最后一道防线，正常裁剪发生在 Mac 侧）。
    static let maxSummaryLength = 300

    let summary: String
    let isTruncated: Bool
    let speechSha256: String?
    let speechDurationMs: Int?

    enum CodingKeys: String, CodingKey {
        case summary
        case isTruncated = "is_truncated"
        case speechSha256 = "speech_sha256"
        case speechDurationMs = "speech_duration_ms"
    }

    /// 上游漏裁剪时在 Watch 端兜底截断。
    var displaySummary: String {
        guard summary.count > Self.maxSummaryLength else { return summary }
        return String(summary.prefix(Self.maxSummaryLength)) + "…"
    }

    var displayIsTruncated: Bool {
        isTruncated || summary.count > Self.maxSummaryLength
    }
}

/// iPhone → Watch 的状态事件信封（sendMessage / transferUserInfo / transferFile 元数据）。
///
/// ESS-180：failed 事件必须承载 Bridge 侧稳定 error_code（`ERR_*`）。旧路径
/// 把 error_code 塞到 `detail` 字符串里，Watch 端要重新解析才能查表；新增
/// `errorCode` 字段后，Watch 直接按 code → (文字, 语音, 触觉) 决策，不再
/// 把 UI 拟人化文案的责任压到 Bridge/iPhone 层。
struct VoiceStatusEnvelope: Codable, Equatable {
    static let currentProtocolVersion = "1.0"
    static let statusType = "voice_status"

    let protocolVersion: String
    let requestId: String
    let type: String
    let state: VoiceTurnState
    let occurredAt: Date
    let detail: String?
    let failureStage: VoiceFailureStage?
    let permission: VoicePermissionPayload?
    let result: VoiceResultPayload?
    let audioKind: AudioDownlinkKind?
    /// 失败态才有值；`ERR_*` 稳定短码，见 MacRemoteFrontendBridge/ledger.mjs 的
    /// `ledger.fail(requestId, code)`。旧信封无此字段——Watch 端解码兼容缺失。
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case type
        case state
        case occurredAt = "occurred_at"
        case detail
        case failureStage = "failure_stage"
        case permission
        case result
        case audioKind = "audio_kind"
        case errorCode = "error_code"
    }

    init(
        protocolVersion: String, requestId: String, type: String, state: VoiceTurnState,
        occurredAt: Date, detail: String?, failureStage: VoiceFailureStage?,
        permission: VoicePermissionPayload?, result: VoiceResultPayload?,
        audioKind: AudioDownlinkKind? = nil,
        errorCode: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.type = type
        self.state = state
        self.occurredAt = occurredAt
        self.detail = detail
        self.failureStage = failureStage
        self.permission = permission
        self.result = result
        self.audioKind = audioKind
        self.errorCode = errorCode
    }

    static func status(
        requestId: String,
        state: VoiceTurnState,
        occurredAt: Date = Date(),
        detail: String? = nil,
        failureStage: VoiceFailureStage? = nil,
        permission: VoicePermissionPayload? = nil,
        result: VoiceResultPayload? = nil,
        audioKind: AudioDownlinkKind? = nil,
        errorCode: String? = nil
    ) -> VoiceStatusEnvelope {
        VoiceStatusEnvelope(
            protocolVersion: currentProtocolVersion,
            requestId: requestId,
            type: statusType,
            state: state,
            occurredAt: occurredAt,
            detail: detail,
            failureStage: failureStage,
            permission: permission,
            result: result,
            audioKind: audioKind,
            errorCode: errorCode
        )
    }

    func jsonData() throws -> Data {
        try VoiceProtocolJSON.encoder.encode(self)
    }

    static func decode(from data: Data) throws -> VoiceStatusEnvelope {
        try VoiceProtocolJSON.decoder.decode(VoiceStatusEnvelope.self, from: data)
    }

    /// 结构合法性校验；接收端在入账前必须先通过。
    func validate() -> String? {
        guard protocolVersion == Self.currentProtocolVersion else { return "不支持的协议版本：\(protocolVersion)" }
        guard type == Self.statusType else { return "不支持的消息类型：\(type)" }
        guard UUID(uuidString: requestId) != nil else { return "request_id 不是合法 UUID" }
        if state == .permissionRequired && permission == nil { return "permission_required 缺少权限载荷" }
        return nil
    }
}

/// Watch → iPhone 的权限决定。Watch 不保存任何可签名凭据，
/// 签名由 iPhone Relay 持设备密钥补齐后回传 Mac（§5.3，ESS-28）。
struct PermissionDecisionEnvelope: Codable, Equatable {
    static let currentProtocolVersion = "1.0"
    static let decisionType = "permission_decision"

    let protocolVersion: String
    let requestId: String
    let type: String
    let permissionId: String
    let approved: Bool
    let decidedAt: Date

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case type
        case permissionId = "permission_id"
        case approved
        case decidedAt = "decided_at"
    }

    static func decision(
        requestId: String,
        permissionId: String,
        approved: Bool,
        decidedAt: Date = Date()
    ) -> PermissionDecisionEnvelope {
        PermissionDecisionEnvelope(
            protocolVersion: currentProtocolVersion,
            requestId: requestId,
            type: decisionType,
            permissionId: permissionId,
            approved: approved,
            decidedAt: decidedAt
        )
    }

    func jsonData() throws -> Data {
        try VoiceProtocolJSON.encoder.encode(self)
    }

    static func decode(from data: Data) throws -> PermissionDecisionEnvelope {
        try VoiceProtocolJSON.decoder.decode(PermissionDecisionEnvelope.self, from: data)
    }

    func validate() -> String? {
        guard protocolVersion == Self.currentProtocolVersion else { return "不支持的协议版本：\(protocolVersion)" }
        guard type == Self.decisionType else { return "不支持的消息类型：\(type)" }
        guard UUID(uuidString: requestId) != nil else { return "request_id 不是合法 UUID" }
        guard !permissionId.isEmpty else { return "permission_id 为空" }
        return nil
    }
}

/// Watch → iPhone 的取消请求；iPhone 转发 Mac 北向 cancel（ESS-26/27）。
struct VoiceCancelEnvelope: Codable, Equatable {
    static let currentProtocolVersion = "1.0"
    static let cancelType = "voice_cancel"

    let protocolVersion: String
    let requestId: String
    let type: String
    let requestedAt: Date

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case type
        case requestedAt = "requested_at"
    }

    static func cancel(requestId: String, requestedAt: Date = Date()) -> VoiceCancelEnvelope {
        VoiceCancelEnvelope(
            protocolVersion: currentProtocolVersion,
            requestId: requestId,
            type: cancelType,
            requestedAt: requestedAt
        )
    }

    func jsonData() throws -> Data {
        try VoiceProtocolJSON.encoder.encode(self)
    }

    static func decode(from data: Data) throws -> VoiceCancelEnvelope {
        try VoiceProtocolJSON.decoder.decode(VoiceCancelEnvelope.self, from: data)
    }
}

/// WatchConnectivity 消息/元数据里承载各信封 JSON 的键。
enum VoiceStatusMessage {
    static let envelopeKey = "voice_status_envelope"
}

/// iPhone → Watch 的结果语音降级事件。结果文本已经完成入账时，音频链路的
/// 后续失败不能再伪装成第二个 turn 终态（completed 会被状态机吸收），因此
/// 使用独立事件表达“文字已到、语音未到”。
struct VoiceResultAudioDegradationEnvelope: Codable, Equatable {
    static let currentProtocolVersion = "1.0"
    static let eventType = "result_audio_degraded"

    let protocolVersion: String
    let requestId: String
    let type: String
    let errorCode: String
    let occurredAt: Date

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case type
        case errorCode = "error_code"
        case occurredAt = "occurred_at"
    }

    static func event(
        requestId: String, errorCode: String = "ERR_NO_SPEECH_FILE", occurredAt: Date = Date()
    ) -> Self {
        Self(
            protocolVersion: currentProtocolVersion, requestId: requestId,
            type: eventType, errorCode: errorCode, occurredAt: occurredAt
        )
    }

    func validate() -> String? {
        guard protocolVersion == Self.currentProtocolVersion else { return "不支持的协议版本" }
        guard type == Self.eventType else { return "不支持的事件类型" }
        guard UUID(uuidString: requestId) != nil else { return "request_id 不是合法 UUID" }
        guard errorCode.hasPrefix("ERR_") else { return "error_code 非法" }
        return nil
    }

    func jsonData() throws -> Data { try VoiceProtocolJSON.encoder.encode(self) }
    static func decode(from data: Data) throws -> Self { try VoiceProtocolJSON.decoder.decode(Self.self, from: data) }
}

enum VoiceResultAudioDegradationMessage {
    static let envelopeKey = "voice_result_audio_degradation"
}

enum PermissionDecisionMessage {
    static let envelopeKey = "permission_decision_envelope"
}

enum VoiceCancelMessage {
    static let envelopeKey = "voice_cancel_envelope"
}

/// 结果语音 transferFile 的元数据键，值为携带 result 的 VoiceStatusEnvelope JSON。
enum VoiceSpeechMessage {
    static let envelopeKey = "voice_speech_envelope"
}

/// ESS-184/207 下行探针的 transferFile 元数据键；与 speech 分流：
/// - Watch 端匹配到本键时走探针分支（不落 vault、不入 journal、不入 ledger），
/// - iOS Relay 也用它给结果链路让路（`ResultAudioLedger` 不占探针的位置）。
enum VoiceProbeMessage {
    static let envelopeKey = "voice_probe_envelope"
}

// MARK: - ESS-307 下行队列积压可见性

/// iPhone → Watch 的下行队列积压载荷：告知 Watch 当前有多少条结果还在排队。
/// 通过 `updateApplicationContext` 传递，只保留最新值。
struct DownlinkBacklogPayload: Codable, Equatable {
    let pendingCount: Int
    /// 当前排队中的 requestId 列表，供 Watch 时间线标注「等待送达」。
    let queuedRequestIds: [String]
    let updatedAt: Date

    func jsonData() throws -> Data {
        try VoiceProtocolJSON.encoder.encode(self)
    }

    static func decode(from data: Data) throws -> Self {
        try VoiceProtocolJSON.decoder.decode(Self.self, from: data)
    }
}

/// 与 `DownlinkBacklogPayload` 配对的 WCSession applicationContext 键。
enum DownlinkBacklogMessage {
    static let contextKey = "downlink_backlog"
}
