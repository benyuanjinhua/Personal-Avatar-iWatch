import XCTest
@testable import WristAgentCore

/// ESS-56：`cold_start` 上报的 build 指纹。
/// 契约是 Bridge 侧 `watch-build.mjs` 解析的那三个键，格式错了门禁就失效。
final class BuildFingerprintTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buildfp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: iso), "测试基准时间字面量本身必须可解析")
    }

    func testDetailEmitsTheThreeKeysTheBridgeGateParses() throws {
        let builtAt = try Self.date("2026-08-01T13:20:00Z")
        let fingerprint = BuildFingerprint(shortVersion: "0.1.0", build: "1", builtAt: builtAt)
        XCTAssertEqual(fingerprint.detail, "version=0.1.0 build=1 built_at=2026-08-01T13:20:00Z")
    }

    /// 时间读不到时必须是稳定的 `unknown`——Bridge 侧据此判"证据不足"并**不放行**，
    /// 若这里写成空串或省略键，门禁会退化成"解析失败"，判据就不再稳定。
    func testMissingBuildTimeIsReportedAsUnknownRatherThanOmitted() {
        let fingerprint = BuildFingerprint(shortVersion: "0.1.0", build: "1", builtAt: nil)
        XCTAssertEqual(fingerprint.builtAtText, "unknown")
        XCTAssertEqual(fingerprint.detail, "version=0.1.0 build=1 built_at=unknown")
    }

    func testMissingInfoPlistValuesFallBackToUnknown() {
        let fingerprint = BuildFingerprint(shortVersion: nil, build: "", builtAt: nil)
        XCTAssertEqual(fingerprint.detail, "version=unknown build=unknown built_at=unknown")
    }

    /// detail 是空格分隔的 k=v；版本号来自 Info.plist（可被改），值里混进空格或 `=`
    /// 会让 Bridge 侧解析错位，必须在客户端就归一。
    func testValuesWithSeparatorCharactersCannotBreakTheKeyValueFraming() {
        let fingerprint = BuildFingerprint(shortVersion: "0.1 beta=2", build: "1 2", builtAt: nil)
        XCTAssertEqual(fingerprint.detail, "version=0.1_beta_2 build=1_2 built_at=unknown")

        let tokens = fingerprint.detail.split(separator: " ")
        XCTAssertEqual(tokens.count, 3, "detail 必须恰好三个 token，否则 Bridge 侧解析错位")
    }

    func testBuiltAtReadsTheExecutableFileTimestamp() throws {
        let executable = directory.appendingPathComponent("WristAgent")
        try Data("binary".utf8).write(to: executable)
        let stamped = try Self.date("2026-08-01T13:20:00Z")
        try FileManager.default.setAttributes([.modificationDate: stamped], ofItemAtPath: executable.path)

        let resolved = BuildFingerprint.resolveBuiltAt(executableURL: executable, bundleURL: directory)
        XCTAssertEqual(resolved?.timeIntervalSince1970 ?? 0, stamped.timeIntervalSince1970, accuracy: 1)
    }

    func testBuiltAtFallsBackToTheBundleWhenTheExecutableIsUnreadable() throws {
        let missing = directory.appendingPathComponent("does-not-exist")
        let resolved = BuildFingerprint.resolveBuiltAt(executableURL: missing, bundleURL: directory)
        XCTAssertNotNil(resolved, "可执行文件读不到时应退到 bundle 目录时间戳")
    }

    /// 读不到时返回 nil 而不是 `Date()`：用当前时刻兜底会让每次冷启动都"看起来很新"，
    /// 门禁必然放行——恰好是 R3 那种旧 build 混进验收的场景。
    func testUnreadablePathsYieldNilInsteadOfNow() {
        let missing = directory.appendingPathComponent("nope")
        XCTAssertNil(BuildFingerprint.resolveBuiltAt(executableURL: missing, bundleURL: missing))
    }
}
