import CryptoKit
import XCTest
@testable import WristAgentCore

final class VoiceRelayWireTests: XCTestCase {
    private let credentials = RelayDeviceCredentials(deviceId: "dev-123", token: "secret-token")
    private let audio = Data("fake-audio".utf8)

    private func makeEnvelope() -> VoiceRequestEnvelope {
        VoiceRequestEnvelope.voiceRequest(
            createdAt: Date(timeIntervalSince1970: 1_753_920_000),
            audio: VoiceAudioDescriptor(
                codec: "aac", sampleRate: 16_000, channels: 1, durationMs: 8_200,
                sha256: VoiceDigest.sha256Hex(of: audio)
            )
        )
    }

    func testTurnUploadMatchesBridgeContract() throws {
        let upload = VoiceTurnUpload(envelope: makeEnvelope(), audioData: audio)
        XCTAssertEqual(upload.protocolVersion, 1, "Bridge config.json 的 protocol_version 是整数 1")
        XCTAssertEqual(upload.type, "audio_request")
        XCTAssertEqual(upload.audioBase64, audio.base64EncodedString())

        let json = String(data: try JSONEncoder().encode(upload), encoding: .utf8)!
        for key in ["protocol_version", "request_id", "created_at", "audio_base64", "duration_ms", "sha256"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "缺少 wire 字段 \(key)")
        }
    }

    func testCanonicalStringLayout() {
        let canonical = RelayWire.canonicalString(
            deviceId: "dev-123", method: "POST", path: "/v1/voice/turns",
            requestId: "req-1", timestampMs: "1753920000000", nonce: "nonce-1", bodySha256: "abc"
        )
        XCTAssertEqual(
            canonical,
            "v1\ndev-123\nPOST\n/v1/voice/turns\nreq-1\n1753920000000\nnonce-1\nabc",
            "与 ESS-23 Bridge 验证过的签名串逐字段一致"
        )
    }

    func testSignatureIsDeterministicHMACOfDerivedKey() {
        let canonical = "v1\ndev-123\nPOST\n/v1/voice/turns\nreq-1\n1753920000000\nnonce-1\nabc"
        let signature = RelayWire.signatureHex(canonical: canonical, signingKey: credentials.signingKey)

        // 密钥派生 = SHA256(token)；用派生密钥独立重算必须一致。
        let derived = SymmetricKey(data: Data(SHA256.hash(data: Data("secret-token".utf8))))
        let expected = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: derived)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(signature, expected)
        XCTAssertEqual(signature.count, 64)
    }

    func testSignedRequestCarriesAllAuthHeaders() throws {
        let body = Data("{}".utf8)
        let request = RelaySignedRequestBuilder(
            baseURL: URL(string: "https://bridge.example:8443")!, credentials: credentials
        ).request(
            method: "POST", path: "/v1/voice/turns", requestId: "req-1", body: body,
            timestampMs: "1753920000000", nonce: "nonce-1"
        )

        XCTAssertEqual(request.url?.path, "/v1/voice/turns")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Id"), "dev-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Request-Id"), "req-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Request-Timestamp"), "1753920000000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Nonce"), "nonce-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Body-SHA256"), RelayWire.sha256Hex(body))

        let canonical = RelayWire.canonicalString(
            deviceId: "dev-123", method: "POST", path: "/v1/voice/turns",
            requestId: "req-1", timestampMs: "1753920000000", nonce: "nonce-1",
            bodySha256: RelayWire.sha256Hex(body)
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Signature"),
            RelayWire.signatureHex(canonical: canonical, signingKey: credentials.signingKey)
        )
    }

    func testRetryabilityClassification() {
        XCTAssertFalse(RelayUploadError.bridge(code: "ERR_SIGNATURE_INVALID", httpStatus: 401).isRetryable)
        XCTAssertFalse(RelayUploadError.bridge(code: "ERR_IDEMPOTENCY_CONFLICT", httpStatus: 409).isRetryable)
        XCTAssertTrue(RelayUploadError.bridge(code: "ERR_INTERNAL", httpStatus: 500).isRetryable)
        XCTAssertTrue(RelayUploadError.bridge(code: "ERR_RATE_LIMITED", httpStatus: 429).isRetryable)
        XCTAssertTrue(RelayUploadError.transport(URLError(.notConnectedToInternet)).isRetryable)
    }
}

