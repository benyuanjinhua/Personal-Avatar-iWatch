// ESS-366 demo — 故意让 `swift test` 失败一次，证明 CI 门禁真的会拦。
// 本文件不会合入 main：仅作为 CI 反例的实跑证据。
import XCTest

final class ESS366GateDemoTests: XCTestCase {
    func testGateShouldBlockThisFailure() {
        XCTFail("ESS-366 demo: intentional swift test failure to prove CI blocks red PRs")
    }
}
