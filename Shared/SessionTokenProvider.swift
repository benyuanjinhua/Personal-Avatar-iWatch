import Foundation
import os

/// ESS-446: obtains single-use WSS bearer tokens from the Audio Realtime
/// Agent Gateway (`POST /v1/realtime/session-token`).
///
/// Uses the existing device-level `RelayDeviceCredentials` (HMAC-SHA256
/// signing) already stored in Keychain; the API footprint matches the
/// `RelaySignedRequestBuilder` pattern so the Gateway verifies the same
/// `X-Device-Id` / `X-Signature` headers as the Bridge voice relay.
///
/// Token lifecycle:
///   - One token per turn — never reused.
///   - Token lives in memory only; never persisted to Keychain, UserDefaults,
///     or logs (the logger drops `token` / `signature` fields before write).
///   - Gateway enforces single-use + ≤90 s TTL (ESS-388 A1); a second
///     consume returns `ERR_TOKEN_CONSUMED` and the transport MUST obtain a
///     fresh token.
///
/// Threading: the `fetch` method is `@MainActor`-safe but the underlying
/// `URLSession` call is `async`. Callers on the main actor should `await`
/// the result.
///
/// Error handling: `fetch` returns a structured `Result` so callers can
/// distinguish "Gateway refused" vs "network unreachable" vs "bad response
/// shape" and log each with the right severity.
enum SessionTokenProvider {
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "SessionToken"
    )

    // MARK: - Response types

    /// Parsed from Gateway `POST /v1/realtime/session-token` 201 JSON body.
    struct IssuedToken: Sendable, Equatable {
        /// Ephemeral bearer token string (e.g. `rtk_xxxxxxxxxx`). Must NOT
        /// be logged or persisted.
        let token: String
        /// The scope this token is bound to. Must match the WSS query params.
        let deviceId: String
        let sessionId: String?
        let requestId: String?
        /// The generation the token was issued for.
        let generation: Int
        /// TTL in milliseconds as declared by the Gateway.
        let expiresInMs: Int
        /// Gateway protocol version.
        let protocolVersion: Int
    }

    enum FetchError: Error, Equatable {
        /// No device credentials in Keychain — phone isn't paired yet.
        case notPaired
        /// Gateway URL not configured (feature flag gatewayURL is empty).
        case noGatewayURL
        /// HTTP 4xx with a structured `code` + optional `detail`.
        case gatewayRejected(code: String, httpStatus: Int, detail: String?)
        /// Network-level failure (timeout, DNS, TLS, etc.).
        case transport(Error)
        /// HTTP 2xx/5xx, or 4xx without a JSON body, or JSON doesn't parse.
        case badResponse(Int)

        static func == (lhs: FetchError, rhs: FetchError) -> Bool {
            switch (lhs, rhs) {
            case (.notPaired, .notPaired): return true
            case (.noGatewayURL, .noGatewayURL): return true
            case let (.gatewayRejected(c1, s1, d1), .gatewayRejected(c2, s2, d2)):
                return c1 == c2 && s1 == s2 && d1 == d2
            case let (.transport(e1), .transport(e2)):
                return (e1 as NSError) == (e2 as NSError)
            case let (.badResponse(s1), .badResponse(s2)): return s1 == s2
            default: return false
            }
        }
    }

    // MARK: - Coding (snake_case wire contract)

    private struct IssueRequest: Encodable {
        let deviceId: String
        let sessionId: String
        let requestId: String
        let generation: Int
        let protocolVersion: Int

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case sessionId = "session_id"
            case requestId = "request_id"
            case generation
            case protocolVersion = "protocol_version"
        }
    }

    private struct IssueResponse: Decodable {
        let token: String
        let deviceId: String?
        let sessionId: String?
        let requestId: String?
        let generation: Int?
        let expiresInMs: Int?
        let protocolVersion: Int?

        enum CodingKeys: String, CodingKey {
            case token
            case deviceId = "device_id"
            case sessionId = "session_id"
            case requestId = "request_id"
            case generation
            case expiresInMs = "expires_in_ms"
            case protocolVersion = "protocol_version"
        }
    }

    private struct ErrorBody: Decodable {
        let error: String
        let detail: String?
    }

    // MARK: - Fetch

    /// Request a single-use WSS session token from the Agent Gateway.
    ///
    /// - Parameters:
    ///   - gatewayBaseURL: the Gateway HTTP base (e.g. `https://gateway.example.com`).
    ///     The method appends `/v1/realtime/session-token`.
    ///   - deviceId: the device identity from Keychain credentials.
    ///   - sessionId: the WSS session this token will protect.
    ///   - requestId: the request (turn) this token is minted for.
    ///   - generation: the turn generation (≥ 1).
    ///   - credentials: the paired device credentials for HMAC signing.
    ///   - session: URLSession to use (default `.shared`; injectable for tests).
    /// - Returns: `.success(IssuedToken)` or `.failure(FetchError)`.
    static func fetch(
        gatewayBaseURL: URL,
        deviceId: String,
        sessionId: String,
        requestId: String,
        generation: Int,
        credentials: RelayDeviceCredentials,
        session: URLSession = .shared
    ) async -> Result<IssuedToken, FetchError> {
        let path = "/v1/realtime/session-token"
        let body: Data
        do {
            let payload = IssueRequest(
                deviceId: deviceId, sessionId: sessionId,
                requestId: requestId, generation: generation,
                protocolVersion: 1
            )
            body = try JSONEncoder().encode(payload)
        } catch {
            return .failure(.badResponse(0))
        }

        let builder = RelaySignedRequestBuilder(
            baseURL: gatewayBaseURL, credentials: credentials
        )
        var request = builder.request(
            method: "POST", path: path,
            requestId: requestId, body: body
        )
        request.timeoutInterval = 10

        Self.logger.debug(
            "session-token request device=\(deviceId.prefix(8), privacy: .public) gen=\(generation)"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("session-token transport error: \(String(describing: error), privacy: .public)")
            return .failure(.transport(error))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.badResponse(0))
        }

        if http.statusCode == 201 {
            guard let parsed = try? JSONDecoder().decode(IssueResponse.self, from: data),
                  let token = parsed.token.nilIfEmpty,
                  let gen = parsed.generation else {
                Self.logger.error("session-token bad 201 shape")
                return .failure(.badResponse(201))
            }
            let issued = IssuedToken(
                token: token,
                deviceId: parsed.deviceId ?? deviceId,
                sessionId: parsed.sessionId,
                requestId: parsed.requestId,
                generation: gen,
                expiresInMs: parsed.expiresInMs ?? 30_000,
                protocolVersion: parsed.protocolVersion ?? 1
            )
            Self.logger.info(
                "session-token issued gen=\(gen) expires_ms=\(issued.expiresInMs, privacy: .public)"
            )
            return .success(issued)
        }

        // Non-201: extract structured error if available
        if let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            Self.logger.error(
                "session-token rejected code=\(errorBody.error, privacy: .public) status=\(http.statusCode)"
            )
            return .failure(.gatewayRejected(
                code: errorBody.error, httpStatus: http.statusCode, detail: errorBody.detail
            ))
        }
        Self.logger.error("session-token bad response status=\(http.statusCode)")
        return .failure(.badResponse(http.statusCode))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
