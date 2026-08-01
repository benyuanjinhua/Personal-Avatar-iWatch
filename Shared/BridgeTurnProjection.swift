import Foundation

/// Bridge WSS /v1/voice/events 的真实下行契约（ESS-38）。
/// Bridge 只发两种消息：连接即回放的 `{type:"snapshot", turns:[…]}`（非终态回合
/// + TTL 内尚未被 Watch 确认的终态回合）
/// 与增量 `{type:"turn.state", turn:{…}}`。turn 即账本投影（ledger.projection）。
/// 防御性解码：未知 type/status/字段一律忽略，坏 JSON 返回 nil。
struct BridgeEventMessage: Decodable {
    let type: String
    let turn: BridgeTurnProjection?
    let turns: [BridgeTurnProjection]?
    let interim: BridgeInterimProjection?

    static func decode(from data: Data) -> BridgeEventMessage? {
        try? VoiceProtocolJSON.decoder.decode(BridgeEventMessage.self, from: data)
    }
}

struct BridgeInterimProjection: Decodable, Equatable {
    let requestId: String
    let deliverySequence: Int
    let text: String
    let audio: BridgeInterimAudio?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case deliverySequence = "delivery_sequence"
        case text, audio
    }
}

struct BridgeInterimAudio: Decodable, Equatable {
    let base64: String
    let sha256: String
    let codec: String
    let durationMs: Int?
    let sizeBytes: Int?

    enum CodingKeys: String, CodingKey {
        case base64, sha256, codec
        case durationMs = "duration_ms"
        case sizeBytes = "size_bytes"
    }
}

/// 结果语音文件元数据（ESS-38）：inline base64 缺席（超限被裁）时，
/// 凭它经 GET /v1/voice/turns/{id}/audio 有界下载取回，sha256 校验后才可用。
struct BridgeResultAudioMeta: Codable, Equatable {
    let sha256: String
    let codec: String
    let durationMs: Int?
    let sizeBytes: Int?
    let truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case sha256
        case codec
        case durationMs = "duration_ms"
        case sizeBytes = "size_bytes"
        case truncated
    }
}

struct BridgeTurnResult: Codable, Equatable {
    /// 后台路径为任务结果文本，direct 路径为助手转写。
    let text: String?
    let audioBase64: String?
    let truncated: Bool?
    /// Qwen Audio Realtime 播报的口气转写（announcement transcript）。
    let speechText: String?
    let audio: BridgeResultAudioMeta?

    enum CodingKeys: String, CodingKey {
        case text
        case audioBase64 = "audio_base64"
        case truncated
        case speechText = "speech_text"
        case audio
    }
}

struct BridgeTurnPermission: Codable, Equatable {
    let id: String
    let title: String?
    let description: String?
}

/// Bridge 账本投影（TurnLedger.projection 的客户端视图）。
struct BridgeTurnProjection: Decodable, Equatable {
    let requestId: String
    let status: String
    let detail: String?
    let path: String?
    let permission: BridgeTurnPermission?
    let result: BridgeTurnResult?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case status
        case detail
        case path
        case permission
        case result
        case error
    }
}

extension BridgeTurnProjection {
    /// Bridge 北向状态（status + detail 子状态）→ Watch 状态机。
    /// 未知 status 返回 nil（忽略，不中断事件流）。
    var turnState: VoiceTurnState? {
        switch status {
        case "accepted":
            return .accepted
        case "processing":
            switch detail {
            case "background_accepted":
                return .backgroundAccepted
            case let sub? where sub.hasPrefix("background_") || sub == "write_denied_read_only":
                return .backgroundProcessing
            default:
                return .realtimeProcessing
            }
        case "permission_required":
            return .permissionRequired
        case "completed":
            return .completed
        case "failed":
            return .failed
        case "cancelled":
            return .cancelled
        default:
            return nil
        }
    }

    /// 面向用户的补充说明：失败时给稳定错误码，其余透传子状态。
    /// 「没听清」类失败（ESS-41 B2）翻译成可执行的中文提示，不裸露错误码。
    var detailText: String? {
        guard status == "failed" else { return detail }
        switch error {
        case "ERR_AUDIO_TOO_SHORT", "ERR_TRANSCRIPT_DISCARDED":
            return "没听清，请重说"
        default:
            return error ?? detail
        }
    }

    /// completed 投影 → Watch 结果载荷。speechSha256/speechDurationMs 来自
    /// 语音文件元数据；无音频时为 nil（纯文本降级）。
    var resultPayload: VoiceResultPayload? {
        guard status == "completed" else { return nil }
        let summary = result?.text ?? result?.speechText ?? "已完成"
        return VoiceResultPayload(
            summary: summary,
            isTruncated: result?.truncated ?? false,
            speechSha256: result?.audio?.sha256.lowercased(),
            speechDurationMs: result?.audio?.durationMs
        )
    }

    /// 投影 → Watch 状态信封（VoiceTurnJournal 的入账单位）。
    /// permission_required 而权限载荷缺失时返回 nil（信封校验不过，宁缺毋滥）。
    func statusEnvelope(at date: Date = Date()) -> VoiceStatusEnvelope? {
        guard let state = turnState else { return nil }
        var permissionPayload: VoicePermissionPayload?
        if state == .permissionRequired {
            guard let permission else { return nil }
            permissionPayload = VoicePermissionPayload(
                id: permission.id,
                action: "confirm",
                target: permission.title ?? "权限请求",
                summary: permission.description ?? permission.title ?? ""
            )
        }
        return VoiceStatusEnvelope.status(
            requestId: requestId,
            state: state,
            occurredAt: date,
            detail: detailText,
            failureStage: state == .failed ? .execution : nil,
            permission: permissionPayload,
            result: resultPayload
        )
    }
}
