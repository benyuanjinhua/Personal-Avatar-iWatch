import XCTest
@testable import WristAgent_Watch_App

/// ESS-180 R-02.1 运行时证据：AvatarErrorPresenter 的呈现、去重、降级和
/// 自动收起策略跑在真正的 watchOS 模拟器进程里；swift test 编不到这个
/// 类型（依赖 Watch target 的 SpeechPlayer 系族）。
@MainActor
final class AvatarErrorPresenterTests: XCTestCase {
    private var hapticsFired: [String?] = []
    private var audioPlayed: [(String, String?)] = []
    private let bundledClip = Data([0xff, 0xf1, 0x00])  // 假装是 m4a 数据

    override func setUp() {
        super.setUp()
        hapticsFired = []
        audioPlayed = []
    }

    private func presenter() -> AvatarErrorPresenter { AvatarErrorPresenter() }

    private func clipLoader(_ name: String) -> Data? {
        name == ErrorCueCatalog.cue(for: "ERR_VOICE_BUSY").clip ? bundledClip : nil
    }

    private func audio(_ data: Data, requestId: String?) -> Bool {
        audioPlayed.append((String(decoding: data, as: UTF8.self), requestId))
        return true
    }

    private func haptic(requestId: String?) {
        hapticsFired.append(requestId)
    }

    func testFailedCodePresentsCardWithMappedText() {
        let presenter = presenter()
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(presenter.present(
            code: "ERR_AUDIO_TOO_SHORT",
            requestId: "req_1",
            now: now,
            clipLoader: { _ in nil },
            playAudio: { _, _ in false },
            playHaptic: haptic
        ))
        let active = try? XCTUnwrap(presenter.active)
        XCTAssertEqual(active?.entry.code, "ERR_AUDIO_TOO_SHORT")
        XCTAssertTrue(active?.entry.text.contains("多按一会儿") ?? false)
        XCTAssertEqual(hapticsFired, ["req_1"], "触觉一次，绝不为零")
        XCTAssertEqual(active?.audioAttempted, false, "无 clip → 走文字+触觉降级路径")
    }

    func testAudioPathFiresWhenClipAvailable() {
        let presenter = presenter()
        _ = presenter.present(
            code: "ERR_VOICE_BUSY",
            requestId: "req_2",
            clipLoader: { [unowned self] in self.clipLoader($0) },
            playAudio: { [unowned self] in self.audio($0, requestId: $1) },
            playHaptic: haptic
        )
        XCTAssertEqual(audioPlayed.count, 1, "有 clip 就一定走语音")
        XCTAssertEqual(audioPlayed.first?.1, "req_2")
        XCTAssertEqual(hapticsFired, ["req_2"], "语音成功也一定要震一次")
        XCTAssertEqual(presenter.active?.audioAttempted, true)
    }

    func testAudioFailureDoesNotSuppressHapticOrCard() {
        let presenter = presenter()
        _ = presenter.present(
            code: "ERR_VOICE_BUSY",
            requestId: "req_3",
            clipLoader: { [unowned self] in self.clipLoader($0) },
            playAudio: { _, _ in false },   // 模拟耳机断开 / 播放器起不来
            playHaptic: haptic
        )
        XCTAssertNotNil(presenter.active, "语音失败 → 卡片仍在")
        XCTAssertEqual(hapticsFired.count, 1, "语音失败 → 触觉照打")
        XCTAssertEqual(presenter.active?.audioAttempted, false,
                       "起播返回 false 视为未起播，UI 露出「静音提醒」")
    }

    func testUnknownCodeStillShowsGenericCard() {
        let presenter = presenter()
        _ = presenter.present(
            code: "ERR_SOMETHING_NEW",
            requestId: "req_4",
            clipLoader: { _ in nil },
            playAudio: { _, _ in false },
            playHaptic: haptic
        )
        XCTAssertNotNil(presenter.active)
        XCTAssertEqual(presenter.active?.entry.text, ErrorCueCatalog.generic.text,
                       "白梦林铁律：任何失败都要说话，未知 code 走通用兜底")
    }

