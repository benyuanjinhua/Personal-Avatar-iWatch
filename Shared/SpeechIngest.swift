import Foundation

/// 结果语音入库校验（ESS-38 复测取证）：WCSession transferFile 落地后、
/// 加密入库前的强校验。纯逻辑、可单测，每个拒收分支都有稳定的可记录结论
/// ——真机排查时日志必须能回答"停在哪一步、为什么"。
enum SpeechIngestOutcome: Equatable {
    case accepted(envelope: VoiceStatusEnvelope, sha256: String)
    /// 信封解码失败 / 结构校验不过 / 缺少 speechSha256。
    case envelopeInvalid(reason: String)
    /// 音频字节与信封声明的 sha256 不一致：数据不可信，整体拒收。
    case shaMismatch(expected: String, actual: String)
}

enum SpeechIngest {
    /// 语音 transferFile 的信封必须携带 speechSha256——没有校验值的音频
    /// 一律拒收（宁缺毋滥，文本结果不受影响）。
    static func validate(envelopeData: Data, audioData: Data) -> SpeechIngestOutcome {
        guard let envelope = try? VoiceStatusEnvelope.decode(from: envelopeData) else {
            return .envelopeInvalid(reason: "envelope_decode_failed")
        }
        if let reason = envelope.validate() {
            return .envelopeInvalid(reason: reason)
        }
        guard let expected = envelope.result?.speechSha256?.lowercased(), !expected.isEmpty else {
            return .envelopeInvalid(reason: "missing_speech_sha256")
        }
        let actual = VoiceDigest.sha256Hex(of: audioData)
        guard actual == expected else {
            return .shaMismatch(expected: expected, actual: actual)
        }
        return .accepted(envelope: envelope, sha256: actual)
    }
}
