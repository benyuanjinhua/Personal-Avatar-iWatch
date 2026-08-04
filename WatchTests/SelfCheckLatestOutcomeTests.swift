import XCTest

@testable import WristAgent_Watch_App

/// ESS-163 复审补丁的运行时断言：Debug 面板在冷启动同 build 已跑过
/// （`autoRunIfNeeded` → `selfcheck_skipped`，`stage` 停在 `.idle`）时，
/// 必须能从磁盘 RunRecord 还原「最近一次结果」，而不是显示「尚未运行」。
///
/// 本用例直接构造带持久化记录的 `SelfCheckRunner`，验证 `latestOutcome`
/// 在三类结论下都能正确还原；额外一条用例锁住「无历史 + 从未跑」→ nil
/// 的空态契约，避免下游 UI 猜个默认值误导排查。
@MainActor
final class SelfCheckLatestOutcomeTests: XCTestCase {

    private func makeIsolatedDefaults(_ label: String) -> UserDefaults {
        // 每条用例独立 suite，避免残留互相污染；suite 名带 UUID 后缀，
        // 即便重试也是全新盘。
        let suite = "wristagent.tests.ess163.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func persist(_ record: SelfCheckPolicy.RunRecord, to defaults: UserDefaults) throws {
        let data = try JSONEncoder().encode(record)
        defaults.set(data, forKey: SelfCheckRunner.lastRunDefaultsKey)
    }

    func testLatestOutcomeReturnsNilWhenNoHistory() {
        let runner = SelfCheckRunner(defaults: makeIsolatedDefaults("empty"))
        XCTAssertNil(runner.latestOutcome, "首启前应为空态，UI 显示「尚未运行」")
    }

    func testLatestOutcomeRestoresPassFromDisk() throws {
        let defaults = makeIsolatedDefaults("pass")
        try persist(
            SelfCheckPolicy.RunRecord.from(
                outcome: .pass,
                fingerprintDetail: "version=1.0 build=1 built_at=2026-08-03T00:00:00Z"
            ),
            to: defaults
        )
        let runner = SelfCheckRunner(defaults: defaults)
        XCTAssertEqual(runner.latestOutcome, .pass)
    }

    func testLatestOutcomeRestoresFailWithStepAndCode() throws {
        let defaults = makeIsolatedDefaults("fail")
        let outcome: SelfCheckPolicy.Outcome = .failed(
            step: .playThenRecord, code: "NSOSStatusErrorDomain#-50"
        )
        try persist(
            SelfCheckPolicy.RunRecord.from(
                outcome: outcome,
                fingerprintDetail: "version=1.0 build=1 built_at=2026-08-03T00:00:00Z"
            ),
            to: defaults
        )
        let runner = SelfCheckRunner(defaults: defaults)
        XCTAssertEqual(runner.latestOutcome, outcome)
    }

    func testLatestOutcomeRestoresInconclusiveReason() throws {
        let defaults = makeIsolatedDefaults("inconclusive")
        try persist(
            SelfCheckPolicy.RunRecord.from(
                outcome: .inconclusive(.micPermissionMissing),
                fingerprintDetail: "version=1.0 build=1 built_at=2026-08-03T00:00:00Z"
            ),
            to: defaults
        )
        let runner = SelfCheckRunner(defaults: defaults)
        XCTAssertEqual(runner.latestOutcome, .inconclusive(.micPermissionMissing))
    }

    /// 旧记录（老版本 App 落盘、只有 fingerprintDetail+result 两个键）解码为 nil，
    /// UI 侧退回「尚未运行」空态——不猜默认 outcome，避免下次重跑时误导排查。
    func testLatestOutcomeYieldsNilForLegacyRecord() throws {
        let defaults = makeIsolatedDefaults("legacy")
        let legacyJSON = #"{"fingerprintDetail":"version=1.0 build=1 built_at=2026-08-03T00:00:00Z","result":"fail"}"#
            .data(using: .utf8)!
        defaults.set(legacyJSON, forKey: SelfCheckRunner.lastRunDefaultsKey)
        let runner = SelfCheckRunner(defaults: defaults)
        XCTAssertNil(runner.latestOutcome)
    }
}
