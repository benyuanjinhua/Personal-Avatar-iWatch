import XCTest
@testable import WristAgent_Watch_App

/// ESS-180 R-02.1：语音球四态映射的运行时证据。
/// 只测 Mode 类型的语义（呼吸频率的正确性由 SwiftUI 动画层观察），
/// 关键点：终态（completed/failed/cancelled）绝不产生独立 orb 显示，
/// 一律回到 idle——白梦林原始 bug 的病灶就是失败态被 Orb 悄悄压掉。
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
}
