import XCTest
@testable import WristAgentCore

final class ClientLogStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clientlog-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func lines(of url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    func testEntryEncodesContractKeysAsJSONLine() throws {
        let store = ClientLogStore(directory: directory)
        store.append(ClientLogEntry(
            ts: "2026-08-01T08:00:00.000Z",
            requestId: "req_abc",
            module: "welcome",
            event: "resource_missing",
            detail: "WelcomeSpeech.m4a not in bundle",
            error: .init(code: "ERR_WELCOME_ASSET_MISSING", description: "missing")
        ))
        let chunks = store.rotateForShipment()
        XCTAssertEqual(chunks.count, 1)
        let line = try XCTUnwrap(lines(of: chunks[0]).first)
        for key in ["\"ts\"", "\"request_id\"", "\"module\"", "\"event\"", "\"detail\"", "\"error\"", "\"code\"", "\"description\""] {
            XCTAssertTrue(line.contains(key), "缺少契约键：\(key)")
        }
        let decoded = try JSONDecoder().decode(ClientLogEntry.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.requestId, "req_abc")
        XCTAssertEqual(decoded.error?.code, "ERR_WELCOME_ASSET_MISSING")
    }

    func testAppendIsOrderedAndRotationSkipsEmptyCurrent() throws {
        let store = ClientLogStore(directory: directory)
        for index in 0..<5 {
            store.append(ClientLogEntry(module: "m", event: "e\(index)"))
        }
        let chunks = store.rotateForShipment()
        XCTAssertEqual(chunks.count, 1)
        let events = try lines(of: chunks[0])
            .map { try JSONDecoder().decode(ClientLogEntry.self, from: Data($0.utf8)) }
            .map(\.event)
        XCTAssertEqual(events, ["e0", "e1", "e2", "e3", "e4"])
        // 当前文件为空：再次滚动不产生新 chunk。
        XCTAssertEqual(store.rotateForShipment().count, 1)
    }

    func testRotatesWhenFileExceedsLimitAndCapsPendingChunks() throws {
        // 上限压小以便测试：每条约 100 字节，写满即滚动。
        let store = ClientLogStore(directory: directory, maxFileBytes: 300, maxPendingChunks: 3)
        for index in 0..<40 {
            store.append(ClientLogEntry(module: "m", event: "event-\(index)", detail: String(repeating: "x", count: 60)))
        }
        let chunks = store.rotateForShipment()
        XCTAssertEqual(chunks.count, 3, "chunk 保留数必须封顶")
        // 丢弃留痕：后续日志里有 chunks_dropped 标记。
        let allEntries = try chunks.flatMap { try lines(of: $0) }
            .map { try JSONDecoder().decode(ClientLogEntry.self, from: Data($0.utf8)) }
        XCTAssertTrue(allEntries.contains { $0.event == "chunks_dropped" })
        // 保留的是最新的日志（最后一条一定还在）。
        XCTAssertTrue(allEntries.contains { $0.event == "event-39" })
    }

    func testRemoveChunkOnlyTouchesChunkFiles() throws {
        let store = ClientLogStore(directory: directory)
        store.append(ClientLogEntry(module: "m", event: "e"))
        let chunk = try XCTUnwrap(store.rotateForShipment().first)
        store.removeChunk(named: "../outside.jsonl") // 非 chunk 名：拒绝
        store.removeChunk(named: chunk.lastPathComponent)
        XCTAssertEqual(store.pendingChunkURLs().count, 0)
    }

    func testUploadBodyUsesContractKeys() throws {
        let body = ClientLogUploadBody(chunkId: "watchlog-abc.jsonl", jsonl: "{}\n")
        let json = String(data: try body.jsonData(), encoding: .utf8)!
        for key in ["protocol_version", "chunk_id", "source", "jsonl"] {
            XCTAssertTrue(json.contains(key), "缺少契约键：\(key)")
        }
        XCTAssertTrue(json.contains("\"watch\""))
    }

    // MARK: - ESS-137 快速旁路：JSONL 单行与主路径逐字节等价

    func testEntryJsonlLineMatchesStoreEncoding() throws {
        let entry = ClientLogEntry(
            ts: "2026-08-02T13:46:18.000Z",
            module: "selfcheck", event: "selfcheck_finished",
            detail: "result=fail failed_step=S2 version=0.1.0 build=1 built_at=2026-08-02T10:27:52Z",
            error: .init(code: "NSOSStatusErrorDomain#561145203", description: "resource_not_available")
        )
        // 与 ClientLogStore.append 落盘同一 encoder（sortedKeys + withoutEscapingSlashes）
        // 编出来的字节，末尾必须带 \n——iPhone 侧 ClientLogUplink 按行透传 Bridge。
        let line = try entry.jsonlLine()
        XCTAssertEqual(line.last, 0x0A, "JSONL 末尾必须是换行")
        let store = ClientLogStore(directory: directory)
        store.append(entry)
        let chunk = try XCTUnwrap(store.rotateForShipment().first)
        let stored = try Data(contentsOf: chunk)
        XCTAssertEqual(
            stored, line,
            "快速旁路 microchunk 必须与 ClientLogStore 落盘字节完全一致，避免 Bridge 侧解析分歧"
        )
    }

    func testSelfCheckSummaryPayloadRoundTrip() throws {
        let payload = SelfCheckSummaryPayload(
            chunkId: "selfcheck-019fc300-abc.jsonl",
            jsonl: "{\"event\":\"selfcheck_finished\"}\n"
        )
        let encoded = try payload.encoded()
        let decoded = try XCTUnwrap(SelfCheckSummaryPayload.decode(from: encoded))
        XCTAssertEqual(decoded, payload)
        // 契约键必须是 snake_case，Bridge/iPhone 两侧都靠它对账。
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains("\"chunk_id\""))
        XCTAssertTrue(json.contains("\"jsonl\""))
    }

    func testSelfCheckSummaryPayloadDecodeRejectsGarbage() {
        XCTAssertNil(SelfCheckSummaryPayload.decode(from: Data("not json".utf8)))
        // 缺 chunk_id 或 jsonl 字段都必须解码失败——避免 iPhone 侧生成空 chunk。
        XCTAssertNil(SelfCheckSummaryPayload.decode(from: Data("{\"jsonl\":\"x\"}".utf8)))
        XCTAssertNil(SelfCheckSummaryPayload.decode(from: Data("{\"chunk_id\":\"x\"}".utf8)))
    }

    func testSelfCheckSummaryKeyIsStable() {
        // 该 key 是 Watch ↔ iPhone 的线格式契约，改名要 Bridge/iPhone/Watch 同步。
        XCTAssertEqual(
            WatchClientLogMessage.selfCheckSummaryKey,
            "watch_client_log_selfcheck_summary"
        )
    }
}
