import XCTest
@testable import WristAgentCore

/// ESS-180：错误码 → 拟人化文案 + 语音片段的查表规则钉死。
/// 每个 Bridge 稳定 `ERR_*` 码都必须有可判定输出——未知/nil 走通用兜底
/// 而不是返回 nil，从 API 形状层杜绝「静音吞错」。
final class ErrorCueCatalogTests: XCTestCase {
    func testAudioTooShortHasBespokeCopyAndClip() {
        let entry = ErrorCueCatalog.cue(for: "ERR_AUDIO_TOO_SHORT")
        XCTAssertEqual(entry.code, "ERR_AUDIO_TOO_SHORT")
        XCTAssertTrue(entry.text.contains("多按一会儿"), "audio_too_short 提示按太短")
        XCTAssertEqual(entry.clip, "ErrorCue_AudioTooShort")
    }

    func testTranscriptDiscardedHintsClarity() {
        let entry = ErrorCueCatalog.cue(for: "ERR_TRANSCRIPT_DISCARDED")
        XCTAssertTrue(entry.text.contains("离麦"))
        XCTAssertEqual(entry.clip, "ErrorCue_TranscriptDiscarded")
    }

    func testVoiceBusyDefersUser() {
        let entry = ErrorCueCatalog.cue(for: "ERR_VOICE_BUSY")
        XCTAssertTrue(entry.text.contains("稍后再叫"))
        XCTAssertEqual(entry.clip, "ErrorCue_VoiceBusy")
    }

    func testAllRealtimeStallCodesShareSameClip() {
        for code in ["ERR_REALTIME_STALLED", "ERR_REALTIME_NO_EVENTS", "ERR_REALTIME_TIMEOUT"] {
            let entry = ErrorCueCatalog.cue(for: code)
            XCTAssertEqual(entry.clip, "ErrorCue_RealtimeStalled",
                           "\(code) 三个 realtime 停摆用户感知一致，共用一条语音")
            XCTAssertEqual(entry.code, code, "code 原样保留供日志追溯")
        }
    }

    func testUnknownCodeFallsBackToGenericButPreservesCode() {
        let entry = ErrorCueCatalog.cue(for: "ERR_SOMETHING_NEW")
        XCTAssertEqual(entry.code, "ERR_SOMETHING_NEW", "code 保留供日志追溯")
        XCTAssertEqual(entry.text, ErrorCueCatalog.generic.text)
        XCTAssertEqual(entry.clip, ErrorCueCatalog.generic.clip)
    }

    func testNilAndEmptyBothFallBackToGeneric() {
        XCTAssertEqual(ErrorCueCatalog.cue(for: nil), ErrorCueCatalog.generic)
        XCTAssertEqual(ErrorCueCatalog.cue(for: ""), ErrorCueCatalog.generic)
    }

    /// ESS-180 铁律：绝不允许 code → nil。所有已列的错误码 + 通用兜底都必须
    /// 至少给一条文案；语音片段可以缺席（fallback 到文字 + 触觉），但文字
    /// 从不缺席。
    func testEveryEntryHasNonEmptyText() {
        for code in [
            "ERR_AUDIO_TOO_SHORT", "ERR_TRANSCRIPT_DISCARDED", "ERR_VOICE_BUSY",
            "ERR_REALTIME_STALLED", "ERR_REALTIME_NO_EVENTS", "ERR_REALTIME_TIMEOUT",
            "ERR_WORK_TIMEOUT", "ERR_PROCESSING_FAILED", "ERR_UNKNOWN",
        ] {
            let entry = ErrorCueCatalog.cue(for: code)
            XCTAssertFalse(entry.text.isEmpty, "\(code) 文案不许空")
        }
        XCTAssertFalse(ErrorCueCatalog.generic.text.isEmpty)
    }

    func testAllClipNamesDedupesRealtimeStallVariants() {
        let names = ErrorCueCatalog.allClipNames
        // 5 张片：AudioTooShort / TranscriptDiscarded / VoiceBusy / RealtimeStalled / Generic
        XCTAssertEqual(Set(names).count, names.count, "文件名去重")
        XCTAssertTrue(names.contains("ErrorCue_Generic"))
        XCTAssertTrue(names.contains("ErrorCue_RealtimeStalled"))
        XCTAssertEqual(names.count, 5, "白梦林规格 3-5 条，实装 5 条")
    }
}
