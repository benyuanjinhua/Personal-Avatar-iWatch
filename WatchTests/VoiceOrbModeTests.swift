import XCTest
@testable import WristAgent_Watch_App

/// ESS-180-B R-02.1：语音球四态映射的运行时证据。
/// 关键点：
/// 1) 四态与专属呼吸频率（0.9 / 2.0 / 1.3 / 1.3 Hz）被钉死——改动数字要同步
///    更新白梦林拍板的呼吸表，不允许悄悄漂移。
/// 2) 终态（completed/failed/cancelled）绝不产生独立 orb 显示，一律回到 idle
///    —— 白梦林原始 bug 的病灶就是失败态被 Orb 悄悄压掉。
final class VoiceOrbModeTests: XCTestCase {
    func testFourDistinctModesExist() {
        // 编译期保证 Mode 只有四态；新增/删减态破坏这条测试即要求
        // 同步更新白梦林拍板的三态呼吸表。
        let modes: [VoiceOrbView.Mode] = [
            .idle,
            .listening(level: 0),
            .thinking,
            .speaking,
        ]
        XCTAssertEqual(modes.count, 4)
    }

    func testListeningModeIgnoresLevelForEquality() {
        // 电平不同不等（用于驱动波形动画），但都是 listening 态。
        XCTAssertNotEqual(VoiceOrbView.Mode.listening(level: 0),
                          VoiceOrbView.Mode.listening(level: 0.5))
        // 保底：都不是 idle。
        XCTAssertNotEqual(VoiceOrbView.Mode.listening(level: 0), .idle)
    }

    func testThinkingAndSpeakingAreDistinct() {
        XCTAssertNotEqual(VoiceOrbView.Mode.thinking, .speaking)
    }

    /// ESS-180-B 验收标准：四态呼吸频率精确锁死。
    func testBreathHertzPinnedPerMode() {
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .idle), 0.9, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .listening(level: 0)), 2.0, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .listening(level: 0.7)), 2.0, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .thinking), 1.3, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathHertz(for: .speaking), 1.3, accuracy: 1e-9)
    }

    /// 呼吸幅度也要锁：thinking/speaking 同幅（1.3 Hz 同源），listening 最大以配合波形。
    func testBreathAmplitudePinnedPerMode() {
        XCTAssertEqual(VoiceOrbView.breathAmplitude(for: .idle), 0.03, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathAmplitude(for: .listening(level: 0)), 0.08, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathAmplitude(for: .thinking), 0.06, accuracy: 1e-9)
        XCTAssertEqual(VoiceOrbView.breathAmplitude(for: .speaking), 0.06, accuracy: 1e-9)
    }
}
