import XCTest
@testable import WristAgentCore

/// ESS-65 / G9：装机音频自检的决策与日志契约。
/// detail 格式是 Bridge 侧 watch-smoke.mjs 的解析契约，字段名/取值变更
/// 必须两侧同步——这些用例就是那份契约的 Swift 侧锚点。
final class SelfCheckPolicyTests: XCTestCase {
    private let fingerprint = "version=0.1.0 build=1 built_at=2026-08-02T06:00:00Z"

    // MARK: - shouldAutoRun：同一 build 只跑一次

    func testFirstLaunchRuns() {
        XCTAssertTrue(SelfCheckPolicy.shouldAutoRun(currentFingerprint: fingerprint, lastRun: nil))
    }

    func testSameBuildAfterPassDoesNotRerun() {
        let last = SelfCheckPolicy.RunRecord(fingerprintDetail: fingerprint, result: .pass)
        XCTAssertFalse(SelfCheckPolicy.shouldAutoRun(currentFingerprint: fingerprint, lastRun: last))
    }

    func testSameBuildAfterFailDoesNotRerun() {
        // 确定性失败重跑不会变绿，只会每次启动都抢一次麦克风；
        // 失败证据已在 bridge.log，门禁已拦住，重跑走手动入口。
        let last = SelfCheckPolicy.RunRecord(fingerprintDetail: fingerprint, result: .fail)
        XCTAssertFalse(SelfCheckPolicy.shouldAutoRun(currentFingerprint: fingerprint, lastRun: last))
    }

    func testSameBuildAfterInconclusiveReruns() {
        // 授权补上以后，下一次启动要能自动补跑完整自检，不依赖用户找到手动入口。
        let last = SelfCheckPolicy.RunRecord(fingerprintDetail: fingerprint, result: .inconclusive)
        XCTAssertTrue(SelfCheckPolicy.shouldAutoRun(currentFingerprint: fingerprint, lastRun: last))
    }

    func testNewBuildReruns() {
        let last = SelfCheckPolicy.RunRecord(fingerprintDetail: fingerprint, result: .pass)
        let newer = "version=0.1.0 build=1 built_at=2026-08-02T09:00:00Z"
        XCTAssertTrue(SelfCheckPolicy.shouldAutoRun(currentFingerprint: newer, lastRun: last))
    }

    // MARK: - 日志契约

    func testStepDetailFormat() {
        XCTAssertEqual(
            SelfCheckPolicy.stepDetail(step: .record, passed: true, elapsedMs: 612),
            "step=S1 result=pass elapsed_ms=612"
        )
        XCTAssertEqual(
            SelfCheckPolicy.stepDetail(step: .playThenRecord, passed: false, elapsedMs: -5),
            "step=S3 result=fail elapsed_ms=0"
        )
    }

    func testFinishedDetailPass() {
        XCTAssertEqual(
            SelfCheckPolicy.finishedDetail(outcome: .pass, fingerprint: fingerprint),
            "result=pass failed_step=none \(fingerprint)"
        )
    }

    func testFinishedDetailFailCarriesFailedStep() {
        let detail = SelfCheckPolicy.finishedDetail(
            outcome: .failed(step: .playThenRecord, code: "NSOSStatusErrorDomain#-50"),
            fingerprint: fingerprint
        )
        XCTAssertEqual(detail, "result=fail failed_step=S3 \(fingerprint)")
    }

    func testFinishedDetailInconclusiveCarriesReason() {
        let detail = SelfCheckPolicy.finishedDetail(
            outcome: .inconclusive(.micPermissionMissing),
            fingerprint: fingerprint
        )
        XCTAssertEqual(
            detail,
            "result=inconclusive failed_step=none reason=mic_permission_missing \(fingerprint)"
        )
    }

    // MARK: - S5/S6 观测记录契约（与毕玄在 ESS-65 评论对齐的字段与枚举）

    func testStepRawValuesCoverS5S6() {
        XCTAssertEqual(SelfCheckPolicy.Step.interruptionGate.rawValue, "S5")
        XCTAssertEqual(SelfCheckPolicy.Step.dualActivationFailure.rawValue, "S6")
    }

    // ESS-72：S3'（录音→播放交替）落地为 S3R，Bridge 侧 stepDescription 同名对应。
    func testStepRawValueCoversS3R() {
        XCTAssertEqual(SelfCheckPolicy.Step.recordThenPlay.rawValue, "S3R")
    }

    func testObservationDetailDeferredPhase() {
        let detail = SelfCheckPolicy.observationDetail(
            step: .interruptionGate, phase: "deferred", scenePhase: "active",
            interruptionState: .began, requestTs: 1754112000000, callbackTs: nil,
            longFormResult: .skippedInterrupted, fallbackResult: .skippedInterrupted
        )
        XCTAssertEqual(
            detail,
            "step=S5 phase=deferred scene_phase=active interruption_state=began "
                + "request_ts=1754112000000 callback_ts=none "
                + "long_form_result=skipped_interrupted fallback_result=skipped_interrupted"
        )
    }

    func testObservationDetailExhaustedPhase() {
        let detail = SelfCheckPolicy.observationDetail(
            step: .dualActivationFailure, phase: "exhausted", scenePhase: "active",
            interruptionState: .none, requestTs: 1754112000000, callbackTs: 1754112000180,
            longFormResult: .failed, fallbackResult: .failed
        )
        XCTAssertEqual(
            detail,
            "step=S6 phase=exhausted scene_phase=active interruption_state=none "
                + "request_ts=1754112000000 callback_ts=1754112000180 "
                + "long_form_result=failed fallback_result=failed"
        )
    }

    // MARK: - 结论分类与文案

    func testOutcomeResultMapping() {
        XCTAssertEqual(SelfCheckPolicy.Outcome.pass.result, .pass)
        XCTAssertEqual(SelfCheckPolicy.Outcome.failed(step: .record, code: nil).result, .fail)
        XCTAssertEqual(SelfCheckPolicy.Outcome.inconclusive(.interrupted).result, .inconclusive)
    }

    func testUserMessageDistinguishesPermissionFromDefect() {
        let permission = SelfCheckPolicy.userMessage(outcome: .inconclusive(.micPermissionMissing))
        XCTAssertTrue(permission.contains("麦克风权限"))
        XCTAssertFalse(permission.contains("未通过"))

        let defect = SelfCheckPolicy.userMessage(
            outcome: .failed(step: .playThenRecord, code: "NSOSStatusErrorDomain#-50")
        )
        XCTAssertTrue(defect.contains("S3"))
        // PD 约束 3：失败只拦验收，不拦使用——文案必须说清 App 仍可用。
        XCTAssertTrue(defect.contains("仍可正常使用"))
    }

    // MARK: - ESS-137 S1→S2 会话让出屏障

    /// 屏障必须 > 0：模拟器 6ms 可通、真机 !res 复现之间的差就是这个屏障。
    /// 数值锚点：AVAudioSession route change 通知通常 200ms 内投递（watchOS
    /// 经验值），本值给到 300ms 是给硬件回收留 100ms 余量。同时不能过大，
    /// 每次录音后都会等一次，S1/S3 加起来占自检总预算 ~10s 的 6%——本上限是 500ms。
    func testReleaseSettleMsIsBoundedNonZero() {
        XCTAssertGreaterThan(SelfCheckPolicy.releaseSettleMs, 0)
        XCTAssertLessThanOrEqual(SelfCheckPolicy.releaseSettleMs, 500)
    }
}
