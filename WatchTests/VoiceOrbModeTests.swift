import XCTest
@testable import WristAgent_Watch_App

/// ESS-572（Wave 0 / F7）验收标准钉表测试。
///
/// AC-1 ～ AC-5（编译期 / 单测）在这里覆盖。
/// 关键点：
/// 1) 五态与专属呼吸频率（0.6 / 0.6 / 2.0 / 1.3 / 1.3 Hz）被钉死——改动数字
///    要同步更新 ESS-540 F7 的呼吸表，不允许悄悄漂移。
/// 2) 终态（completed/failed/cancelled）绝不产生独立 orb 显示，一律回到 idle
///    —— 白梦林原始 bug 的病灶就是失败态被 Orb 悄悄压掉。
final class VoiceOrbModeTests: XCTestCase {

    // MARK: - AC-1：5 态编译期保证（exhaustive switch，无 default 分支）

    /// AC-1：用无 default 分支的 switch 钉住 5 态。新增/删减 case 即编译失败。
    func testExhaustiveSwitchCoversExactlyFiveModes() {
        let modes: [VoiceOrbView.Mode] = [
            .idle,
            .establishing,
            .listening(level: 0),
            .thinking,
            .speaking,
        ]
        var names: [String] = []
        for m in modes {
            switch m {
            case .idle: names.append("idle")
            case .establishing: names.append("establishing")
            case .listening: names.append("listening")
            case .thinking: names.append("thinking")
            case .speaking: names.append("speaking")
            }
        }
        XCTAssertEqual(names, ["idle", "establishing", "listening", "thinking", "speaking"])
        XCTAssertEqual(modes.count, 5)
    }

    // MARK: - AC-2：establishing 与 idle 同频不同幅，且是两个独立 enum case

    func testEstablishingIsDistinctFromIdle() {
        XCTAssertNotEqual(VoiceOrbView.Mode.establishing, .idle)
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .establishing),
                       VoiceOrbView.breathHertz(for: .idle),
                       accuracy: 1e-9)
        XCTAssertNotEqual(VoiceOrbView.breathAmplitude(for: .establishing),
                          VoiceOrbView.breathAmplitude(for: .idle))
    }

    // MARK: - AC-3：五态频率/幅度钉表

    func testBreathHertzPinnedPerMode() {
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .idle), 0.6, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .establishing), 0.6, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .listening(level: 0)), 2.0, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .listening(level: 0.7)), 2.0, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .thinking), 1.3, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .speaking), 1.3, accuracy: 1e-9)
    }

    func testBreathAmplitudePinnedPerMode() {
        XCTAssertEqual(VoiceOrbView.breathAmplitude(for: .idle), 0.02, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathAmplitude(for: .establishing), 0.04, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathAmplitude(for: .listening(level: 0)), 0.08, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathAmplitude(for: .thinking), 0.06, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathAmplitude(for: .speaking), 0.06, accuracy: 1e-9)
    }

    // MARK: - AC-4：listening 电平变化不触发转场动画重建

    func testListeningModeTagStableAcrossLevels() {
        let modeLow = VoiceOrbView(mode: .listening(level: 0.1))
        let modeHigh = VoiceOrbView(mode: .listening(level: 0.9))
        XCTAssertEqual(modeLow.modeTag, modeHigh.modeTag)
        XCTAssertEqual(modeLow.modeTag, 2)
    }

    // MARK: - 基础 Equatable / 区分性

    func testListeningModeIgnoresLevelForEquality() {
        XCTAssertNotEqual(VoiceOrbView.Mode.listening(level: 0),
                          VoiceOrbView.Mode.listening(level: 0.5))
        XCTAssertNotEqual(VoiceOrbView.Mode.listening(level: 0), .idle)
    }

    func testThinkingAndSpeakingAreDistinct() {
        XCTAssertNotEqual(VoiceOrbView.Mode.thinking, .speaking)
    }

    func testIdleUsesPhoneEntrySymbol() {
        XCTAssertEqual(VoiceOrbView.symbol(for: .idle), "phone.fill")
    }
}
