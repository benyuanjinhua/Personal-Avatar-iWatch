import Foundation

/// ESS-402 configuration for the Audio Realtime Agent Gateway WSS direct
/// connection. Aligned with Gateway PR #159 contract.
///
/// ### Token semantics (F6 clarification)
///
/// - `authToken` is an **ephemeral** single-use bearer token with a TTL of
///   ≤ 90 s, obtained via `POST /v1/realtime/session-token` (Gateway PR #159).
///   It lives in memory only — never persisted to Keychain or UserDefaults.
/// - The long-lived device credential (used to HMAC-sign the session-token
///   request) lives in `SecureTokenStore` per the existing Bridge auth model.
///   This module does NOT store ephemeral tokens to Keychain.
///
/// ### Reconnect posture (F4/F5 clarification)
///
/// - `maxReconnectAttempts` defaults to **0**: the Gateway issues single-use
///   tokens. A disconnected WSS cannot be reconnected within the same turn
///   without a fresh token from `POST /v1/realtime/session-token`. Token
///   refresh is a downstream ESS-401 integration concern. When the socket
///   drops, the session emits `.failed` and the caller falls back to the
///   existing Bridge path.
/// - No retransmission queue is maintained: reconnection is disallowed, so
///   sequence continuity across sockets is moot.
struct AudioRealtimeAgentConfig: Sendable, Equatable {
    let gatewayURL: URL
    /// Ephemeral single-use bearer token (≤ 90 s TTL). Memory only.
    let authToken: String
    /// Device identity for scope binding (sent as `device_id` URL query param).
    let deviceId: String
    let connectionTimeout: TimeInterval
    /// ESS-842: how long the client keeps waiting after `audio.commit` before
    /// it gives up on its own. It must stay **longer** than the Gateway's
    /// committed-turn deadline plus delivery margin — otherwise the client
    /// leaves first and the Gateway's structured `error` frame lands on a
    /// socket nobody is reading, which is exactly the failure the incident
    /// left behind as a bare `close_code=1006`.
    ///
    /// The ordering is asserted by `AudioRealtimeAgentSessionTests`
    /// (`testResponseWaitBudgetOutlastsGatewayDeadline`) against
    /// `gatewayResponseDeadline`.
    let responseWaitTimeout: TimeInterval
    /// Default heartbeat interval matches Gateway's default (15 s).
    let heartbeatInterval: TimeInterval
    /// 0 = no reconnect. Single-use tokens make reconnect structurally
    /// impossible without a fresh token (F4).
    let maxReconnectAttempts: Int

    /// ESS-842 client-side mirror of the Gateway's shipped
    /// `agent_response_timeout_ms` (`AudioRealtimeGateway/config.json`, 8000 ms).
    /// Kept as a named constant so the wait-budget ordering is a checked
    /// invariant instead of two numbers that silently drift apart.
    static let gatewayResponseDeadline: TimeInterval = 8.0

    /// Margin the Gateway's `error` frame needs to travel and be handled
    /// (matches `ERROR_DELIVERY_MARGIN_MS` in
    /// `AudioRealtimeGateway/test/ess842-response-deadline.test.mjs`).
    static let gatewayErrorDeliveryMargin: TimeInterval = 1.5

    // MARK: - ESS-1004 回合终态预算

    /// ESS-1004：Gateway 出厂 `agent_turn_idle_backstop_ms` 的客户端镜像
    /// （`AudioRealtimeGateway/config.json`，32000 ms）。
    ///
    /// 这不是一条「兜底」：上游的 `voice.state {state:'idle'}` 对本客户端形态
    /// 不可达（取证见 `qwen-agent-transport.mjs` 的 `turnIdleBackstopMs` 注释），
    /// 所以它是多段回合**唯一**的终态来源。客户端等待预算必须显著长于它，
    /// 否则客户端先到点、误报「回答超时」并自动挂断 —— 这就是 ESS-1004 的事故。
    static let gatewayTurnIdleBackstop: TimeInterval = 32.0

    /// 兜底到点 → `audio.done` 穿过 WAN 到达并被处理所需的余量。
    /// 与 `gatewayErrorDeliveryMargin` 同口径。
    static let turnTerminalDeliveryMargin: TimeInterval = 1.5

    /// 客户端硬超时与 Gateway 终态之间必须保留的最小间隔。
    ///
    /// 光是「不相等」不够：ESS-969 把两者都设成 45.0 s，真机 2026-08-22 10:35:47.740
    /// 客户端先到点，兜底从未起作用。要让终态真正有机会先到，间隔必须大于
    /// 任何单次调度抖动加一次 WAN 往返。与
    /// `test/ess1004-turn-terminal-budget.test.mjs` 的 `REQUIRED_SEPARATION_MS` 同值。
    static let turnTerminalRequiredSeparation: TimeInterval = 8.0

    /// 客户端「思考」硬超时。`Watch/SessionController.thinkingHardTimeoutSeconds`
    /// 直接取这个值，段落播完后由 `markAnswerInterim` 重新武装。
    ///
    /// 放在 Shared 而不是 Watch 里，是为了让「它必须显著晚于 Gateway 终态」
    /// 这条不变量能被 `swift test` 检查（`Ess1004TurnTerminalBudgetTests`）——
    /// 两个数分居两个仓库目录时，它们上一次就是这样悄悄漂到相等的。
    static let clientThinkingHardTimeout: TimeInterval = 45.0

    init(
        gatewayURL: URL,
        authToken: String,
        deviceId: String,
        connectionTimeout: TimeInterval = 10.0,
        responseWaitTimeout: TimeInterval = 15.0,
        heartbeatInterval: TimeInterval = 15.0,
        maxReconnectAttempts: Int = 0
    ) {
        self.gatewayURL = gatewayURL
        self.authToken = authToken
        self.deviceId = deviceId
        self.connectionTimeout = connectionTimeout
        self.responseWaitTimeout = responseWaitTimeout
        self.heartbeatInterval = heartbeatInterval
        self.maxReconnectAttempts = maxReconnectAttempts
    }

    // MARK: - URL Validation

    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalidScheme(String)
        case missingHost
        case notAbsolute

        var description: String {
            switch self {
            case .invalidScheme(let scheme):
                return "不支持的协议：\(scheme)。生产环境必须使用 wss://"
            case .missingHost:
                return "Gateway URL 缺少 host"
            case .notAbsolute:
                return "Gateway URL 必须是绝对地址"
            }
        }
    }

    static func validate(
        urlString: String,
        authToken: String,
        deviceId: String,
        allowInsecure: Bool = false
    ) -> Result<AudioRealtimeAgentConfig, ValidationError> {
        guard let url = URL(string: urlString) else {
            return .failure(.notAbsolute)
        }
        guard url.host != nil, !(url.host ?? "").isEmpty else {
            return .failure(.missingHost)
        }
        guard let scheme = url.scheme?.lowercased() else {
            return .failure(.invalidScheme("(none)"))
        }
        switch scheme {
        case "wss": break
        case "ws":
            guard allowInsecure else { return .failure(.invalidScheme(scheme)) }
        default:
            return .failure(.invalidScheme(scheme))
        }
        guard !authToken.isEmpty else {
            return .failure(.invalidScheme("missing auth token"))
        }
        guard !deviceId.isEmpty else {
            return .failure(.invalidScheme("missing device_id"))
        }
        return .success(AudioRealtimeAgentConfig(
            gatewayURL: url, authToken: authToken, deviceId: deviceId
        ))
    }
}
