import XCTest
@testable import WristAgentCore

/// ESS-749：服务端 `request_id` 参与客户端文件路径的目录穿越防线。
///
/// 覆盖三道闸口：
/// 1. 严格校验（长度/字符集）——坏 ID 在解码边界就被丢弃；
/// 2. 文件名只用不可逆摘要——原始 ID 永不进路径；
/// 3. 标准化后的目录内校验——即使前两道被绕过也逃不出目标目录。
final class RelayIdentifierTests: XCTestCase {

    // MARK: - 1. 严格 ID 校验

    func testAcceptsRealWorldIdentifierShapes() {
        XCTAssertTrue(RelayIdentifier.isValid(UUID().uuidString.lowercased()))
        XCTAssertTrue(RelayIdentifier.isValid(UUIDv7.generate().uuidString))
        XCTAssertTrue(RelayIdentifier.isValid("req_0123456789abcdef0123456789abcdef"))
        XCTAssertTrue(RelayIdentifier.isValid("probe-1"))
    }

    func testRejectsPathTraversalAndSeparators() {
        let hostile = [
            "../../../../Library/Preferences/com.apple.Bogus",
            "..",
            ".",
            "a/b",
            "a\\b",
            "/etc/passwd",
            "%2e%2e%2fetc",     // 含 `%`：不在白名单内
            "turn.state",        // `.` 不允许，杜绝 `..` 的一切变体
            "id\u{0000}.m4a",
            "id with space",
            "标识",              // 非 ASCII
        ]
        for value in hostile {
            XCTAssertFalse(RelayIdentifier.isValid(value), "must reject: \(value)")
        }
    }

    func testRejectsEmptyAndOverlongIdentifiers() {
        XCTAssertFalse(RelayIdentifier.isValid(""))
        XCTAssertTrue(RelayIdentifier.isValid(String(repeating: "a", count: RelayIdentifier.maxLength)))
        XCTAssertFalse(RelayIdentifier.isValid(String(repeating: "a", count: RelayIdentifier.maxLength + 1)))
    }

    func testValidatedMirrorsIsValid() {
        XCTAssertEqual(RelayIdentifier.validated("req_1"), "req_1")
        XCTAssertNil(RelayIdentifier.validated("../req_1"))
    }

    // MARK: - 2. 文件名摘要

    func testFileTokenIsStableIrreversibleHex() {
        let id = "3f2b1c4d-0000-7000-8000-000000000001"
        let token = RelayIdentifier.fileToken(for: id)
        XCTAssertEqual(token, RelayIdentifier.fileToken(for: id))
        XCTAssertEqual(token.count, 64)
        XCTAssertFalse(token.contains(id))
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(token, RelayIdentifier.fileToken(for: id + "x"))
    }

    /// 摘要必须对任何输入都是 path-safe：即便校验被绕过，文件名里也造不出分隔符。
    func testFileTokenIsPathSafeEvenForHostileIdentifiers() {
        for hostile in ["../../escape", "/absolute/path", "a\u{0000}b", "..", "点"] {
            let token = RelayIdentifier.fileToken(for: hostile)
            XCTAssertEqual(token.count, 64)
            XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
            XCTAssertTrue(RelayIdentifier.isValid(token))
        }
    }

    // MARK: - 3. 目录内校验

    func testFileURLStaysInsideTargetDirectory() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ess749-\(UUID().uuidString)", isDirectory: true)
        let url = try XCTUnwrap(RelayIdentifier.fileURL(in: base, name: "abc123.m4a"))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, base.standardizedFileURL.path)
        XCTAssertEqual(url.lastPathComponent, "abc123.m4a")
    }

    func testFileURLRejectsEscapingNames() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ess749-\(UUID().uuidString)", isDirectory: true)
        let hostile = [
            "../escaped.m4a",
            "../../Library/Preferences/com.apple.Bogus.plist",
            "sub/escaped.m4a",
            "..",
            ".",
            "",
            "a\u{0000}b.m4a",
        ]
        for name in hostile {
            XCTAssertNil(RelayIdentifier.fileURL(in: base, name: name), "must reject: \(name)")
        }
    }

    /// 端到端：恶意 ID 走完整链路（摘要 + 目录内校验）后仍落在目标目录内。
    func testHostileIdentifierCannotEscapeThroughFullPipeline() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ess749-\(UUID().uuidString)", isDirectory: true)
        let hostileId = "../../../../Library/Preferences/pwned"
        let url = try XCTUnwrap(RelayIdentifier.fileURL(
            in: base, name: "\(RelayIdentifier.fileToken(for: hostileId)).m4a"
        ))
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path + "/"))
        XCTAssertFalse(url.path.contains(".."))
        XCTAssertFalse(url.path.contains("Preferences"))
    }

    // MARK: - 解码边界

    func testResultPayloadDecodeRejectsTraversalRequestId() throws {
        let json = """
        {"protocol_version":"1.0","request_id":"../../../../Library/Preferences/pwned",\
        "text":"hi","audio_sha256":null,"completed_at":"2026-08-11T00:00:00Z"}
        """
        XCTAssertNil(VoiceRelayResultPayload.decode(from: Data(json.utf8)))
    }

    func testResultPayloadDecodeAcceptsWellFormedRequestId() throws {
        let payload = VoiceRelayResultPayload(
            requestId: UUIDv7.generate().uuidString.lowercased(),
            text: "hi",
            completedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let decoded = VoiceRelayResultPayload.decode(from: try payload.jsonData())
        XCTAssertEqual(decoded?.requestId, payload.requestId)
    }
}