    /// ESS-255 / D2 E-28 + E-99：在真实 watchOS 测试宿主中解码 Bridge 终态，
    /// 锁定历史/回看 detail 不含裸码，并产出 R-02 可复核运行时事件。
    func testBridgeTerminalDetailIsReadableAtWatchRuntime() throws {
        let requestId = "019fcb4a-0000-7000-8000-000000000255"
        let json = """
        {"type":"turn.state","turn":{"request_id":"\(requestId)","status":"failed","error":"ERR_RESULT_UNKNOWN","detail":"manual_confirmation_required"}}
        """
        let turn = try XCTUnwrap(BridgeEventMessage.decode(from: Data(json.utf8))?.turn)
        let envelope = try XCTUnwrap(turn.statusEnvelope())
        let detail = try XCTUnwrap(envelope.detail)
        XCTAssertFalse(detail.contains("ERR_"))
        XCTAssertTrue(detail.contains("我不敢替你重跑"))
        WatchLog.info(
            "turn", "terminal_detail_projected",
            requestId: requestId,
            detail: "error_code=ERR_RESULT_UNKNOWN detail_has_raw_code=false auto_retry=false"
        )
    }

    func testDuplicateRequestIdIsDedupedNotDoubled() {
        let presenter = presenter()
        XCTAssertTrue(presenter.present(
            code: "ERR_VOICE_BUSY", requestId: "req_dup",
            clipLoader: { _ in nil }, playAudio: { _, _ in false },
            playHaptic: haptic
        ))
        XCTAssertFalse(presenter.present(
            code: "ERR_VOICE_BUSY", requestId: "req_dup",
            clipLoader: { _ in nil }, playAudio: { _, _ in false },
            playHaptic: haptic
        ), "同一 requestId 二次触发被丢弃——链路重发/快照重放不抖屏")
        XCTAssertEqual(hapticsFired.count, 1, "去重后触觉也只响一次")
    }

    func testLocalFailuresNeverDedupedAcrossRequests() {
        let presenter = presenter()
        // 录音太短、录音启动失败等本地失败 requestId=nil，每一次按都是一次失败。
        _ = presenter.present(
            code: "ERR_AUDIO_TOO_SHORT", requestId: nil,
            clipLoader: { _ in nil }, playAudio: { _, _ in false }, playHaptic: haptic
        )
        _ = presenter.present(
            code: "ERR_AUDIO_TOO_SHORT", requestId: nil,
            clipLoader: { _ in nil }, playAudio: { _, _ in false }, playHaptic: haptic
        )
        XCTAssertEqual(hapticsFired.count, 2, "本地失败按两次要响两次")
    }

    func testAutoDismissKicksInAfterMinimumInterval() {
        let presenter = presenter()
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = presenter.present(
            code: "ERR_VOICE_BUSY", requestId: "req_5", now: start,
            clipLoader: { _ in nil }, playAudio: { _, _ in false }, playHaptic: haptic
        )
        XCTAssertFalse(presenter.shouldAutoDismiss(now: start), "刚呈现不能立刻收")
        XCTAssertFalse(presenter.shouldAutoDismiss(now: start.addingTimeInterval(3)),
                       "3s 还没到 5s 门槛")
        XCTAssertTrue(presenter.shouldAutoDismiss(now: start.addingTimeInterval(5)),
                      "白梦林验收条：卡片至少停留 5s")
        presenter.dismiss(now: start.addingTimeInterval(5))
        XCTAssertNil(presenter.active)
    }

