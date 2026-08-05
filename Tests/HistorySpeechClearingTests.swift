import CryptoKit
import XCTest
@testable import WristAgentCore

/// ESS-319 ③屏「清除历史语音」的两个落点：
/// `EncryptedAudioVault.removeAll()` 删密文，`VoiceTurnJournal.clearAllSpeech()` 清引用。
///
/// 白梦林 2026-08-04 拍板 Q2：「『清除历史语音』入口保留」。这里守的是
/// 「只清语音、不清历史」——把回合一起删掉，用户连自己问过什么都查不到。
@MainActor
final class HistorySpeechClearingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ess319-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeVault() throws -> EncryptedAudioVault {
        try EncryptedAudioVault(
            directory: directory.appendingPathComponent("vault", isDirectory: true),
            key: SymmetricKey(size: .bits256)
        )
    }

    // MARK: - Vault

    func testRemoveAllDeletesEveryStoredClipAndReportsCount() throws {
        let vault = try makeVault()
        for i in 0..<3 {
            _ = try vault.store(Data(repeating: UInt8(i), count: 64), name: "clip-\(i)")
        }
        XCTAssertTrue(vault.contains(name: "clip-1"))

        XCTAssertEqual(vault.removeAll(), 3, "返回值是给用户看的回执，必须等于实际删除条数")

        for i in 0..<3 {
            XCTAssertFalse(vault.contains(name: "clip-\(i)"), "清除后不得残留密文")
        }
    }

    func testRemoveAllOnEmptyVaultIsZeroNotAnError() throws {
        let vault = try makeVault()
        XCTAssertEqual(vault.removeAll(), 0, "空仓清除是正常路径，不应抛错或误报")
    }

    /// 目录当前由 vault 独占，但入口是用户手动触发且不可撤销——
    /// 一旦将来有人往目录里放索引/临时文件，无差别清目录会连带删掉。
    func testRemoveAllOnlyTouchesSealedFiles() throws {
        let vaultDir = directory.appendingPathComponent("vault", isDirectory: true)
        let vault = try makeVault()
        _ = try vault.store(Data([0xAB]), name: "clip")
        let bystander = vaultDir.appendingPathComponent("index.json")
        try Data("{}".utf8).write(to: bystander)

        XCTAssertEqual(vault.removeAll(), 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bystander.path),
            "非 .sealed 文件不属于本入口的清除范围"
        )
    }

    // MARK: - Journal

    func testClearAllSpeechDropsReferencesButKeepsTurns() throws {
        let journal = VoiceTurnJournal(directory: directory)
        let ids = ["req-a", "req-b", "req-c"]
        for id in ids { journal.begin(requestId: id) }
        XCTAssertTrue(journal.attachSpeech(requestId: "req-a", fileName: "a.m4a"))
        XCTAssertTrue(journal.attachSpeech(requestId: "req-c", fileName: "c.m4a"))

        XCTAssertEqual(journal.clearAllSpeech(), 2, "只统计真正带语音的回合")

        XCTAssertEqual(journal.turns.count, 3, "清的是语音，不是历史——回合必须原样保留")
        XCTAssertTrue(journal.turns.allSatisfy { $0.speechFileName == nil })
        XCTAssertEqual(Set(journal.turns.map(\.requestId)), Set(ids))
    }

    func testClearAllSpeechIsIdempotent() throws {
        let journal = VoiceTurnJournal(directory: directory)
        journal.begin(requestId: "req-a")
        XCTAssertTrue(journal.attachSpeech(requestId: "req-a", fileName: "a.m4a"))

        XCTAssertEqual(journal.clearAllSpeech(), 1)
        XCTAssertEqual(journal.clearAllSpeech(), 0, "重复点清除不应再报数，否则回执会骗人")
    }

    func testClearAllSpeechSurvivesRelaunch() throws {
        let first = VoiceTurnJournal(directory: directory)
        first.begin(requestId: "req-a")
        XCTAssertTrue(first.attachSpeech(requestId: "req-a", fileName: "a.m4a"))
        XCTAssertEqual(first.clearAllSpeech(), 1)

        let reopened = VoiceTurnJournal(directory: directory)
        XCTAssertEqual(reopened.turns.count, 1, "回合仍在")
        XCTAssertNil(reopened.turns.first?.speechFileName, "清除必须落盘，否则重启后语音又「回来」了")
    }
}
