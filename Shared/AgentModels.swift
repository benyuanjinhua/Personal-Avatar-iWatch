import Foundation

enum AgentRisk: String, Codable, CaseIterable {
    case readOnly = "read_only"
    case reversible
    case confirmationRequired = "confirmation_required"

    var displayName: String {
        switch self {
        case .readOnly: return "只读"
        case .reversible: return "可撤回"
        case .confirmationRequired: return "需要确认"
        }
    }
}

enum AgentTaskState: String, Codable {
    case completed
    case running
    case failed
    case cancelled
}

struct AgentConfirmation: Codable, Equatable {
    let id: String
    let title: String
    let target: String
    let impact: String
    let actionLabel: String
}

struct AgentUndo: Codable, Equatable {
    let id: String
    let label: String
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, label
        case expiresAt = "expires_at"
    }
}

struct AgentTurnResponse: Codable {
    let turnID: String
    let transcript: String
    let reply: String
    let risk: AgentRisk
    let state: AgentTaskState
    let taskID: String?
    let confirmation: AgentConfirmation?
    let undo: AgentUndo?
    let ttsAudioBase64: String?

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case transcript, reply, risk, state
        case taskID = "task_id"
        case confirmation, undo
        case ttsAudioBase64 = "tts_audio_base64"
    }
}

struct AgentConfirmationRequest: Codable {
    let confirmationID: String
    let approved: Bool

    enum CodingKeys: String, CodingKey {
        case confirmationID = "confirmation_id"
        case approved
    }
}

struct AgentTaskResponse: Codable {
    let taskID: String
    let state: AgentTaskState
    let reply: String?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case state, reply
    }
}

struct AgentConfiguration: Codable, Equatable {
    var mode: ConnectionMode
    var endpoint: String
    var bearerToken: String
    var autoListen: Bool
    var hapticsEnabled: Bool
    var conciseReply: Bool
    /// Shared uplink/downlink L1 gate. Missing values decode as false so an
    /// upgrade can never silently enable streaming.
    var voiceStreamingV2: Bool = false

    enum CodingKeys: String, CodingKey {
        case mode, endpoint, bearerToken, autoListen, hapticsEnabled, conciseReply, voiceStreamingV2
    }

    init(
        mode: ConnectionMode, endpoint: String, bearerToken: String, autoListen: Bool,
        hapticsEnabled: Bool, conciseReply: Bool, voiceStreamingV2: Bool = false
    ) {
        self.mode = mode
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.autoListen = autoListen
        self.hapticsEnabled = hapticsEnabled
        self.conciseReply = conciseReply
        self.voiceStreamingV2 = voiceStreamingV2
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(ConnectionMode.self, forKey: .mode)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        bearerToken = try values.decode(String.self, forKey: .bearerToken)
        autoListen = try values.decode(Bool.self, forKey: .autoListen)
        hapticsEnabled = try values.decode(Bool.self, forKey: .hapticsEnabled)
        conciseReply = try values.decode(Bool.self, forKey: .conciseReply)
        voiceStreamingV2 = try values.decodeIfPresent(Bool.self, forKey: .voiceStreamingV2) ?? false
    }

    static let demo = AgentConfiguration(
        mode: .demo,
        endpoint: "",
        bearerToken: "",
        autoListen: false,
        hapticsEnabled: true,
        conciseReply: true,
        voiceStreamingV2: false
    )
}

enum ConnectionMode: String, Codable, CaseIterable {
    case demo
    case cloud
}

enum ConfigurationMessage {
    static let key = "agent_configuration"
}
