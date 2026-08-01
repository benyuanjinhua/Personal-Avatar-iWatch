import CryptoKit
import Foundation

/// iPhone Relay ↔ Mac Remote Frontend Bridge 的 wire 协议（ESS-23 已在真机 tailnet 验证）。
/// 鉴权：签名密钥 = SHA256(设备 Token)；HMAC-SHA256 覆盖
/// "v1\n<device_id>\n<method>\n<path>\n<request_id>\n<timestamp_ms>\n<nonce>\n<body_sha256>"。
enum RelayWire {
    /// Bridge config.json 的 protocol_version（整数，区别于 Watch↔iPhone 信封的 "1.0"）。
    static let protocolVersion = 1

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalString(
        deviceId: String, method: String, path: String,
        requestId: String, timestampMs: String, nonce: String, bodySha256: String
    ) -> String {
        ["v1", deviceId, method, path, requestId, timestampMs, nonce, bodySha256]
            .joined(separator: "\n")
    }

    static func signatureHex(canonical: String, signingKey: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: signingKey)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// 配对后 Mac 签发的设备凭据。真机上整体存 iPhone Keychain
/// （kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly），绝不进入 Watch 或日志。
struct RelayDeviceCredentials: Codable, Equatable {
    let deviceId: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case token
    }

    /// HMAC 密钥 = SHA256(token)；Bridge 侧只存这个哈希，不存原始 Token。
    var signingKey: SymmetricKey {
        SymmetricKey(data: Data(SHA256.hash(data: Data(token.utf8))))
    }
}

/// POST /v1/voice/turns 请求体：ESS-22 信封元数据 + base64 音频。
struct VoiceTurnUpload: Codable {
    let protocolVersion: Int
    let requestId: String
    let type: String
    let createdAt: String
    let audio: VoiceAudioDescriptor
    let audioBase64: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case type
        case createdAt = "created_at"
        case audio
        case audioBase64 = "audio_base64"
    }

    init(envelope: VoiceRequestEnvelope, audioData: Data) {
        protocolVersion = RelayWire.protocolVersion
        requestId = envelope.requestId
        type = "audio_request"
        createdAt = ISO8601DateFormatter().string(from: envelope.createdAt)
        audio = envelope.audio
        audioBase64 = audioData.base64EncodedString()
    }
}

struct VoiceTurnResponse: Codable {
    let requestId: String
    let status: String
    let idempotentReplay: Bool?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case status
        case idempotentReplay = "idempotent_replay"
    }
}

struct BridgeErrorBody: Codable {
    let error: String
}

enum RelayUploadError: Error {
    /// Bridge 返回的稳定错误码（ERR_*）；4xx（非 429）不应重试。
    case bridge(code: String, httpStatus: Int)
    case transport(Error)
    case badResponse

    var isRetryable: Bool {
        switch self {
        case .bridge(_, let status):
            return status >= 500 || status == 429 || status == 408
        case .transport, .badResponse:
            return true
        }
    }

    var stableCode: String {
        switch self {
        case .bridge(let code, _): return code
        case .transport: return "ERR_TRANSPORT"
        case .badResponse: return "ERR_BAD_RESPONSE"
        }
    }
}

/// 生成带签名头的 Bridge 请求。timestamp/nonce 可注入以便测试。
struct RelaySignedRequestBuilder {
    let baseURL: URL
    let credentials: RelayDeviceCredentials

    func request(
        method: String,
        path: String,
        requestId: String,
        body: Data?,
        timestampMs: String? = nil,
        nonce: String? = nil
    ) -> URLRequest {
        let timestamp = timestampMs ?? String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonceValue = nonce ?? UUID().uuidString
        let bodySha = RelayWire.sha256Hex(body ?? Data())
        let canonical = RelayWire.canonicalString(
            deviceId: credentials.deviceId, method: method, path: path,
            requestId: requestId, timestampMs: timestamp, nonce: nonceValue, bodySha256: bodySha
        )
        let signature = RelayWire.signatureHex(canonical: canonical, signingKey: credentials.signingKey)

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.deviceId, forHTTPHeaderField: "X-Device-Id")
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Request-Timestamp")
        request.setValue(nonceValue, forHTTPHeaderField: "X-Nonce")
        request.setValue(bodySha, forHTTPHeaderField: "X-Body-SHA256")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
        return request
    }
}

