// ESS-366 demo — 故意让 Watch xctest 失败，重现 ESS-360 报告的形态：
// "所有套件 0 failures 但末尾 Failing tests: 非空"。
// 本文件不会合入 main。仅作为 CI 反例的实跑证据。
import XCTest

@testable import WristAgent_Watch_App

@MainActor
final class ESS366GateDemoWatchTests: XCTestCase {
    func testGateShouldBlockEss360Pattern() {
        XCTFail("ESS-366 demo: intentional watch xctest failure to reproduce ESS-360 pattern")
    }
}
