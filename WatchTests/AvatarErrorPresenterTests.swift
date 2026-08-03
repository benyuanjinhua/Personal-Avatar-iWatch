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
        presenter.dismiss()
        XCTAssertNil(presenter.active)
    }

    /// ESS-180-A 阶段不打包语音资产（属 180-B 范围）。这里断言：Bundle 里没有
    /// 任何 ErrorCue_*.m4a 时，AvatarErrorPresenter 的默认 clipLoader 走「文字 +
    /// 触觉」降级路径——绝不静音吞错，也不因资产缺失崩溃。
    func testAbsentBundleClipsFallBackGracefully() {
        for name in ErrorCueCatalog.allClipNames {
            let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "m4a")
                ?? Bundle.main.url(forResource: name, withExtension: "m4a")
            XCTAssertNil(url, "180-A 阶段不应打包 \(name).m4a（属 180-B 范围）")
        }
        // 用真实 Bundle 加载器：无资产 → audioAttempted=false，卡片 + 触觉仍在。
        let presenter = AvatarErrorPresenter()
        _ = presenter.present(
            code: "ERR_VOICE_BUSY", requestId: "req_no_bundle",
            playAudio: { _, _ in true },  // 就算 playAudio 会成功，也会被没数据挡住
            playHaptic: haptic
        )
        XCTAssertNotNil(presenter.active)
        XCTAssertEqual(presenter.active?.audioAttempted, false)
        XCTAssertEqual(hapticsFired.count, 1)
    }
}