/// Bridge HTTP 客户端：配对 + 幂等上送。重试调度由 outbox/relay 负责，
/// 本类型只做单次请求与稳定错误码映射。
final class RelayClient {
    private let baseURL: URL
    private let credentials: RelayDeviceCredentials
    private let session: URLSession

    init(baseURL: URL, credentials: RelayDeviceCredentials, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
    }

    /// 一次性配对码（Mac 端展示）换取设备凭据。
    static func pair(
        baseURL: URL, pairingCode: String, deviceName: String, session: URLSession = .shared
    ) async throws -> RelayDeviceCredentials {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/pair"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "pairing_code": pairingCode,
            "device_name": deviceName,
        ])
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayUploadError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw RelayUploadError.badResponse }
        guard http.statusCode == 201 else {
            let code = (try? JSONDecoder().decode(BridgeErrorBody.self, from: data))?.error ?? "ERR_UNKNOWN"
            throw RelayUploadError.bridge(code: code, httpStatus: http.statusCode)
        }
        return try JSONDecoder().decode(RelayDeviceCredentials.self, from: data)
    }

    /// 结果语音有界取回（ESS-38）：GET /v1/voice/turns/{id}/audio。
    /// rangeStart 非 nil 时带 Range 头断点续传（Bridge 返回 206 + 剩余字节）。
    /// 返回 (字节, HTTP 状态码)；sha256 校验由调用方按结果元数据执行。
    func fetchResultAudio(requestId: String, rangeStart: Int? = nil) async throws -> (Data, Int) {
        var request = RelaySignedRequestBuilder(baseURL: baseURL, credentials: credentials)
            .request(
                method: "GET", path: "/v1/voice/turns/\(requestId)/audio",
                requestId: requestId, body: nil
            )
        if let rangeStart, rangeStart > 0 {
            request.setValue("bytes=\(rangeStart)-", forHTTPHeaderField: "Range")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayUploadError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw RelayUploadError.badResponse }
        return (data, http.statusCode)
    }

    /// 上送一个 Watch 日志 chunk（ESS-42）：POST /v1/client-logs。
    /// 重试复用同一 chunk_id 作为 request_id（新 nonce/签名），Bridge 按 chunk_id 幂等去重。
    func uploadClientLogs(chunkId: String, jsonl: String) async throws {
        let body = try ClientLogUploadBody(chunkId: chunkId, jsonl: jsonl).jsonData()
        let request = RelaySignedRequestBuilder(baseURL: baseURL, credentials: credentials)
            .request(method: "POST", path: "/v1/client-logs", requestId: chunkId, body: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayUploadError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw RelayUploadError.badResponse }
        guard http.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(BridgeErrorBody.self, from: data))?.error ?? "ERR_UNKNOWN"
            throw RelayUploadError.bridge(code: code, httpStatus: http.statusCode)
        }
    }

    /// 上送一个 turn；重试时以同一 request_id 重新调用（新 nonce/签名），Bridge 幂等去重。
    func upload(envelope: VoiceRequestEnvelope, audioData: Data) async throws -> VoiceTurnResponse {
        let body = try JSONEncoder().encode(VoiceTurnUpload(envelope: envelope, audioData: audioData))
        let request = RelaySignedRequestBuilder(baseURL: baseURL, credentials: credentials)
            .request(method: "POST", path: "/v1/voice/turns", requestId: envelope.requestId, body: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayUploadError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw RelayUploadError.badResponse }
        guard http.statusCode == 202 || http.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(BridgeErrorBody.self, from: data))?.error ?? "ERR_UNKNOWN"
            throw RelayUploadError.bridge(code: code, httpStatus: http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(VoiceTurnResponse.self, from: data) else {
            throw RelayUploadError.badResponse
        }
        return decoded
    }
}