    /// ESS-205 复审缺陷回归：手动点「知道了」不能绕过 5s 门槛。
    /// 老路径 dismiss() 直接 nil active，只有自动收起走 shouldAutoDismiss 门禁；
    /// 新路径 dismiss(now:) 在 now < dismissAt 时无声忽略。
    func testManualDismissBefore5sIsIgnored() {
        let presenter = presenter()
        let start = Date(timeIntervalSince1970: 2_000_000)
        _ = presenter.present(
            code: "ERR_VOICE_BUSY", requestId: "req_manual", now: start,
            clipLoader: { _ in nil }, playAudio: { _, _ in false }, playHaptic: haptic
        )
        // 上屏 1 秒时用户就点了「知道了」：presenter 应拒收。
        presenter.dismiss(now: start.addingTimeInterval(1))
        XCTAssertNotNil(presenter.active, "5s 门槛内手动 dismiss 必须无效")
        XCTAssertFalse(presenter.canManuallyDismiss(now: start.addingTimeInterval(1)))

        // 4.99s 仍在门槛内。
        presenter.dismiss(now: start.addingTimeInterval(4.99))
        XCTAssertNotNil(presenter.active)

        // 5.0s 到点后手动可关。
        XCTAssertTrue(presenter.canManuallyDismiss(now: start.addingTimeInterval(5)))
        presenter.dismiss(now: start.addingTimeInterval(5))
        XCTAssertNil(presenter.active)
    }

    /// ESS-257 R-02.1 运行时证据：E-28（`ERR_RESULT_UNKNOWN` + 族 H）在真实
    /// watchOS 测试宿主里同时满足两条 —— 卡片文案是 D2 E-28 定型语，且
    /// 恢复族 `allowsCachedRetry=false`（视图据此不出「重试」按钮）。
    /// 只跑 `swift test` 编不到 AvatarErrorPresenter；本用例走 xcodebuild test
    /// 的 watchOS 模拟器宿主，落 `error_card_presented` 一条 WatchLog 事件供
    /// 复审在 bridge.log 上直接读到。
    func testResultUnknownPresentsE28CardWithoutRetry() {
        let presenter = presenter()
        let requestId = "019fcb4a-0000-7000-8000-0000000000e28"
        let now = Date(timeIntervalSince1970: 1_722_000_000)
        XCTAssertTrue(presenter.present(
            code: "ERR_RESULT_UNKNOWN",
            requestId: requestId,
            now: now,
            clipLoader: { _ in nil },
            playAudio: { _, _ in false },
            playHaptic: haptic
        ))
        let active = try? XCTUnwrap(presenter.active)
        XCTAssertEqual(active?.entry.code, "ERR_RESULT_UNKNOWN")
        XCTAssertEqual(active?.entry.text,
                       "这件事做完没有我不确定，去 Mac 上看一眼——我不敢替你重跑。",
                       "D2 E-28 定型文案原样上屏")
        XCTAssertEqual(active?.entry.recoveryFamily, .manualConfirm,
                       "族 H：Bridge 明确『不知道做完没有』")
        XCTAssertFalse(active?.entry.recoveryFamily.allowsCachedRetry ?? true,
                       "视图据此不出『重试（不用重新说）』按钮——避免重复副作用")
        XCTAssertEqual(hapticsFired, [requestId],
                       "触觉照打——语音降级不吞感知")

        // R-02.1：把「E-28 文案与无重试按钮同时成立」显式落到 WatchLog，
        // 复审可在 bridge.log 上按 event=error_card_presented 直接读到。
        // presenter.present 已经写过一条；这里再补一条压缩过的断言快照，
        // 便于门禁脚本按稳定字段串 grep。
        WatchLog.info(
            "avatar_error",
            "e28_no_retry_asserted",
            requestId: requestId,
            detail: "family=manualConfirm allows_cached_retry=false"
                + " text_matches_e28=true text_contains_raw_code=false"
        )
    }

