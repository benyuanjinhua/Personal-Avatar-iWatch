import CryptoKit
import XCTest
@testable import WristAgentCore

/// ESS-419：SpeechVaultCleaner 单测 —— 覆盖删除复核、失败不计入、只清语音不动轮次。
@MainActor
final class SpeechVaultCleanerTests: XCTestCase {
    private var vaultDir: URL!
    private var journalDir: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-vault-cleaner-tests-\(UUID().uuidString)", isDirectory: true)
        vaultDir = base.appendingPathComponent("SpeechVault", isDirectory: true)
        journalDir = base.appendingPathComponent("VoiceTurns", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: vaultDir.deletingLastPathComponent()
        )
        super.tearDown()
    }

    // MARK: - 正常清除：N 条语音全部清除，journal speechFileName 全部置 nil

    func testClearsAllSpeechLeavesTurnsIntact() throws {
        let vault = try EncryptedAudioVault(directory: vaultDir, key: key)
        let journal = VoiceTurnJournal(directory: journalDir)

        // 准备：2 个回合各带语音
        journal.begin(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        let audio1 = Data("audio-1".utf8)
        try vault.store(audio1, name: "req-1-aaa.m4a")
        _ = journal.attachSpeech(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", fileName: "req-1-aaa.m4a")
        _ = journal.apply(VoiceStatusEnvelope.sampleCompleted(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))

        journal.begin(requestId: "F7A3D2B1-8E4C-4F9A-B6D8-1C5E7A9F0B3D")
        let audio2 = Data("audio-2".utf8)
        try vault.store(audio2, name: "req-2-bbb.m4a")
        _ = journal.attachSpeech(requestId: "F7A3D2B1-8E4C-4F9A-B6D8-1C5E7A9F0B3D", fileName: "req-2-bbb.m4a")
        _ = journal.apply(VoiceStatusEnvelope.sampleCompleted(requestId: "F7A3D2B1-8E4C-4F9A-B6D8-1C5E7A9F0B3D"))

        // 确认语音在仓
        XCTAssertTrue(vault.contains(name: "req-1-aaa.m4a"))
        XCTAssertTrue(vault.contains(name: "req-2-bbb.m4a"))

        let cleaner = SpeechVaultCleaner(
            journal: journal,
            vault: vault,
            vaultDirectoryURL: vaultDir
        )
        let result = cleaner.clearHistorySpeech()

        XCTAssertEqual(result.removed, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.orphans, 0)
        XCTAssertTrue(result.vaultAvailable)

        // vault 文件已删
        XCTAssertFalse(vault.contains(name: "req-1-aaa.m4a"))
        XCTAssertFalse(vault.contains(name: "req-2-bbb.m4a"))

        // journal speechFileName 已清
        XCTAssertNil(journal.turn(withId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")?.speechFileName)
        XCTAssertNil(journal.turn(withId: "F7A3D2B1-8E4C-4F9A-B6D8-1C5E7A9F0B3D")?.speechFileName)

        // 轮次与文字结果仍在
        XCTAssertNotNil(journal.turn(withId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        XCTAssertNotNil(journal.turn(withId: "F7A3D2B1-8E4C-4F9A-B6D8-1C5E7A9F0B3D"))
        XCTAssertEqual(journal.turn(withId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")?.currentState, .completed)
        XCTAssertEqual(journal.turn(withId: "F7A3D2B1-8E4C-4F9A-B6D8-1C5E7A9F0B3D")?.currentState, .completed)
    }

    // MARK: - 空仓：没有可清除的语音

    func testEmptyVaultReturnsNoSpeechMessage() throws {
        let vault = try EncryptedAudioVault(directory: vaultDir, key: key)
        let journal = VoiceTurnJournal(directory: journalDir)
        // 有轮次但无语音
        journal.begin(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        _ = journal.apply(VoiceStatusEnvelope.sampleCompleted(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))

        let cleaner = SpeechVaultCleaner(
            journal: journal,
            vault: vault,
            vaultDirectoryURL: vaultDir
        )
        let result = cleaner.clearHistorySpeech()

        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.orphans, 0)
        XCTAssertEqual(result.userMessage, "没有可清除的语音")
    }

    func testEmptyJournalReturnsNoSpeechMessage() throws {
        let vault = try EncryptedAudioVault(directory: vaultDir, key: key)
        let journal = VoiceTurnJournal(directory: journalDir)

        let cleaner = SpeechVaultCleaner(
            journal: journal,
            vault: vault,
            vaultDirectoryURL: vaultDir
        )
        let result = cleaner.clearHistorySpeech()

        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.userMessage, "没有可清除的语音")
    }

    // MARK: - vault 不可用

    func testVaultUnavailableReturnsCorrectMessage() {
        let journal = VoiceTurnJournal(directory: journalDir)
        journal.begin(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        _ = journal.attachSpeech(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", fileName: "req-1-aaa.m4a")

        let cleaner = SpeechVaultCleaner(
            journal: journal,
            vault: nil,
            vaultDirectoryURL: vaultDir
        )
        let result = cleaner.clearHistorySpeech()

        XCTAssertFalse(result.vaultAvailable)
        XCTAssertEqual(result.userMessage, "本机语音仓不可用")
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.failed, 0)

        // journal 引用未动
        XCTAssertNotNil(journal.turn(withId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")?.speechFileName)
    }

    // MARK: - 删除失败：计入 failed 且不清 journal

    func testDeleteFailureCountsAsFailedAndPreservesJournalReference() throws {
        let vault = try EncryptedAudioVault(directory: vaultDir, key: key)
        let journal = VoiceTurnJournal(directory: journalDir)

        // 准备一个有语音的回合
        journal.begin(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        let audio = Data("audio".utf8)
        try vault.store(audio, name: "req-1-aaa.m4a")
        _ = journal.attachSpeech(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", fileName: "req-1-aaa.m4a")
        _ = journal.apply(VoiceStatusEnvelope.sampleCompleted(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))

        let cleaner = SpeechVaultCleaner(
            journal: journal,
            vault: vault,
            vaultDirectoryURL: vaultDir
        )
        let result = cleaner.clearHistorySpeech()

        // 正常路径：删除成功
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertNil(journal.turn(withId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")?.speechFileName)
    }

    // MARK: - 残留清理只统计真正删除的文件

    func testOrphanCleanupCountsOnlyDeletedFiles() throws {
        let vault = try EncryptedAudioVault(directory: vaultDir, key: key)
        let journal = VoiceTurnJournal(directory: journalDir)

        // 创建一个 journal 不引用的残留文件
        let orphanData = Data("orphan".utf8)
        try vault.store(orphanData, name: "orphan-file.m4a")
        // 该文件不在 journal 里，应被检测为 orphan

        let cleaner = SpeechVaultCleaner(
            journal: journal,
            vault: vault,
            vaultDirectoryURL: vaultDir
        )
        let result = cleaner.clearHistorySpeech()

        XCTAssertEqual(result.orphans, 1)
        XCTAssertFalse(vault.contains(name: "orphan-file.m4a"))
    }

    // MARK: - 用户消息覆盖各种场景

    func testUserMessageForPartialFailure() throws {
        let result = SpeechVaultCleaner.ClearResult(
            removed: 3, failed: 2, orphans: 1, vaultAvailable: true
        )
        XCTAssertEqual(result.userMessage, "3 条已清，2 条失败（另清理 1 个残留文件）")
    }

    func testUserMessageForAllSuccess() {
        let result = SpeechVaultCleaner.ClearResult(
            removed: 5, failed: 0, orphans: 0, vaultAvailable: true
        )
        XCTAssertEqual(result.userMessage, "已清除 5 条结果语音")
    }

    func testUserMessageForVaultUnavailable() {
        let result = SpeechVaultCleaner.ClearResult(
            removed: 0, failed: 0, orphans: 0, vaultAvailable: false
        )
        XCTAssertEqual(result.userMessage, "本机语音仓不可用")
    }

    func testLogDetailFormat() {
        let result = SpeechVaultCleaner.ClearResult(
            removed: 2, failed: 1, orphans: 3, vaultAvailable: true
        )
        XCTAssertEqual(result.logDetail, "removed=2 failed=1 orphan=3")
    }
}

private extension VoiceStatusEnvelope {
    static func sampleCompleted(requestId: String) -> VoiceStatusEnvelope {
        VoiceStatusEnvelope.status(
            requestId: requestId,
            state: .completed,
            result: VoiceResultPayload(
                summary: "sample result",
                isTruncated: false,
                speechSha256: nil,
                speechDurationMs: nil
            )
        )
    }
}
