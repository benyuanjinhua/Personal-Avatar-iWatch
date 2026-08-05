import CryptoKit
import XCTest
@testable import WristAgentCore

/// ESS-419：SpeechVaultCleaner 单测 —— 覆盖删除复核、失败不计入、只清语音不动轮次。
@MainActor
final class SpeechVaultCleanerTests: XCTestCase {
    private var vaultDir: URL!
    private var journalDir: URL!
    private var baseDir: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        super.setUp()
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-vault-cleaner-tests-\(UUID().uuidString)", isDirectory: true)
        vaultDir = baseDir.appendingPathComponent("SpeechVault", isDirectory: true)
        journalDir = baseDir.appendingPathComponent("VoiceTurns", isDirectory: true)
    }

    override func tearDown() {
        // 恢复权限后再删（测试可能把目录改成只读）
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vaultDir.path)
        try? FileManager.default.removeItem(at: baseDir)
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

    /// 将 vault 目录降为只读，使 `vault.remove` 无法删除文件，
    /// 验证 `vault.contains` 复核 → 计 `failed` 且不清 journal `speechFileName`。
    func testDeleteFailureCountsAsFailedAndPreservesJournalReference() throws {
        let vault = try EncryptedAudioVault(directory: vaultDir, key: key)
        let journal = VoiceTurnJournal(directory: journalDir)

        // 准备一个有语音的回合
        journal.begin(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        let audio = Data("audio".utf8)
        try vault.store(audio, name: "req-1-aaa.m4a")
        _ = journal.attachSpeech(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", fileName: "req-1-aaa.m4a")
        _ = journal.apply(VoiceStatusEnvelope.sampleCompleted(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))

        // 降为只读，使 vault.remove 对 FileManager.default 的 unlink 失败
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: vaultDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vaultDir.path)
        }

        let cleaner = SpeechVaultCleaner(
            journal: journal,
            vault: vault,
            vaultDirectoryURL: vaultDir
        )
        let result = cleaner.clearHistorySpeech()

        // 删除失败 → removed=0, failed=1
        XCTAssertEqual(result.removed, 0, "只读目录下 remove 应失败，不应计入 removed")
        XCTAssertEqual(result.failed, 1, "只读目录下 remove 失败应计入 failed")

        // journal speechFileName 必须保住（②屏引用不断）
        XCTAssertNotNil(
            journal.turn(withId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")?.speechFileName,
            "删除失败时 speechFileName 必须保留，否则②屏再也引用不到该文件"
        )

        // 文案断言
        XCTAssertEqual(result.userMessage, "0 条已清，1 条失败")
    }

    // MARK: - 残留清理：删不掉的 orphan 不计数

    /// vault 目录只读时，残留文件删不掉，orphanCount 应为 0。
    func testOrphanCleanupDoesNotCountFailedDeletes() throws {
        let vault = try EncryptedAudioVault(directory: vaultDir, key: key)
        let journal = VoiceTurnJournal(directory: journalDir)

        // 创建一个 journal 不引用的残留文件
        try vault.store(Data("orphan".utf8), name: "orphan-file.m4a")

        // 降为只读
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: vaultDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vaultDir.path)
        }

        let cleaner = SpeechVaultCleaner(
            journal: journal,
            vault: vault,
            vaultDirectoryURL: vaultDir
        )
        let result = cleaner.clearHistorySpeech()

        // 删不掉 → orphanCount 不增加
        XCTAssertEqual(result.orphans, 0, "只读目录下残留文件删不掉，orphan 计数应为 0")
    }

    // MARK: - 残留清理：真正删除的才计数

    func testOrphanCleanupCountsOnlyDeletedFiles() throws {
        let vault = try EncryptedAudioVault(directory: vaultDir, key: key)
        let journal = VoiceTurnJournal(directory: journalDir)

        // 创建一个 journal 不引用的残留文件
        let orphanData = Data("orphan".utf8)
        try vault.store(orphanData, name: "orphan-file.m4a")

        let cleaner = SpeechVaultCleaner(
            journal: journal,
            vault: vault,
            vaultDirectoryURL: vaultDir
        )
        let result = cleaner.clearHistorySpeech()

        XCTAssertEqual(result.orphans, 1)
        XCTAssertFalse(vault.contains(name: "orphan-file.m4a"))
    }

    // MARK: - 幂等：连点两次清除，第二次返回 0

    func testClearIsIdempotent() throws {
        let vault = try EncryptedAudioVault(directory: vaultDir, key: key)
        let journal = VoiceTurnJournal(directory: journalDir)

        journal.begin(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        try vault.store(Data("audio".utf8), name: "req-1-aaa.m4a")
        _ = journal.attachSpeech(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", fileName: "req-1-aaa.m4a")
        _ = journal.apply(VoiceStatusEnvelope.sampleCompleted(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))

        let cleaner = SpeechVaultCleaner(journal: journal, vault: vault, vaultDirectoryURL: vaultDir)

        let first = cleaner.clearHistorySpeech()
        XCTAssertEqual(first.removed, 1)
        XCTAssertEqual(first.failed, 0)

        let second = cleaner.clearHistorySpeech()
        XCTAssertEqual(second.removed, 0, "第二次清除应返回 0（幂等）")
        XCTAssertEqual(second.failed, 0)
        XCTAssertEqual(second.userMessage, "没有可清除的语音")
    }

    // MARK: - 跨重启存活：清完重建 journal 不应复活 speechFileName

    func testClearSurvivesJournalReload() throws {
        let vault = try EncryptedAudioVault(directory: vaultDir, key: key)
        let journal = VoiceTurnJournal(directory: journalDir)

        journal.begin(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        try vault.store(Data("audio".utf8), name: "req-1-aaa.m4a")
        _ = journal.attachSpeech(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", fileName: "req-1-aaa.m4a")
        _ = journal.apply(VoiceStatusEnvelope.sampleCompleted(requestId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))

        let cleaner = SpeechVaultCleaner(journal: journal, vault: vault, vaultDirectoryURL: vaultDir)
        _ = cleaner.clearHistorySpeech()

        // 模拟重启：新建 journal 实例从磁盘恢复
        let reloadedJournal = VoiceTurnJournal(directory: journalDir)
        XCTAssertNil(
            reloadedJournal.turn(withId: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")?.speechFileName,
            "重启后 speechFileName 应仍为 nil"
        )
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
