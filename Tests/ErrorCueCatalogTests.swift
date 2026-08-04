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

    // MARK: - ESS-257 · D2 v1.1 四个 Bridge 终态码的文案与恢复族

    /// D2 E-18：Bridge upstream 不可达 + iPhone Relay 传输/回包异常同用一句文案。
    /// 三个 code 用户视角一致：Mac 没人应答，缓存可原样重发（族 B）。
    func testMacUnreachableCodesShareE18CopyAndAllowRetry() {
        for code in ["ERR_UPSTREAM_UNAVAILABLE", "ERR_TRANSPORT", "ERR_BAD_RESPONSE"] {
            let entry = ErrorCueCatalog.cue(for: code)
            XCTAssertEqual(entry.code, code, "code 原样保留供日志追溯")
            XCTAssertEqual(entry.text, "Mac 那边没应答。确认助手在运行，点重试不用重新说。",
                           "\(code) → D2 E-18 定型文案")
            XCTAssertEqual(entry.recoveryFamily, .retry, "\(code) 属族 B，缓存录音可重发")
            XCTAssertTrue(entry.recoveryFamily.allowsCachedRetry, "\(code) 必须允许重试按钮")
        }
    }

    /// D2 E-26：Mac 找不到这次任务（`gateway.mjs` / `taskwatch.mjs`）。
    func testTaskNotFoundShowsE26CopyAndAllowsRetry() {
        let entry = ErrorCueCatalog.cue(for: "ERR_TASK_NOT_FOUND")
        XCTAssertEqual(entry.text, "Mac 那边找不到这件事了，点重试我重新交一次。",
                       "D2 E-26 定型文案")
        XCTAssertEqual(entry.recoveryFamily, .retry)
        XCTAssertTrue(entry.recoveryFamily.allowsCachedRetry)
    }

    /// D2 E-11：Mac 侧任务落 failed 终态。
    func testTaskFailedShowsE11CopyAndAllowsRetry() {
        let entry = ErrorCueCatalog.cue(for: "ERR_TASK_FAILED")
        XCTAssertEqual(entry.text, "这件事我没办成，点重试再跑一次，不用重新说。",
                       "D2 E-11 定型文案")
        XCTAssertEqual(entry.recoveryFamily, .retry)
        XCTAssertTrue(entry.recoveryFamily.allowsCachedRetry)
    }

    /// D2 E-28（族 H）：Bridge 明确「不知道做完没有」。这是本 issue 的头号
    /// 铁律——**禁止重试按钮**，避免重复执行已生效的写操作。
    func testResultUnknownShowsE28CopyAndBlocksRetry() {
        let entry = ErrorCueCatalog.cue(for: "ERR_RESULT_UNKNOWN")
        XCTAssertEqual(entry.text,
                       "这件事做完没有我不确定，去 Mac 上看一眼——我不敢替你重跑。",
                       "D2 E-28 定型文案")
        XCTAssertEqual(entry.recoveryFamily, .manualConfirm, "族 H")
        XCTAssertFalse(entry.recoveryFamily.allowsCachedRetry,
                       "白梦林铁律：族 H 绝不给重试按钮，重复执行有副作用")
    }

    /// D2 E-99：未知/兜底走族 B（可重试），别把新码悄悄退化成「不给重试」。
    func testGenericFallbackAllowsRetry() {
        XCTAssertEqual(ErrorCueCatalog.generic.recoveryFamily, .retry,
                       "D2 E-99 = 族 B（不是 A）")
        XCTAssertTrue(ErrorCueCatalog.generic.recoveryFamily.allowsCachedRetry)
        // 未知 code 同样走 generic 族 B。
        let unknown = ErrorCueCatalog.cue(for: "ERR_SOMETHING_NEW")
        XCTAssertEqual(unknown.recoveryFamily, .retry)
    }

    /// 恢复族判定收在一处：`allowsCachedRetry` 只有族 H 返回 false。
    /// 视图不得再按 code 硬编码分支。
    func testAllowsCachedRetryTable() {
        XCTAssertTrue(RecoveryFamily.reRecord.allowsCachedRetry)
        XCTAssertTrue(RecoveryFamily.retry.allowsCachedRetry)
        XCTAssertTrue(RecoveryFamily.waitAndRetry.allowsCachedRetry)
        XCTAssertTrue(RecoveryFamily.authorize.allowsCachedRetry)
        XCTAssertTrue(RecoveryFamily.textOnly.allowsCachedRetry)
        XCTAssertTrue(RecoveryFamily.replay.allowsCachedRetry)
        XCTAssertTrue(RecoveryFamily.silent.allowsCachedRetry)
        XCTAssertFalse(RecoveryFamily.manualConfirm.allowsCachedRetry,
                       "族 H 是唯一禁止重试的族——ESS-257 白梦林拍板")
    }

    /// D2.3 禁用词：卡片文案里不允许把错误码原样拼进用户可见文本。
    /// 覆盖 ESS-257 新增的所有 code。
    func testNewCodesNeverExposeRawErrorCodeInText() {
        for code in [
            "ERR_UPSTREAM_UNAVAILABLE", "ERR_TRANSPORT", "ERR_BAD_RESPONSE",
            "ERR_TASK_NOT_FOUND", "ERR_TASK_FAILED", "ERR_RESULT_UNKNOWN",
        ] {
            let entry = ErrorCueCatalog.cue(for: code)
            XCTAssertFalse(entry.text.contains("ERR_"), "\(code) 卡片文案不得含裸码")
            XCTAssertFalse(entry.text.contains(code), "\(code) 卡片文案不得含裸码")
        }
    }
}
