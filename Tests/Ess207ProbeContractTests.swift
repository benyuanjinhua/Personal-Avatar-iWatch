import XCTest
@testable import WristAgentCore

/// ESS-207 契约：Shared/ 层新增的 kind=probe 与探针回执信封。
///
/// 这里覆盖 Package.swift 能吃到的所有部分——AudioDownlinkKind、
/// AudioDownlinkPolicy、VoiceProbeMessage/ProbeAckMessage key、
/// VoiceStatusEnvelope 编解码带 audio_kind=probe、WatchDownlinkOutbox 的
/// probe 入队通道。iOS/Watch 端的路由与播放分支放在 WatchTests / xcodebuild
/// 侧走真机 R-02.1，本文件只锁 wire contract。
final class Ess207ProbeContractTests: XCTestCase {
    // MARK: - AudioDownlinkKind + Policy

    func testProbeKindIsWireStable() {
        XCTAssertEqual(AudioDownlinkKind.probe.rawValue, "probe",
                       "wire 值必须是 'probe'，Bridge audio-policy.mjs AUDIO_KINDS 里就是这个字面量")
        XCTAssertTrue(AudioDownlinkKind.allCases.contains(.probe))
    }

    func testAudioDownlinkPolicyAllowsProbeWhenExpected() {
        XCTAssertTrue(AudioDownlinkPolicy.allows(.probe, expected: [.probe]))
        XCTAssertTrue(AudioDownlinkPolicy.allows(.probe, expected: [.probe, .result]))
        XCTAssertFalse(AudioDownlinkPolicy.allows(.probe, expected: [.result, .interim]),
                       "结果链路不应把 probe 当自家客——storeSpeech 就是靠这条把 probe 挡在外面")
        XCTAssertFalse(AudioDownlinkPolicy.allows(nil, expected: [.probe]))
    }

    // MARK: - Wire keys（跨端字符串必须稳定）

    func testProbeWireKeysAreStable() {
        // 与 Bridge server.mjs / iOS PhoneConnectivity / Watch WatchSettingsStore
        // 里的字面量对齐——改一处这里就必须同步改，测试挡住无意漂移。
        XCTAssertEqual(VoiceProbeMessage.envelopeKey, "voice_probe_envelope")
        XCTAssertEqual(ProbeAckMessage.envelopeKey, "probe_playback_ack")
    }

    // MARK: - VoiceStatusEnvelope 带 audio_kind=probe

    func testVoiceStatusEnvelopeRoundTripsAudioKindProbe() throws {
        let envelope = VoiceStatusEnvelope.status(
            requestId: "018f4c6e-0000-7000-8000-000000000207",
            state: .completed,
            occurredAt: Date(timeIntervalSince1970: 1_770_000_000),
            detail: "kind=probe",
            result: VoiceResultPayload(
                summary: "你好Jackson，我是你的数字分身",
                isTruncated: false,
                speechSha256: String(repeating: "a", count: 64),
                speechDurationMs: 3500
            ),
            audioKind: .probe
        )
        let data = try envelope.jsonData()
        // 键名对齐生产 wire（snake_case）。
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["audio_kind"] as? String, "probe")

