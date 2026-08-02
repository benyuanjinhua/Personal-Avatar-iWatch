import XCTest
@testable import WristAgentCore

/// ESS-55 一键重试缓存：失败重发不需要重新说话。
final class RetryRecordingStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func newRequestId() -> String {
        UUIDv7.generate().uuidString.lowercased()
    }

    func testSaveAndLoadRoundTrip() {
        let store = RetryRecordingStore(directory: directory)
        let requestId = newRequestId()
        let audio = Data("aac-bytes".utf8)
        store.save(requestId: requestId, data: audio, durationMs: 1234)

        XCTAssertEqual(store.stored(for: requestId), RetryRecordingStore.Stored(data: audio, durationMs: 1234))
        XCTAssertNil(store.stored(for: newRequestId()), "不匹配的 request_id 不能拿到录音")
    }

    func testStoreSurvivesRelaunch() {
        // 失败后用户可能先退出 App，重开仍能一键重试。
        let requestId = newRequestId()
        RetryRecordingStore(directory: directory).save(requestId: requestId, data: Data([1, 2, 3]), durationMs: 900)
        XCTAssertEqual(RetryRecordingStore(directory: directory).stored(for: requestId)?.durationMs, 900)
    }

    func testNewRecordingOverwritesOld() {
        let store = RetryRecordingStore(directory: directory)
        let old = newRequestId()
        let new = newRequestId()
        store.save(requestId: old, data: Data([1]), durationMs: 500)
        store.save(requestId: new, data: Data([2]), durationMs: 600)
        XCTAssertNil(store.stored(for: old), "只保留最近一条")
        XCTAssertEqual(store.stored(for: new)?.data, Data([2]))
    }

    func testClearOnlyMatchesOwnRequest() {
        let store = RetryRecordingStore(directory: directory)
        let current = newRequestId()
        store.save(requestId: current, data: Data([9]), durationMs: 700)
        store.clear(requestId: newRequestId())
        XCTAssertNotNil(store.stored(for: current), "别的回合的 clear 不能清掉现役缓存")
        store.clear(requestId: current)
        XCTAssertNil(store.stored(for: current))
    }

    func testRebindMovesAudioToNewRequestId() {
        // 重试 = 新 request_id 复用旧音频。
        let store = RetryRecordingStore(directory: directory)
        let original = newRequestId()
        let retried = newRequestId()
        store.save(requestId: original, data: Data([7, 7]), durationMs: 800)
        store.rebind(to: retried)
        XCTAssertNil(store.stored(for: original))
        XCTAssertEqual(store.stored(for: retried), RetryRecordingStore.Stored(data: Data([7, 7]), durationMs: 800))
    }
}
