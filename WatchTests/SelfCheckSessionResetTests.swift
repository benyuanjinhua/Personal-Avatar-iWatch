import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-218：S4 会话状态复位从「单点同步读」改为「有界轮询」的 watchOS 宿主运行时证据
/// （R-02.1）。真机事故：S3R `play_finished` 后 2ms 立即读 `routeSharingPolicy`，
/// 播放器来不及把 `.longFormAudio` 降回去，唯一一次播放链路全绿的自检也被 S4 判失败。
///
/// 修复契约：
/// - 正常路径（policy 已复位到 .default）：首次探测（elapsed ≈ 0）立即通过；
/// - 慢复位路径：容忍 [0, 100, 200, 400] ms 窗口内的延迟归还；
/// - 真正长期残留（本测用「保持 .longFormAudio 前置态」注入）：耗尽后判 fail，
///   fallbackCode == ERR_ROUTE_POLICY_RESIDUE，绝不改成永远通过。
@MainActor
final class SelfCheckSessionResetTests: XCTestCase {

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(event: String, detail: String?, code: String?)] = []
        func record(event: String, detail: String?, code: String?) {
            lock.lock(); defer { lock.unlock() }
            entries.append((event, detail, code))
        }
        func matches(event: String, detailContains fragment: String? = nil) -> [(String?, String?)] {
            lock.lock(); defer { lock.unlock() }
            return entries.compactMap {
                guard $0.event == event else { return nil }
                if let fragment, !($0.detail?.contains(fragment) ?? false) { return nil }
                return ($0.detail, $0.code)
            }
        }
    }

    /// 宿主 App 启动即自动播欢迎语（约 3.3s），会占据播放通道——先等它播完再开测。
    private func waitForHostWelcomeToFinish() async throws {
        try await Task.sleep(for: .seconds(4))
    }

    /// 复位后清理：把会话切回默认，避免污染后续用例。
    private func teardownSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: .default, policy: .default)
    }

    /// ESS-218 验收 1：Given S3R 播放成功结束（policy 已复位到 .default），
    /// When 跑 S4，Then 首次探测即通过，不因 2ms 内策略未复位而判失败。
    func testSessionResetPassesFastWhenPolicyAlreadyDefault() async throws {
        try await waitForHostWelcomeToFinish()
        let session = AVAudioSession.sharedInstance()
        // 前置态：播放刚结束后的健康状态——category .playback，policy 已回到 .default。
        try session.setCategory(.playback, mode: .default, policy: .default)
        try session.setActive(true)
        XCTAssertNotEqual(session.routeSharingPolicy, .longFormAudio, "前置态：policy 必须已复位")

        let events = EventLog()
        WatchLog.setObserver { _, event, detail, code in events.record(event: event, detail: detail, code: code) }
        defer { WatchLog.setObserver(nil); teardownSession() }

        let runner = SelfCheckRunner()
        let startedAt = Date()
        let outcome = await runner.sessionResetStep()
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        XCTAssertNil(outcome, "policy 已复位时 S4 必须通过（返回 nil）")
        // 首次探测 delayMs=0，通过路径不应等待后续 100/200/400ms 序列。
        XCTAssertLessThan(elapsedMs, 100, "policy 已复位时应首次探测即返回，实际耗时 \(elapsedMs)ms")

        let stateMatches = events.matches(event: "session_state")
        XCTAssertGreaterThan(stateMatches.count, 0, "S4 必须落 session_state 取证事件")
        let (detail, code) = try XCTUnwrap(stateMatches.last)
        let text = try XCTUnwrap(detail)
        XCTAssertTrue(text.contains("result=reset"), "通过路径 detail 需带 result=reset；实际 detail=\(text)")
        XCTAssertTrue(text.contains("probes=1"), "首次即通过应 probes=1；实际 detail=\(text)")
        XCTAssertTrue(text.contains("elapsed_ms="), "detail 需带 elapsed_ms")
        XCTAssertNil(code, "通过路径 error_code 必须为空")

        // 通过路径必须落 selfcheck_step S4 pass。
        let stepMatches = events.matches(event: "selfcheck_step", detailContains: "step=S4")
        let (stepDetail, stepCode) = try XCTUnwrap(stepMatches.last)
        XCTAssertTrue(try XCTUnwrap(stepDetail).contains("result=pass"), "S4 应记为 pass")
        XCTAssertNil(stepCode, "S4 pass 时 error_code 必须为空")
    }

    /// ESS-218 验收 2：Given 策略确实长时间未复位（本测把 .longFormAudio 保持在
    /// 前置态、探测期间不释放），When 跑 S4，Then 轮询耗尽后仍判失败，
    /// fallbackCode == ERR_ROUTE_POLICY_RESIDUE——不能改成永远通过。
    func testSessionResetFailsWhenPolicyStuckAsLongFormAudio() async throws {
        try await waitForHostWelcomeToFinish()
        let session = AVAudioSession.sharedInstance()
        // 事故注入态：保持 .longFormAudio。sessionResetStep 内部只读 policy，
        // 不主动修改；探测期间 policy 不会自动降下来。
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try session.setActive(true)
        XCTAssertEqual(session.routeSharingPolicy, .longFormAudio, "前置态：policy 应保持 .longFormAudio")

        let events = EventLog()
        WatchLog.setObserver { _, event, detail, code in events.record(event: event, detail: detail, code: code) }
        defer { WatchLog.setObserver(nil); teardownSession() }

        let runner = SelfCheckRunner()
        let startedAt = Date()
        let outcome = await runner.sessionResetStep()
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        // 判定 fail + 原始错误码。
        guard case .failed(let step, let code) = outcome else {
            XCTFail("policy 长期残留时 S4 必须 fail；实际 outcome=\(String(describing: outcome))")
            return
        }
        XCTAssertEqual(step, .sessionReset, "失败步骤必须是 S4/sessionReset")
        XCTAssertEqual(code, "ERR_ROUTE_POLICY_RESIDUE", "fallbackCode 必须是 ERR_ROUTE_POLICY_RESIDUE")

        // 耗尽序列 [0, 100, 200, 400] 累计 ~700ms；给足 100ms 抖动余量。
        let expectedFloor = SelfCheckRunner.sessionResetWaitsMs.reduce(0, +)
        XCTAssertGreaterThanOrEqual(
            elapsedMs, Int(expectedFloor) - 50,
            "失败前必须至少等待轮询序列上限；实际耗时 \(elapsedMs)ms"
        )

        let stateMatches = events.matches(event: "session_state")
        XCTAssertGreaterThan(stateMatches.count, 0, "S4 必须落 session_state 取证事件")
        let (detail, stateCode) = try XCTUnwrap(stateMatches.last)
        let text = try XCTUnwrap(detail)
        XCTAssertTrue(text.contains("result=residue"), "耗尽路径 detail 需带 result=residue；实际 detail=\(text)")
        // 探测次数等于等待序列长度。
        XCTAssertTrue(
            text.contains("probes=\(SelfCheckRunner.sessionResetWaitsMs.count)"),
            "耗尽路径 probes 应等于序列长度；实际 detail=\(text)"
        )
        XCTAssertEqual(stateCode, "ERR_ROUTE_POLICY_RESIDUE", "耗尽路径必须带 ERR_ROUTE_POLICY_RESIDUE")

        // 失败路径也必须落 selfcheck_step S4 fail，带原始错误码。
        let stepMatches = events.matches(event: "selfcheck_step", detailContains: "step=S4")
        let (stepDetail, stepCode) = try XCTUnwrap(stepMatches.last)
        XCTAssertTrue(try XCTUnwrap(stepDetail).contains("result=fail"), "S4 应记为 fail")
        XCTAssertEqual(stepCode, "ERR_ROUTE_POLICY_RESIDUE", "step 事件的 error_code 必须一致")
    }

    /// 契约：S4 轮询等待序列固定为 [0, 100, 200, 400] ms（与 S1→S2 / S3→S3R
    /// 屏障对称）。序列变化会直接影响真机上能容忍的播放器策略归还延迟；
    /// 该常量既是运行时行为，也是复现 ESS-218 事故时的对账锚点。
    func testSessionResetWaitScheduleIsStable() {
        XCTAssertEqual(SelfCheckRunner.sessionResetWaitsMs, [0, 100, 200, 400])
    }
}
