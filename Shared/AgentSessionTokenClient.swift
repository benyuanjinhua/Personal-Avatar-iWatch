import Foundation

struct AgentSessionTokenScope: Codable, Equatable, Sendable {
    let deviceId: String
    let sessionId: String
    let requestId: String
    let generation: Int

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case sessionId = "session_id"
        case requestId = "request_id"
        case generation
    }
}

struct AgentSessionTokenResponse: Codable, Equatable, Sendable {
    let token: String
    let expiresAt: Int64
    let ttlMs: Int
    let scope: AgentSessionTokenScope

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case ttlMs = "ttl_ms"
        case scope
    }
}

enum AgentSessionTokenError: Error, Equatable {
    case invalidGatewayURL
    case invalidResponse
    case rejected(code: String, status: Int)
    case scopeMismatch
}

/// Mints one short-lived, single-upgrade Gateway token for a realtime turn.
/// The returned token is never persisted; callers retain it only until the
/// WSS transport consumes it.
struct AgentSessionTokenClient {
    private struct RequestBody: Codable {
        let protocolVersion: Int
        let deviceId: String
        let sessionId: String
        let requestId: String
        let generation: Int
        let ttlMs: Int

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case deviceId = "device_id"
            case sessionId = "session_id"
            case requestId = "request_id"
            case generation
            case ttlMs = "ttl_ms"
        }
    }

    private struct ErrorBody: Codable { let error: String }

    let gatewayURL: URL
    let credentials: RelayDeviceCredentials
    let session: URLSession

    init(
        gatewayURL: URL,
        credentials: RelayDeviceCredentials,
        session: URLSession = .shared
    ) {
        self.gatewayURL = gatewayURL
        self.credentials = credentials
        self.session = session
    }

    func mint(
        requestId: String,
        sessionId: String,
        generation: Int,
        ttlMs: Int = 30_000
    ) async throws -> AgentSessionTokenResponse {
        guard generation > 0, var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false) else {
            throw AgentSessionTokenError.invalidGatewayURL
        }
        switch components.scheme?.lowercased() {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        case "https", "http": break
        default: throw AgentSessionTokenError.invalidGatewayURL
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let baseURL = components.url else { throw AgentSessionTokenError.invalidGatewayURL }

        let scope = AgentSessionTokenScope(
            deviceId: credentials.deviceId,
            sessionId: sessionId,
            requestId: requestId,
            generation: generation
        )
        let body = try JSONEncoder().encode(RequestBody(
            protocolVersion: 1,
            deviceId: scope.deviceId,
            sessionId: scope.sessionId,
            requestId: scope.requestId,
            generation: scope.generation,
            ttlMs: ttlMs
        ))
        let request = RelaySignedRequestBuilder(baseURL: baseURL, credentials: credentials)
            .request(
                method: "POST",
                path: "/v1/realtime/session-token",
                requestId: requestId,
                body: body
            )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentSessionTokenError.invalidResponse
        }
        guard http.statusCode == 201 else {
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data).error) ?? "ERR_UNKNOWN"
            throw AgentSessionTokenError.rejected(code: code, status: http.statusCode)
        }
        let issued = try JSONDecoder().decode(AgentSessionTokenResponse.self, from: data)
        guard issued.scope == scope, !issued.token.isEmpty else {
            throw AgentSessionTokenError.scopeMismatch
        }
        return issued
    }
}