        let decoded = try VoiceStatusEnvelope.decode(from: data)
        XCTAssertEqual(decoded.audioKind, .probe)
        XCTAssertEqual(decoded.state, .completed)
        XCTAssertEqual(decoded.requestId, envelope.requestId)
    }

    // MARK: - ProbeAckEnvelope

    func testProbeAckEnvelopeEncodesSnakeCaseWireFields() throws {
        let ack = ProbeAckEnvelope(
            requestId: "018f4c6e-0000-7000-8000-000000000207",
            playedOk: true,
            playedAtMs: 1_770_000_000_000,
            durationMs: 3500,
            sha256: String(repeating: "a", count: 64)
        )
        let data = try ack.jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["request_id"] as? String, ack.requestId)
        XCTAssertEqual(object["played_ok"] as? Bool, true)
        XCTAssertEqual(object["played_at_ms"] as? Int64, 1_770_000_000_000)
        XCTAssertEqual(object["duration_ms"] as? Int, 3500)
        XCTAssertEqual(object["sha256"] as? String, ack.sha256)
        // 成功路径不写 error_code；避免让 Bridge 侧解析器把 null 当有效错误码。
        XCTAssertNil(object["error_code"])
    }

    func testProbeAckEnvelopeCarriesErrorCodeOnFailure() throws {
        let ack = ProbeAckEnvelope(
            requestId: "018f4c6e-0000-7000-8000-000000000208",
            playedOk: false,
            playedAtMs: 1_770_000_000_500,
            durationMs: nil,
            sha256: String(repeating: "b", count: 64),
            errorCode: "ERR_PROBE_SHA_MISMATCH"
        )
        let data = try ack.jsonData()
        let decoded = try XCTUnwrap(ProbeAckEnvelope.decode(from: data))
        XCTAssertEqual(decoded.playedOk, false)
        XCTAssertEqual(decoded.errorCode, "ERR_PROBE_SHA_MISMATCH")
        XCTAssertNil(decoded.durationMs)
    }

    // MARK: - WatchDownlinkOutbox probe 通道

    func testEnqueueProbeStagesAudioAndIsIsolatedFromSpeechDedup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try WatchDownlinkOutbox(directory: directory)
        let envelope = try VoiceStatusEnvelope.status(
            requestId: "018f4c6e-0000-7000-8000-000000000209",
            state: .completed,
            audioKind: .probe
        ).jsonData()
        let audio = Data(repeating: 0xAB, count: 1024)

        let probeResult = try outbox.enqueueProbe(
            requestId: "018f4c6e-0000-7000-8000-000000000209",
            messageKey: VoiceProbeMessage.envelopeKey,
            envelope: envelope, audio: audio, fileName: "probe.m4a"
        )
        guard case .enqueued(let probeItem) = probeResult else {
            return XCTFail("探针应入队")
        }
        XCTAssertEqual(probeItem.kind, .probe, "kind 必须是 .probe，避免和 .speech 走同一份内存 dedup")
        XCTAssertEqual(probeItem.messageKey, VoiceProbeMessage.envelopeKey)
        let staged = try XCTUnwrap(outbox.stagedAudioURL(for: probeItem.id))
        XCTAssertEqual(try Data(contentsOf: staged), audio)

        // 同 request_id 同信封同音频但 kind=speech：不应被判为 probe 的重复。
        let speechEnv = try VoiceStatusEnvelope.status(
            requestId: "018f4c6e-0000-7000-8000-000000000209",
            state: .completed,
            audioKind: .result
        ).jsonData()
        let speechResult = try outbox.enqueueSpeech(
            requestId: "018f4c6e-0000-7000-8000-000000000209",
            messageKey: VoiceSpeechMessage.envelopeKey,
            envelope: speechEnv, audio: audio, fileName: "speech.m4a"
        )
        guard case .enqueued = speechResult else {
            return XCTFail("结果 speech 与 probe 语义独立，不得因 request_id 相同被判重复")
        }
        XCTAssertEqual(outbox.items.count, 2)
    }

    func testEnqueueProbeDedupesSameEnvelopeAndAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-dedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try WatchDownlinkOutbox(directory: directory)
        let envelope = try VoiceStatusEnvelope.status(
            requestId: "018f4c6e-0000-7000-8000-000000000210",
            state: .completed,
            audioKind: .probe
        ).jsonData()
        let audio = Data(repeating: 0xCD, count: 512)

        _ = try outbox.enqueueProbe(
            requestId: "018f4c6e-0000-7000-8000-000000000210",
            messageKey: VoiceProbeMessage.envelopeKey,
            envelope: envelope, audio: audio, fileName: "probe.m4a"
        )
        let replay = try outbox.enqueueProbe(
            requestId: "018f4c6e-0000-7000-8000-000000000210",
            messageKey: VoiceProbeMessage.envelopeKey,
            envelope: envelope, audio: audio, fileName: "probe.m4a"
        )
        guard case .duplicate = replay else {
            return XCTFail("同 request_id 同信封同音频的探针重放不应重复入队（Bridge sweep 补发会命中）")
        }
        XCTAssertEqual(outbox.items.count, 1)
    }
}