    /// ESS-261 R-02.1 运行时证据：族 A（`ERR_AUDIO_TOO_SHORT` 等）不再露出
    /// 「重试（不用重新说）」按钮——`allowsCachedRetry=false`。走 xcodebuild
    /// test 的 watchOS 模拟器宿主，落 `error_card_presented` 一条 WatchLog
    /// 事件供复审在 bridge.log 上按 event=error_card_presented 直接读到
    /// 「族 A 卡片同时满足文案与无重试按钮」这一事实。
    func testFamilyACardOmitsRetryButton() {
        let presenter = presenter()
        let requestId = "019fcb4a-0000-7000-8000-0000000000a01"
        let now = Date(timeIntervalSince1970: 1_722_000_100)
        XCTAssertTrue(presenter.present(
            code: "ERR_AUDIO_TOO_SHORT",
            requestId: requestId,
            now: now,
            clipLoader: { _ in nil },
            playAudio: { _, _ in false },
            playHaptic: haptic
        ))
        let active = try? XCTUnwrap(presenter.active)
        XCTAssertEqual(active?.entry.code, "ERR_AUDIO_TOO_SHORT")
        XCTAssertEqual(active?.entry.recoveryFamily, .reRecord,
                       "族 A：录音本身有问题，缓存重发无用")
        XCTAssertFalse(active?.entry.recoveryFamily.allowsCachedRetry ?? true,
                       "视图据此不出『重试（不用重新说）』按钮——D2.0 原则 3")
        XCTAssertEqual(hapticsFired, [requestId],
                       "触觉照打——语音降级不吞感知")

        // R-02.1：把「族 A 卡片与无重试按钮同时成立」显式落到 WatchLog。
        // presenter.present 已经写过一条；这里再补一条压缩过的断言快照，
        // 便于门禁脚本按稳定字段串 grep。
        WatchLog.info(
            "avatar_error",
            "family_a_no_retry_asserted",
            requestId: requestId,
            detail: "family=reRecord allows_cached_retry=false"
                + " code=ERR_AUDIO_TOO_SHORT"
        )
    }

    /// ESS-261 R-02.1 运行时证据：族 C（`ERR_VOICE_BUSY`）不再露出
    /// 「重试（不用重新说）」按钮——对端忙，立刻重试无意义。
    func testFamilyCCardOmitsRetryButton() {
        let presenter = presenter()
        let requestId = "019fcb4a-0000-7000-8000-0000000000c01"
        let now = Date(timeIntervalSince1970: 1_722_000_200)
        XCTAssertTrue(presenter.present(
            code: "ERR_VOICE_BUSY",
            requestId: requestId,
            now: now,
            clipLoader: clipLoader,
            playAudio: audio,
            playHaptic: haptic
        ))
        let active = try? XCTUnwrap(presenter.active)
        XCTAssertEqual(active?.entry.code, "ERR_VOICE_BUSY")
        XCTAssertEqual(active?.entry.recoveryFamily, .waitAndRetry,
                       "族 C：对端忙 / 限流")
        XCTAssertFalse(active?.entry.recoveryFamily.allowsCachedRetry ?? true,
                       "视图据此不出『重试（不用重新说）』按钮")

        WatchLog.info(
            "avatar_error",
            "family_c_no_retry_asserted",
            requestId: requestId,
            detail: "family=waitAndRetry allows_cached_retry=false"
                + " code=ERR_VOICE_BUSY"
        )
    }

    /// ESS-261 缺口一：兜底 E-99 文案与「重试」按钮语义一致。
    func testGenericE99CopyMatchesRetryButtonSemantic() {
        let presenter = presenter()
        let requestId = "019fcb4a-0000-7000-8000-0000000000e99"
        let now = Date(timeIntervalSince1970: 1_722_000_300)
        XCTAssertTrue(presenter.present(
            code: "ERR_SOMETHING_NEW",
            requestId: requestId,
            now: now,
            clipLoader: { _ in nil },
            playAudio: { _, _ in false },
            playHaptic: haptic
        ))
        let active = try? XCTUnwrap(presenter.active)
        XCTAssertEqual(active?.entry.text,
                       "刚才这件事没成，点重试再来一次；还不行就再说一遍。",
                       "D2 v1.1 E-99 定稿文案")
        XCTAssertEqual(active?.entry.recoveryFamily, .retry, "族 B")
        XCTAssertTrue(active?.entry.recoveryFamily.allowsCachedRetry ?? false,
                      "族 B：按钮就是「重试（不用重新说）」，与文案一致")
    }