final class VoiceRelayEventsTests: XCTestCase {
    func testStatusEventDecodesPhase() {
        let json = """
        {"request_id":"req-1","event":"status","status":"background_processing","occurred_at":"2026-07-30T09:00:00Z"}
        """
        let event = VoiceRelayEvent.decode(from: Data(json.utf8))
        XCTAssertEqual(event?.requestId, "req-1")
        XCTAssertEqual(event?.phase, .backgroundProcessing)
    }

    func testResultEventCarriesTextAndAudio() {
        let json = """
        {"request_id":"req-1","event":"result","status":"completed","text":"完成","audio_base64":"QUJD"}
        """
        let event = VoiceRelayEvent.decode(from: Data(json.utf8))
        XCTAssertEqual(event?.text, "完成")
        XCTAssertEqual(event?.audioBase64, "QUJD")
        XCTAssertEqual(event?.phase, .completed)
    }

    func testUnknownStatusAndFieldsAreTolerated() {
        let json = """
        {"request_id":"req-1","event":"status","status":"quantum_flux","future_field":42}
        """
        let event = VoiceRelayEvent.decode(from: Data(json.utf8))
        XCTAssertNotNil(event, "未知字段/未知状态不应导致解码失败")
        XCTAssertNil(event?.phase, "未知状态映射为 nil 由上层忽略")
        XCTAssertNil(VoiceRelayEvent.decode(from: Data("not-json".utf8)), "坏 JSON 返回 nil 不崩溃")
    }

    func testRelayStatusUpdateRoundTripUsesContractKeys() throws {
        let update = RelayStatusUpdate(
            requestId: "req-1", phase: .waitingForMac, detail: "已到手机，等待 Mac",
            updatedAt: Date(timeIntervalSince1970: 1_753_920_000)
        )
        let data = try update.jsonData()
        let json = String(data: data, encoding: .utf8)!
        for key in ["protocol_version", "request_id", "phase", "updated_at"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "缺少契约字段 \(key)")
        }
        XCTAssertTrue(json.contains("waiting_for_mac"), "phase 用 §6 状态机字符串")
        XCTAssertEqual(RelayStatusUpdate.decode(from: data), update)
    }

    func testLegacyRelayStatusStillDecodesWithoutFailureFields() throws {
        let data = Data(#"{"protocol_version":"1.0","request_id":"req-old","phase":"waiting_for_mac","updated_at":"2026-08-04T00:00:00Z"}"#.utf8)
        let update = try XCTUnwrap(RelayStatusUpdate.decode(from: data))
        XCTAssertNil(update.errorCode)
        XCTAssertNil(update.failureStage)
    }

    func testCodedFailureProjectsToJournalEnvelope() throws {
        let update = RelayStatusUpdate(
            requestId: "req-fail", phase: .failed, detail: "Mac 暂时无法连接",
            errorCode: "ERR_TRANSPORT", failureStage: .macUnreachable
        )
        let envelope = try XCTUnwrap(update.failedStatusEnvelope())
        XCTAssertEqual(envelope.state, .failed)
        XCTAssertEqual(envelope.errorCode, "ERR_TRANSPORT")
        XCTAssertEqual(envelope.failureStage, .macUnreachable)
        XCTAssertNil(RelayStatusUpdate(requestId: "req-ok", phase: .accepted).failedStatusEnvelope())
    }

    func testVoiceRelayResultPayloadRoundTrip() throws {
        let payload = VoiceRelayResultPayload(
            requestId: "req-1", text: "答案", audioSha256: String(repeating: "a", count: 64),
            completedAt: Date(timeIntervalSince1970: 1_753_920_000)
        )
        XCTAssertEqual(VoiceRelayResultPayload.decode(from: try payload.jsonData()), payload)
    }

    func testTerminalPhases() {
        XCTAssertTrue(VoiceRelayPhase.completed.isTerminal)
        XCTAssertTrue(VoiceRelayPhase.failed.isTerminal)
        XCTAssertTrue(VoiceRelayPhase.cancelled.isTerminal)
        XCTAssertFalse(VoiceRelayPhase.waitingForMac.isTerminal)
        XCTAssertFalse(VoiceRelayPhase.permissionRequired.isTerminal)
    }
}
