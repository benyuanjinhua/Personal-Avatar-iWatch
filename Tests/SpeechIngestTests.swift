import XCTest
@testable import WristAgentCore

/// ESS-38 复测：Watch 侧语音入库强校验（信封 + sha256）。
/// 每个拒收分支都有稳定结论——真机日志必须能回答"停在哪一步、为什么"。
final class SpeechIngestTests: XCTestCase {
    private let requestId = "019fbbdd-5c39-70fa-9760-dc262ee092b0"
    private let audio = Data("fake-m4a-bytes".utf8)

    private func envelopeData(sha: String?) throws -> Data {
        let result = VoiceResultPayload(
            summary: "完成了。", isTruncated: false,
            speechSha256: sha, speechDurationMs: 800
        )
        return try VoiceStatusEnvelope
            .status(requestId: requestId, state: .completed, result: result)
            .jsonData()
    }

    func testAcceptsMatchingSha() throws {
        let sha = VoiceDigest.sha256Hex(of: audio)
        let outcome = SpeechIngest.validate(envelopeData: try envelopeData(sha: sha), audioData: audio)
        guard case .accepted(let envelope, let acceptedSha) = outcome else {
            return XCTFail("应当接受 sha 一致的语音，实际 \(outcome)")
        }
        XCTAssertEqual(envelope.requestId, requestId)
        XCTAssertEqual(acceptedSha, sha)
    }

    func testAcceptsUppercaseShaFromSender() throws {
        let sha = VoiceDigest.sha256Hex(of: audio).uppercased()
        let outcome = SpeechIngest.validate(envelopeData: try envelopeData(sha: sha), audioData: audio)
        guard case .accepted = outcome else {
            return XCTFail("sha 大小写不应影响校验，实际 \(outcome)")
        }
    }

    func testRejectsShaMismatch() throws {
        let outcome = SpeechIngest.validate(
            envelopeData: try envelopeData(sha: String(repeating: "ab", count: 32)),
            audioData: audio
        )
        guard case .shaMismatch(let expected, let actual) = outcome else {
            return XCTFail("sha 不一致必须拒收，实际 \(outcome)")
        }
        XCTAssertNotEqual(expected, actual)
    }

    func testRejectsMissingSha() throws {
        let outcome = SpeechIngest.validate(envelopeData: try envelopeData(sha: nil), audioData: audio)
        XCTAssertEqual(outcome, .envelopeInvalid(reason: "missing_speech_sha256"),
                       "没有校验值的语音一律拒收")
    }

    func testRejectsGarbageEnvelope() {
        let outcome = SpeechIngest.validate(envelopeData: Data("not-json".utf8), audioData: audio)
        XCTAssertEqual(outcome, .envelopeInvalid(reason: "envelope_decode_failed"))
    }
}
