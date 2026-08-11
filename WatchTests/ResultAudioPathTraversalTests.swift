import XCTest
@testable import WristAgent_Watch_App

/// ESS-749：服务端 `request_id` 未校验即参与结果音频落盘路径的目录穿越防线。
///
/// 在 watchOS 运行时（模拟器）真跑 `handleResultAudioFile`，验证：
/// - 合法 ID：音频落在 `resultsDirectory/<sha256(request_id)>.m4a`，原始 ID 不出现在文件名里；
/// - 恶意 ID（`../` 逃逸）：整条载荷被丢弃，app container 内不产生任何文件。
@MainActor
final class ResultAudioPathTraversalTests: XCTestCase {

    private var transport: WatchVoiceTransport!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        transport = WatchVoiceTransport()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ess749-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        transport = nil
        try super.tearDownWithError()
    }

    /// transferFile 落地的临时文件（WCSession 交给我们的那份）。
    private func stageIncomingAudio(_ data: Data) throws -> URL {
        let url = tempDirectory.appendingPathComponent("incoming-\(UUID().uuidString).m4a")
        try data.write(to: url)
        return url
    }

    private func payloadData(requestId: String, audio: Data) throws -> Data {
        try VoiceRelayResultPayload(
            requestId: requestId,
            text: "结果",
            audioSha256: VoiceDigest.sha256Hex(of: audio)
        ).jsonData()
    }

    func testWellFormedRequestIdStoresUnderDigestFileName() throws {
        let requestId = UUIDv7.generate().uuidString.lowercased()
        let audio = Data("ess749-audio-\(requestId)".utf8)
        let tempURL = try stageIncomingAudio(audio)

        transport.handleResultAudioFile(
            tempURL: tempURL, payloadData: try payloadData(requestId: requestId, audio: audio)
        )

        let expected = transport.resultsDirectory
            .appendingPathComponent("\(RelayIdentifier.fileToken(for: requestId)).m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertEqual(try Data(contentsOf: expected), audio)
        XCTAssertEqual(transport.lastResult?.requestId, requestId)

        // 原始 ID 不得出现在任何文件名里（不可逆摘要，非可读 ID）。
        let names = try FileManager.default.contentsOfDirectory(atPath: transport.resultsDirectory.path)
        XCTAssertFalse(names.contains { $0.contains(requestId) })

        try? FileManager.default.removeItem(at: expected)
    }

    func testTraversalRequestIdIsRejectedAndWritesNothing() throws {
        let audio = Data("ess749-hostile".utf8)
        let tempURL = try stageIncomingAudio(audio)
        let hostileId = "../../../../Library/Preferences/ess749-pwned"
        let before = try FileManager.default
            .contentsOfDirectory(atPath: transport.resultsDirectory.path).sorted()

        transport.handleResultAudioFile(
            tempURL: tempURL, payloadData: try payloadData(requestId: hostileId, audio: audio)
        )

        // 载荷在解码边界被丢弃：没有结果、没有新文件、目标目录外没有落点。
        XCTAssertNil(transport.lastResult)
        let after = try FileManager.default
            .contentsOfDirectory(atPath: transport.resultsDirectory.path).sorted()
        XCTAssertEqual(before, after)

        let escaped = transport.resultsDirectory
            .appendingPathComponent(hostileId).standardizedFileURL
            .appendingPathExtension("m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: escaped.deletingLastPathComponent()
                .appendingPathComponent("ess749-pwned.m4a").path
        ))
    }
}
