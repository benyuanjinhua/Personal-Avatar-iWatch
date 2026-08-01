import XCTest
@testable import WristAgentCore

/// ESS-55 验收：任何等待状态的文案在 10 秒内至少变化一次，不存在静止转圈。
final class WaitingStatusCopyTests: XCTestCase {
    private let waitingPhases: [VoiceTurnPhase] = [
        .sending,
        .waitingForPhone,
        .waitingForMac,
        .delivered,
        .processing(background: false),
        .processing(background: true)
    ]

    func testEveryWaitingPhaseChangesWithinTenSeconds() {
        // 验收硬口径：0–120 秒内任意时刻 t，t 与 t+10 的文案必须不同。
        for phase in waitingPhases {
            for t in 0...120 {
                let now = WaitingStatusCopy.entry(for: phase, elapsed: TimeInterval(t))
                let later = WaitingStatusCopy.entry(for: phase, elapsed: TimeInterval(t) + WaitingStatusCopy.maxSilentInterval)
                XCTAssertNotNil(now, "\(phase) 是等待相位，必须有阶梯文案")
                XCTAssertNotEqual(now, later, "\(phase) 在 t=\(t)s 后 10 秒文案未变化")
            }
        }
    }

    func testInitialCopyAcknowledgesReceipt() {
        // 主张 2：等待第一秒就要有状态，且处理中首档必须传达「已收到」。
        for background in [false, true] {
            let entry = WaitingStatusCopy.entry(for: .processing(background: background), elapsed: 0)
            XCTAssertTrue(entry?.title.contains("已收到") == true, "处理中首档文案应先给「已收到」回执")
        }
    }

    func testLongWaitMentionsElapsedSeconds() {
        let entry = WaitingStatusCopy.entry(for: .processing(background: true), elapsed: 45)
        XCTAssertTrue(entry?.subtitle.contains("45") == true, "长等待要能看到已等秒数")
    }

    func testTerminalAndConfirmationPhasesHaveNoLadder() {
        for phase: VoiceTurnPhase in [.completed, .cancelled, .needsConfirmation, .failed(.execution)] {
            XCTAssertNil(WaitingStatusCopy.entry(for: phase, elapsed: 30), "\(phase) 不是等待相位")
        }
    }

    func testNegativeElapsedClampsToFirstRung() {
        // 时钟偏移/事件时间晚于本地时钟：不崩、退回首档。
        let entry = WaitingStatusCopy.entry(for: .sending, elapsed: -5)
        XCTAssertEqual(entry, WaitingStatusCopy.entry(for: .sending, elapsed: 0))
    }
}
