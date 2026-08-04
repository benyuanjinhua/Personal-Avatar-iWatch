import XCTest
@testable import WristAgentCore

/// ESS-180：主界面文案禁止「已等待 N 秒」。这里独立校验 MainStatusCopy 的
/// `containsDigit` 判定，`WatchContentView` 的实际拼装留给 WatchTests 的
/// runtime evidence（swift test 编不到 SwiftUI View）。
final class MainStatusCopyTests: XCTestCase {
    func testDigitFreeCopyIsAccepted() {
        let copy = MainStatusCopy(title: "分身正在思考…", subtitle: "结果好了会震动提醒")
        XCTAssertFalse(copy.containsDigit)
    }

    func testAnyDigitInTitleFailsValidation() {
        let copy = MainStatusCopy(title: "已等待 85 秒", subtitle: "受理后会有震动提醒")
        XCTAssertTrue(copy.containsDigit, "白梦林原始 bug 的截图文案必须被拒")
    }

    func testAnyDigitInSubtitleFailsValidation() {
        let copy = MainStatusCopy(title: "分身还在跑…", subtitle: "已等待 1:20")
        XCTAssertTrue(copy.containsDigit)
    }

    func testEmptyCopyIsAlsoDigitFree() {
        XCTAssertFalse(MainStatusCopy(title: "", subtitle: "").containsDigit)
    }
}
