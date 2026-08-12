import CryptoKit
import XCTest
@testable import WristAgentCore

// MARK: - 测试用 Keychain Mock

/// 内存 Keychain 实现：可用于验证 Keychain 失败和跨实例持久化路径。
private final class InMemoryKeyProvider: AudioVaultKeyProviding {
    var store: Data?
    var persistShouldThrow: OSStatus?

    func readExistingKey() -> SymmetricKey? {
        guard let data = store, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    func persistNewKey(_ data: Data) throws {
        if let status = persistShouldThrow {
            throw EncryptedAudioVault.VaultError.keychainSaveFailed(status)
        }
        store = data
    }

    func deleteKey() {
        store = nil
    }
}

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

    /// Keychain add 失败阻止 vault 创建：provider.persistNewKey 抛出 → init 传播错误，
    /// vault 不可用，目录和密文均不产生。
    func testKeychainAddFailurePreventsVaultCreation() throws {
        let provider = InMemoryKeyProvider()
        provider.persistShouldThrow = errSecNotAvailable

        XCTAssertThrowsError(try EncryptedAudioVault(directory: directory, keyProvider: provider)) { error in
            guard case .keychainSaveFailed(let status) = error as? EncryptedAudioVault.VaultError else {
                XCTFail("应抛出 VaultError.keychainSaveFailed，实际: \(error)")
                return
            }
            XCTAssertEqual(status, errSecNotAvailable, "OSStatus 应与注入值一致")
        }

        // 失败后不产生任何落盘
        let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(contents?.isEmpty ?? true, "Keychain 失败后目录应为空")
        XCTAssertNil(provider.store, "provider 不应保存 key")
    }

    /// Keychain 持久化路径：第一实例通过 provider 生成并保存 key、写密文，
    /// 第二实例从同一 provider 读取 key、解密旧密文。
    func testKeychainPersistenceAcrossInstances() throws {
        let provider = InMemoryKeyProvider()
        let audio = Data("重启前写入的音频数据".utf8)

        // 第一实例：provider 无 key → 生成新 key → persistNewKey 存入 provider
        let vault1 = try EncryptedAudioVault(directory: directory, keyProvider: provider)
        try vault1.store(audio, name: "persisted.m4a")
        XCTAssertNotNil(provider.store, "provider 应在 persistNewKey 后持有 key data")

        // 第二实例：用同一个 provider（含已保存的 key）创建新 vault
        let vault2 = try EncryptedAudioVault(directory: directory, keyProvider: provider)
        let loaded = try vault2.load(name: "persisted.m4a")
        XCTAssertEqual(loaded, audio, "第二实例应能用 provider 中的 key 解密历史数据")
        XCTAssertTrue(vault2.contains(name: "persisted.m4a"))
    }

    /// provider 不保存 key 时第二实例应无法解密（再现原始 bug 场景）。
    func testMissingKeyFailsDecryptionAcrossInstances() throws {
        let provider = InMemoryKeyProvider()
        let audio = Data("使用 key1 加密".utf8)

        let vault1 = try EncryptedAudioVault(directory: directory, keyProvider: provider)
        try vault1.store(audio, name: "lost.m4a")
        XCTAssertNotNil(provider.store)

        // 模拟 key 丢失：清空 provider
        provider.store = nil

        let vault2 = try EncryptedAudioVault(directory: directory, keyProvider: provider)
        // provider 无 key → 生成全新 key → 新 key ≠ 旧 key → 解密失败
        XCTAssertThrowsError(try vault2.load(name: "lost.m4a")) { error in
            guard case .corrupted = error as? EncryptedAudioVault.VaultError else {
                XCTFail("key 丢失后应抛出 .corrupted，实际: \(error)")
                return
            }
        }
    }
}
