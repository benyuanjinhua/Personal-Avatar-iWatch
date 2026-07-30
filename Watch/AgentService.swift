import Foundation

protocol AgentServing {
    func submit(audio: Data, conciseReply: Bool) async throws -> AgentTurnResponse
    func confirm(id: String, approved: Bool) async throws -> AgentTurnResponse
    func task(id: String) async throws -> AgentTaskResponse
    func undo(id: String) async throws -> AgentTurnResponse
    func cancel(taskID: String) async
}

enum AgentServiceError: LocalizedError {
    case invalidEndpoint
    case insecureEndpoint
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Agent 地址无效，请在 iPhone 腕语设置中检查。"
        case .insecureEndpoint: return "真机只允许使用 HTTPS Agent 地址。"
        case .invalidResponse: return "Agent 返回了无法识别的数据。"
        case let .server(status, message): return "Agent 请求失败（\(status)）：\(message)"
        }
    }
}

final class UnavailableAgentService: AgentServing {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func submit(audio: Data, conciseReply: Bool) async throws -> AgentTurnResponse { throw error }
    func confirm(id: String, approved: Bool) async throws -> AgentTurnResponse { throw error }
    func task(id: String) async throws -> AgentTaskResponse { throw error }
    func undo(id: String) async throws -> AgentTurnResponse { throw error }
    func cancel(taskID: String) async {}
}

final class CloudAgentService: AgentServing {
    private let endpoint: URL
    private let token: String
    private let session: URLSession

    init(configuration: AgentConfiguration, session: URLSession = .shared) throws {
        guard let url = URL(string: configuration.endpoint), url.host != nil else {
            throw AgentServiceError.invalidEndpoint
        }
        guard Self.isAllowed(url) else {
            throw AgentServiceError.insecureEndpoint
        }
        endpoint = url
        token = configuration.bearerToken
        self.session = session
    }

    private static func isAllowed(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
#if DEBUG
        // Development-only escape hatch for the bundled LAN mock gateway.
        if url.scheme?.lowercased() == "http" {
            let host = url.host?.lowercased() ?? ""
            return host == "localhost"
                || host == "127.0.0.1"
                || host.hasPrefix("192.168.")
                || host.hasPrefix("10.")
                || host.hasPrefix("172.16.")
        }
#endif
        return false
    }

    func submit(audio: Data, conciseReply: Bool) async throws -> AgentTurnResponse {
        struct Payload: Encodable {
            let audioBase64: String
            let audioFormat = "m4a"
            let locale = "zh-CN"
            let client = "watchos"
            let conciseReply: Bool

            enum CodingKeys: String, CodingKey {
                case audioBase64 = "audio_base64"
                case audioFormat = "audio_format"
                case locale, client
                case conciseReply = "concise_reply"
            }
        }
        return try await request(
            path: "v1/turns",
            method: "POST",
            body: Payload(audioBase64: audio.base64EncodedString(), conciseReply: conciseReply),
            response: AgentTurnResponse.self
        )
    }

    func confirm(id: String, approved: Bool) async throws -> AgentTurnResponse {
        try await request(
            path: "v1/confirmations/\(id)",
            method: "POST",
            body: AgentConfirmationRequest(confirmationID: id, approved: approved),
            response: AgentTurnResponse.self
        )
    }

    func task(id: String) async throws -> AgentTaskResponse {
        try await request(path: "v1/tasks/\(id)", method: "GET", response: AgentTaskResponse.self)
    }

    func undo(id: String) async throws -> AgentTurnResponse {
        struct Empty: Encodable {}
        return try await request(
            path: "v1/undo/\(id)",
            method: "POST",
            body: Empty(),
            response: AgentTurnResponse.self
        )
    }

    func cancel(taskID: String) async {
        struct Empty: Encodable {}
        let _: AgentTaskResponse? = try? await request(
            path: "v1/tasks/\(taskID)/cancel",
            method: "POST",
            body: Empty(),
            response: AgentTaskResponse.self
        )
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        response: Response.Type
    ) async throws -> Response {
        try await request(path: path, method: method, body: Optional<String>.none, response: response)
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?,
        response: Response.Type
    ) async throws -> Response {
        let url = endpoint.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, rawResponse) = try await session.data(for: request)
        guard let httpResponse = rawResponse as? HTTPURLResponse else {
            throw AgentServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "未知错误"
            throw AgentServiceError.server(status: httpResponse.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AgentServiceError.invalidResponse
        }
    }
}