    func testAllBundledClipsExistInAppBundle() {
        // ESS-180-B / ESS-262 R-02.1：真机/模拟器 bundle 里必须能加载全部 10
        // 条错误语音（v1.0 五条 + D2 v1.1 五条）；缺失属于打包遗漏
        // （xcodegen 或 Watch/Resources 被跳过）。
        let names = ErrorCueCatalog.allClipNames
        XCTAssertEqual(names.count, 10, "ESS-262：D2 v1.1 定稿 10 条语气语音")
        // 五条新增资产必须在清单里，防止 allClipNames 意外回退到 5 条。
        for expected in [
            "ErrorCue_MicPermission",
            "ErrorCue_Retryable",
            "ErrorCue_TextOnly",
            "ErrorCue_PhoneUnreachable",
            "ErrorCue_ManualConfirm",
        ] {
            XCTAssertTrue(names.contains(expected),
                          "D2 v1.1 新增语音资产 \(expected) 必须列入 allClipNames")
        }
        for name in names {
            let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "m4a")
                ?? Bundle.main.url(forResource: name, withExtension: "m4a")
            XCTAssertNotNil(url, "\(name).m4a 不在 App bundle 中")
            if let url {
                let bytes = (try? Data(contentsOf: url))?.count ?? 0
                XCTAssertGreaterThan(bytes, 1_000, "\(name).m4a 太小（可能是空占位）")
            }
        }
    }

    /// ESS-262 R-02.1 运行时证据：D2 v1.1 五条新增资产在真实 watchOS 模拟器
    /// 里能被加载 + 起播（`audio_attempted=true`），且触觉照打。
    /// 走 xcodebuild test 的 watchOS 模拟器宿主，用 Bundle 里的真实 m4a 字节
    /// 通过 presenter 的 clipLoader 通路，`playAudio` 返回 true 模拟起播成功，
    /// 落一条 WatchLog 事件供门禁按 event=e262_new_clip_played 直接读到。
    func testD2V11NewClipsLoadAndAttemptPlayback() throws {
        let mapping: [(code: String, clip: String)] = [
            ("ERR_MIC_PERMISSION",       "ErrorCue_MicPermission"),
            ("ERR_WORK_TIMEOUT",         "ErrorCue_Retryable"),
            ("ERR_NO_SPEECH_FILE",       "ErrorCue_TextOnly"),
            ("ERR_WC_NOT_ACTIVATED",     "ErrorCue_PhoneUnreachable"),
            ("ERR_RESULT_UNKNOWN",       "ErrorCue_ManualConfirm"),
        ]
        for (idx, pair) in mapping.enumerated() {
            let entry = ErrorCueCatalog.cue(for: pair.code)
            XCTAssertEqual(entry.clip, pair.clip,
                           "\(pair.code) 必须映射到 \(pair.clip)")

            let bundleUrl = Bundle(for: type(of: self)).url(forResource: pair.clip, withExtension: "m4a")
                ?? Bundle.main.url(forResource: pair.clip, withExtension: "m4a")
            let url = try XCTUnwrap(bundleUrl, "\(pair.clip).m4a 缺失，装机会走文字+触觉降级")
            let data = try Data(contentsOf: url)
            XCTAssertGreaterThan(data.count, 1_000,
                                 "\(pair.clip).m4a 太小，怀疑是空占位而非 qwen-audio-realtime 生成")

            let presenter = presenter()
            let requestId = "019fcb62-0000-7000-8000-000000000\(String(format: "%03d", 262 + idx))"
            let now = Date(timeIntervalSince1970: 1_722_000_400 + TimeInterval(idx))
            var loaded = 0
            var played = 0
            XCTAssertTrue(presenter.present(
                code: pair.code,
                requestId: requestId,
                now: now,
                clipLoader: { name in
                    XCTAssertEqual(name, pair.clip, "loader 拿到的 clip 名要与查表一致")
                    loaded += 1
                    return data
                },
                playAudio: { bytes, id in
                    XCTAssertEqual(id, requestId)
                    XCTAssertEqual(bytes.count, data.count)
                    played += 1
                    return true
                },
                playHaptic: haptic
            ))
            let active = try XCTUnwrap(presenter.active)
            XCTAssertEqual(active.entry.code, pair.code)
            XCTAssertEqual(active.entry.clip, pair.clip)
            XCTAssertTrue(active.audioAttempted,
                          "\(pair.clip) 加载 + 起播成功 → audio_attempted=true")
            XCTAssertEqual(loaded, 1, "\(pair.clip) 加载器只应被调一次")
            XCTAssertEqual(played, 1, "\(pair.clip) 播放器只应被调一次")
            XCTAssertEqual(hapticsFired.count, idx + 1,
                           "\(pair.clip) 语音成功也一定要震一次（累计）")
            XCTAssertEqual(hapticsFired.last ?? nil, requestId,
                           "\(pair.clip) 最新一次触觉带对 requestId")

            // R-02.1：把「clip 加载 + 起播 + audio_attempted=true」显式落到
            // WatchLog，复审可在 bridge.log 上按 event=e262_new_clip_played
            // 直接读到 D2 v1.1 五条资产真的入包并被触发。
            WatchLog.info(
                "avatar_error",
                "e262_new_clip_played",
                requestId: requestId,
                detail: "code=\(pair.code) clip=\(pair.clip)"
                    + " bytes=\(data.count)"
                    + " audio_attempted=true"
                    + " family=\(active.entry.recoveryFamily.rawValue)"
            )
        }
    }

    /// ESS-262 R-02.1 补：新增语音资产若加载/起播失败仍走「文字 + 触觉」降级，
    /// audio_attempted=false 触发 UI 露出「静音提醒」小字——绝不静音吞错。
    func testD2V11NewClipsFallbackWhenPlaybackFails() throws {
        let presenter = presenter()
        let requestId = "019fcb62-0000-7000-8000-000000000fbk"
        let now = Date(timeIntervalSince1970: 1_722_000_500)
        // 模拟耳机断开 / 播放器起不来：clipLoader 拿到数据，playAudio 返回 false。
        XCTAssertTrue(presenter.present(
            code: "ERR_MIC_PERMISSION",
            requestId: requestId,
            now: now,
            clipLoader: { _ in Data(repeating: 0, count: 4096) },
            playAudio: { _, _ in false },
            playHaptic: haptic
        ))
        let active = try XCTUnwrap(presenter.active)
        XCTAssertEqual(active.entry.clip, "ErrorCue_MicPermission")
        XCTAssertFalse(active.audioAttempted,
                       "起播返回 false → audio_attempted=false，UI 露出「静音提醒」")
        XCTAssertEqual(hapticsFired, [requestId], "触觉照打——绝不静音吞错")

        WatchLog.info(
            "avatar_error",
            "e262_new_clip_fallback",
            requestId: requestId,
            detail: "code=ERR_MIC_PERMISSION clip=ErrorCue_MicPermission"
                + " audio_attempted=false haptic_fired=true card_visible=true"
        )
    }

    /// ESS-254 R-02：在 watchOS 测试进程中走真实接收入口，产出
    /// `result_audio_degraded` WatchLog，并验证 completed 不被改写成 failed。
    func testResultAudioDegradationRuntimeEventKeepsTextAndProjectsE12() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ess254-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = VoiceTurnJournal(directory: directory)
        let requestId = "018f4c6e-0000-7000-8000-000000000254"
        journal.begin(requestId: requestId)
        let result = VoiceResultPayload(
            summary: "文字答案仍然可读", isTruncated: false,
            speechSha256: "abc", speechDurationMs: 1_000
        )
        XCTAssertTrue(journal.apply(.status(requestId: requestId, state: .completed, result: result)))

        var projectedCode: String?
        journal.onResultAudioDegraded = { _, code in projectedCode = code }
        let store = WatchSettingsStore()
        store.voiceJournal = journal
        let event = VoiceResultAudioDegradationEnvelope.event(
            requestId: requestId, occurredAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        store.applyAudioDegradation(try event.jsonData())

        XCTAssertEqual(projectedCode, "ERR_NO_SPEECH_FILE")
        XCTAssertEqual(journal.turn(withId: requestId)?.currentState, .completed)
        XCTAssertEqual(journal.turn(withId: requestId)?.result?.summary, "文字答案仍然可读")
        XCTAssertEqual(
            ErrorCueCatalog.cue(for: projectedCode).text,
            "答案在，只是语音没留住——文字给你看。"
        )
    }
}
