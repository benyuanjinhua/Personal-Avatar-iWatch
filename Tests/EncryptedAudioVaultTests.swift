import CryptoKit
import XCTest
@testable import WristAgentCore

final class EncryptedAudioVaultTests: XCTestCase {
    private var directory: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-vault-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testStoreLoadRoundTrip() throws {
        let vault = try EncryptedAudioVault(directory: directory, key: key)
        let audio = Data("假装是一段 AAC 语音".utf8)
        try vault.store(audio, name: "turn-1.m4a")
        XCTAssertTrue(vault.contains(name: "turn-1.m4a"))
        XCTAssertEqual(try vault.load(name: "turn-1.m4a"), audio)
    }

    func testCiphertextOnDiskIsNotPlaintext() throws {
        let vault = try EncryptedAudioVault(directory: directory, key: key)
        let audio = Data("plaintext-audio-marker".utf8)
        let url = try vault.store(audio, name: "turn-2.m4a")
        let onDisk = try Data(contentsOf: url)
        XCTAssertNil(
            String(data: onDisk, encoding: .utf8)?.range(of: "plaintext-audio-marker"),
            "落盘内容不能包含明文"
        )
        XCTAssertNotEqual(onDisk, audio)
    }

    func testTamperedFileFailsToOpen() throws {
        let vault = try EncryptedAudioVault(directory: directory, key: key)
        let url = try vault.store(Data("audio".utf8), name: "turn-3.m4a")
        var tampered = try Data(contentsOf: url)
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: url)
        XCTAssertThrowsError(try vault.load(name: "turn-3.m4a"))
    }

    func testWrongKeyFailsToOpen() throws {
        let vault = try EncryptedAudioVault(directory: directory, key: key)
        try vault.store(Data("audio".utf8), name: "turn-4.m4a")
        let otherVault = try EncryptedAudioVault(directory: directory, key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try otherVault.load(name: "turn-4.m4a"))
    }

    func testRemoveDeletesFile() throws {
        let vault = try EncryptedAudioVault(directory: directory, key: key)
        try vault.store(Data("audio".utf8), name: "turn-5.m4a")
        vault.remove(name: "turn-5.m4a")
        XCTAssertFalse(vault.contains(name: "turn-5.m4a"))
        XCTAssertThrowsError(try vault.load(name: "turn-5.m4a"))
    }

    /// 模拟重启：使用相同密钥创建新的 vault 实例后应能解密历史数据。
    func testRestartDecryptability() throws {
        let vault = try EncryptedAudioVault(directory: directory, key: key)
        let audio = Data("重启前写入的音频数据".utf8)
        try vault.store(audio, name: "persisted.m4a")

        // 模拟重启：用相同密钥创建新的 vault 实例
        let vaultAfterRestart = try EncryptedAudioVault(directory: directory, key: key)
        let loaded = try vaultAfterRestart.load(name: "persisted.m4a")
        XCTAssertEqual(loaded, audio, "重启后应能用同一密钥解密历史音频")
        XCTAssertTrue(vaultAfterRestart.contains(name: "persisted.m4a"))
    }

    /// 验证 keychainSaveFailed 错误类型构造正确且 Equatable。
    func testKeychainSaveFailedError() {
        let status: OSStatus = errSecNotAvailable
        let error = EncryptedAudioVault.VaultError.keychainSaveFailed(status)
        XCTAssertEqual(error, .keychainSaveFailed(errSecNotAvailable))
        XCTAssertNotEqual(error, .keychainSaveFailed(errSecDuplicateItem))
    }
}
