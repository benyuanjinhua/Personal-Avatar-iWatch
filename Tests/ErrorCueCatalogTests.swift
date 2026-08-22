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

    /// ESS-538：录音中断截断走族 A（重说），文案与「按太短」明确区分，
    /// 且不允许出缓存重试按钮（残片已本地丢弃，无缓存可重发）。
    func testRecordingInterruptedIsReRecordFamilyWithoutCachedRetry() {
        let entry = ErrorCueCatalog.cue(for: "ERR_RECORDING_INTERRUPTED")
        XCTAssertEqual(entry.code, "ERR_RECORDING_INTERRUPTED")
        XCTAssertTrue(entry.text.contains("被打断"), "interrupted 要说明是录音被打断，不是按太短")
        XCTAssertEqual(entry.recoveryFamily, .reRecord)
        XCTAssertFalse(entry.recoveryFamily.allowsCachedRetry)
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

    func testResultAudioFailuresMapToD2E12E13E14() {
        XCTAssertEqual(
            ErrorCueCatalog.cue(for: "ERR_NO_SPEECH_FILE").text,
            "答案在，只是语音没留住——文字给你看。"
        )
        XCTAssertTrue(ErrorCueCatalog.cue(for: "ERR_PLAYBACK_ACTIVATION").text.contains("扬声器"))
        XCTAssertTrue(ErrorCueCatalog.cue(for: "ERR_PLAY_RETURNED_FALSE").text.contains("点重播"))
        XCTAssertNil(ErrorCueCatalog.cue(for: "ERR_PLAYBACK_DEFERRED_TIMEOUT").clip)
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
        // ESS-262：10 张片 = v1.0 五条（AudioTooShort / TranscriptDiscarded /
        // VoiceBusy / RealtimeStalled / Generic）+ D2 v1.1 五条（MicPermission /
        // Retryable / TextOnly / PhoneUnreachable / ManualConfirm）。
        XCTAssertEqual(Set(names).count, names.count, "文件名去重")
        XCTAssertTrue(names.contains("ErrorCue_Generic"))
        XCTAssertTrue(names.contains("ErrorCue_RealtimeStalled"))
        XCTAssertTrue(names.contains("ErrorCue_MicPermission"))
        XCTAssertTrue(names.contains("ErrorCue_Retryable"))
        XCTAssertTrue(names.contains("ErrorCue_TextOnly"))
        XCTAssertTrue(names.contains("ErrorCue_PhoneUnreachable"))
        XCTAssertTrue(names.contains("ErrorCue_ManualConfirm"))
        XCTAssertEqual(names.count, 10, "ESS-262：D2 v1.1 定稿 10 条")
    }

    // MARK: - ESS-257 · D2 v1.1 四个 Bridge 终态码的文案与恢复族

    /// D2 E-18：Bridge upstream 不可达 + iPhone Relay 传输/回包异常同用一句文案。
    /// 三个 code 用户视角一致：Mac 没人应答，缓存可原样重发（族 B）。
    /// ESS-262：clip 落 `ErrorCue_Retryable`，与 E-10/E-11/E-26 共用一条语音。
    func testMacUnreachableCodesShareE18CopyAndAllowRetry() {
        for code in ["ERR_UPSTREAM_UNAVAILABLE", "ERR_TRANSPORT", "ERR_BAD_RESPONSE"] {
            let entry = ErrorCueCatalog.cue(for: code)
            XCTAssertEqual(entry.code, code, "code 原样保留供日志追溯")
            XCTAssertEqual(entry.text, "Mac 那边没应答。确认助手在运行，点重试不用重新说。",
                           "\(code) → D2 E-18 定型文案")
            XCTAssertEqual(entry.recoveryFamily, .retry, "\(code) 属族 B，缓存录音可重发")
            XCTAssertTrue(entry.recoveryFamily.allowsCachedRetry, "\(code) 必须允许重试按钮")
            XCTAssertEqual(entry.clip, "ErrorCue_Retryable",
                           "\(code) 属族 B，共用 ErrorCue_Retryable 语音资产")
        }
    }

    /// ESS-983：全文件降级路径确定性不可用（HMAC 密钥缺失 / fallback 关闭）。
    /// 族 C（稍后再叫）：不出「重试」按钮，避免白等——重试必然再次失败。
    func testFallbackNotConfiguredDoesNotAllowCachedRetry() {
        let entry = ErrorCueCatalog.cue(for: "ERR_FALLBACK_NOT_CONFIGURED")
        XCTAssertEqual(entry.code, "ERR_FALLBACK_NOT_CONFIGURED", "code 原样保留供日志追溯")
        XCTAssertTrue(entry.text.contains("稍后再试"), "确定性配置失败应提示稍后再试")
        XCTAssertEqual(entry.recoveryFamily, .waitAndRetry, "ESS-983 族 C")
        XCTAssertFalse(entry.recoveryFamily.allowsCachedRetry, "确定性失败不得出重试按钮")
        XCTAssertNil(entry.clip, "无预置语音，走文字 + 触觉")
    }

    /// D2 E-26：Mac 找不到这次任务（`gateway.mjs` / `taskwatch.mjs`）。
    /// ESS-262：clip 落 `ErrorCue_Retryable`。
    func testTaskNotFoundShowsE26CopyAndAllowsRetry() {
        let entry = ErrorCueCatalog.cue(for: "ERR_TASK_NOT_FOUND")
        XCTAssertEqual(entry.text, "Mac 那边找不到这件事了，点重试我重新交一次。",
                       "D2 E-26 定型文案")
        XCTAssertEqual(entry.recoveryFamily, .retry)
        XCTAssertTrue(entry.recoveryFamily.allowsCachedRetry)
        XCTAssertEqual(entry.clip, "ErrorCue_Retryable")
    }

    /// D2 E-11：Mac 侧任务落 failed 终态。
    /// ESS-262：`ERR_TASK_FAILED` / `ERR_PROCESSING_FAILED` / `ERR_INTERNAL`
    /// 共族共资产，clip 落 `ErrorCue_Retryable`。
    func testTaskFailedShowsE11CopyAndAllowsRetry() {
        for code in ["ERR_TASK_FAILED", "ERR_PROCESSING_FAILED", "ERR_INTERNAL"] {
            let entry = ErrorCueCatalog.cue(for: code)
            XCTAssertEqual(entry.text, "这件事我没办成，点重试再跑一次，不用重新说。",
                           "\(code) → D2 E-11 定型文案")
            XCTAssertEqual(entry.recoveryFamily, .retry)
            XCTAssertTrue(entry.recoveryFamily.allowsCachedRetry)
            XCTAssertEqual(entry.clip, "ErrorCue_Retryable",
                           "\(code) 与 E-18/E-26 共用 ErrorCue_Retryable 语音资产")
        }
    }

    /// D2 E-28（族 H）：Bridge 明确「不知道做完没有」。这是本 issue 的头号
    /// 铁律——**禁止重试按钮**，避免重复执行已生效的写操作。
    /// ESS-262：clip 落 `ErrorCue_ManualConfirm`。
    func testResultUnknownShowsE28CopyAndBlocksRetry() {
        let entry = ErrorCueCatalog.cue(for: "ERR_RESULT_UNKNOWN")
        XCTAssertEqual(entry.text,
                       "这件事做完没有我不确定，去 Mac 上看一眼——我不敢替你重跑。",
                       "D2 E-28 定型文案")
        XCTAssertEqual(entry.recoveryFamily, .manualConfirm, "族 H")
        XCTAssertFalse(entry.recoveryFamily.allowsCachedRetry,
                       "白梦林铁律：族 H 绝不给重试按钮，重复执行有副作用")
        XCTAssertEqual(entry.clip, "ErrorCue_ManualConfirm")
    }

    // MARK: - ESS-262 · D2 v1.1 新增五条语气语音的查表规则

    /// D2 E-04（族 D）：麦克风权限缺失。
    /// 恢复动作是「怎么开」（去手表设置），重录/重试都会被系统再次拦下。
    func testMicPermissionShowsE04CopyAndAuthorizeFamily() {
        let entry = ErrorCueCatalog.cue(for: "ERR_MIC_PERMISSION")
        XCTAssertTrue(entry.text.contains("麦克风权限"))
        XCTAssertTrue(entry.text.contains("设置"))
        XCTAssertEqual(entry.recoveryFamily, .authorize, "族 D")
        XCTAssertFalse(entry.recoveryFamily.allowsCachedRetry,
                       "族 D：权限缺失，重录/重试都会被系统再拦")
        XCTAssertEqual(entry.clip, "ErrorCue_MicPermission")
    }

    /// D2 E-10（族 B）：Bridge 侧 work timeout 属可重试链路错。
    func testWorkTimeoutShowsE10CopyAndAllowsRetry() {
        let entry = ErrorCueCatalog.cue(for: "ERR_WORK_TIMEOUT")
        XCTAssertEqual(entry.text, "这件事我跑太久也没跑完，点一下重试，不用重新说。",
                       "D2 E-10 定型文案")
        XCTAssertEqual(entry.recoveryFamily, .retry)
        XCTAssertTrue(entry.recoveryFamily.allowsCachedRetry)
        XCTAssertEqual(entry.clip, "ErrorCue_Retryable",
                       "E-10 与 E-11/E-18/E-26 共用 ErrorCue_Retryable")
    }

    /// D2 E-12（族 E）：语音丢了 / 存不下 / 加载不出，但文字答案在。
    /// 三个 code 共用「看文字」恢复动作与 `ErrorCue_TextOnly` 语音资产。
    func testTextOnlyCodesShareE12CopyAndTextOnlyFamily() {
        for code in ["ERR_NO_SPEECH_FILE", "ERR_VAULT_LOAD", "ERR_VAULT_STORE"] {
            let entry = ErrorCueCatalog.cue(for: code)
            XCTAssertEqual(entry.text, "答案在，只是语音没留住——文字给你看。",
                           "\(code) → D2 E-12 定型文案")
            XCTAssertEqual(entry.recoveryFamily, .textOnly, "\(code) 属族 E")
            XCTAssertFalse(entry.recoveryFamily.allowsCachedRetry,
                           "族 E：动作是「看文字」不是重试")
            XCTAssertEqual(entry.clip, "ErrorCue_TextOnly")
        }
    }

    /// D2 E-17（族 B）：手机不可达。缓存录音自动重发，卡片语音强调「连上会重发」。
    func testPhoneUnreachableShowsE17CopyAndAllowsRetry() {
        let entry = ErrorCueCatalog.cue(for: "ERR_WC_NOT_ACTIVATED")
        XCTAssertEqual(entry.text, "手机没连上。录音我存着了，连上会自动重发。",
                       "D2 E-17 定型文案")
        XCTAssertEqual(entry.recoveryFamily, .retry, "族 B：缓存重发")
        XCTAssertTrue(entry.recoveryFamily.allowsCachedRetry)
        XCTAssertEqual(entry.clip, "ErrorCue_PhoneUnreachable")
    }

    /// D2 v1.1 E-99：未知/兜底走族 B（可重试），文案先劝重试、再退到重说，
    /// 与按钮语义一致（ESS-261）。别把新码悄悄退化成「不给重试」。
    func testGenericFallbackAllowsRetry() {
        XCTAssertEqual(ErrorCueCatalog.generic.recoveryFamily, .retry,
                       "D2 E-99 = 族 B（不是 A）")
        XCTAssertTrue(ErrorCueCatalog.generic.recoveryFamily.allowsCachedRetry)
        XCTAssertEqual(ErrorCueCatalog.generic.text,
                       "刚才这件事没成，点重试再来一次；还不行就再说一遍。",
                       "D2 v1.1 E-99 定稿文案——文案与「重试」按钮语义一致")
        // 未知 code 同样走 generic 族 B。
        let unknown = ErrorCueCatalog.cue(for: "ERR_SOMETHING_NEW")
        XCTAssertEqual(unknown.recoveryFamily, .retry)
        XCTAssertEqual(unknown.text, ErrorCueCatalog.generic.text)
    }

    /// 恢复族判定收在一处：`allowsCachedRetry` 只有族 B 返回 true。
    /// 视图不得再按 code 硬编码分支。ESS-261 把 A/C 及 D/E/F/G 一并对齐——
    /// 「重试（不用重新说）」只应对族 B（缓存录音原样重发），其他族的动作
    /// 各自不同（知道了/怎么开/看文字/重播），不能共用重试按钮。
    func testAllowsCachedRetryTable() {
        XCTAssertFalse(RecoveryFamily.reRecord.allowsCachedRetry,
                       "族 A：录音本身有问题，重发缓存只会再失败")
        XCTAssertTrue(RecoveryFamily.retry.allowsCachedRetry,
                      "族 B 是唯一允许「重试（不用重新说）」的族")
        XCTAssertFalse(RecoveryFamily.waitAndRetry.allowsCachedRetry,
                       "族 C：对端忙，立刻重试无意义")
        XCTAssertFalse(RecoveryFamily.authorize.allowsCachedRetry,
                       "族 D：权限缺失，重试仍会被拦")
        XCTAssertFalse(RecoveryFamily.textOnly.allowsCachedRetry,
                       "族 E：动作是「看文字」不是重试")
        XCTAssertFalse(RecoveryFamily.replay.allowsCachedRetry,
                       "族 F：动作是「重播」不是重试")
        XCTAssertFalse(RecoveryFamily.silent.allowsCachedRetry,
                       "族 G：不上卡片，按钮语义不适用")
        XCTAssertFalse(RecoveryFamily.manualConfirm.allowsCachedRetry,
                       "族 H：结果未知，重跑有重复副作用——ESS-257 白梦林拍板")
    }

    /// ESS-261 缺口二：族 A / C 的具体码不再露出「重试（不用重新说）」按钮。
    /// D2.0 原则 3 —— 恢复动作必须与错误成因匹配。
    func testFamilyAAndCCodesDoNotAllowCachedRetry() {
        // 族 A：录音本身有问题
        for code in [
            "ERR_AUDIO_TOO_SHORT",
            "ERR_TRANSCRIPT_DISCARDED",
            "ERR_REALTIME_STALLED",
            "ERR_REALTIME_NO_EVENTS",
            "ERR_REALTIME_TIMEOUT",
            "ERR_RECORDING_INTERRUPTED",
        ] {
            let entry = ErrorCueCatalog.cue(for: code)
            XCTAssertEqual(entry.recoveryFamily, .reRecord, "\(code) → 族 A")
            XCTAssertFalse(entry.recoveryFamily.allowsCachedRetry,
                           "\(code) 属族 A，不得出重试按钮")
        }
        // 族 C：对端忙
        let voiceBusy = ErrorCueCatalog.cue(for: "ERR_VOICE_BUSY")
        XCTAssertEqual(voiceBusy.recoveryFamily, .waitAndRetry, "族 C")
        XCTAssertFalse(voiceBusy.recoveryFamily.allowsCachedRetry,
                       "ERR_VOICE_BUSY 属族 C，不得出重试按钮")
    }

    /// D2.3 禁用词：卡片文案里不允许把错误码原样拼进用户可见文本。
    /// 覆盖 ESS-257 & ESS-262 新增的所有 code。
    func testNewCodesNeverExposeRawErrorCodeInText() {
        for code in [
            "ERR_UPSTREAM_UNAVAILABLE", "ERR_TRANSPORT", "ERR_BAD_RESPONSE",
            "ERR_TASK_NOT_FOUND", "ERR_TASK_FAILED", "ERR_RESULT_UNKNOWN",
            "ERR_MIC_PERMISSION", "ERR_WORK_TIMEOUT",
            "ERR_NO_SPEECH_FILE", "ERR_VAULT_LOAD", "ERR_VAULT_STORE",
            "ERR_WC_NOT_ACTIVATED",
            "ERR_PROCESSING_FAILED", "ERR_INTERNAL",
            "ERR_FALLBACK_NOT_CONFIGURED",
        ] {
            let entry = ErrorCueCatalog.cue(for: code)
            XCTAssertFalse(entry.text.contains("ERR_"), "\(code) 卡片文案不得含裸码")
            XCTAssertFalse(entry.text.contains(code), "\(code) 卡片文案不得含裸码")
        }
    }
}
