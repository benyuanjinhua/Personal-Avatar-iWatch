import CryptoKit
import Foundation
import Security

// MARK: - Keychain 抽象

/// 加密密钥存取边界：生产走 Keychain，测试可注入内存实现验证失败与持久化路径。
protocol AudioVaultKeyProviding {
    /// 读取已有密钥，不存在时返回 nil。
    func readExistingKey() -> SymmetricKey?
    /// 持久化新密钥；失败抛出对应 OSStatus。
    func persistNewKey(_ data: Data) throws
    /// 清理旧密钥。
    func deleteKey()
}

/// 生产 Keychain 实现。
struct KeychainAudioVaultKeyProvider: AudioVaultKeyProviding {
    private let service: String
    private let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    func readExistingKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }

    func persistNewKey(_ data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptedAudioVault.VaultError.keychainSaveFailed(status)
        }
    }

    func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 临时语音的加密存储（ESS-29）：结果语音落盘前用 AES-GCM 加密，
/// 播放时解密到内存、交付后删除文件。密钥保存在本机钥匙串
/// （ThisDeviceOnly，本地生成的对称密钥，不是任何云端凭据）。
final class EncryptedAudioVault {
    enum VaultError: Error, Equatable {
        case fileMissing(String)
        case corrupted(String)
        case keychainSaveFailed(OSStatus)
    }

    private let directory: URL
    private let key: SymmetricKey
    private let fileManager = FileManager.default

    /// 测试可传入固定密钥；生产用钥匙串托管密钥。
    /// `keyProvider` 仅在没有显式 `key` 时使用，用于 Keychain 失败与持久化测试。
    init(directory: URL, key: SymmetricKey? = nil, keyProvider: AudioVaultKeyProviding? = nil) throws {
        self.directory = directory
        if let key {
            self.key = key
        } else {
            self.key = try Self.keychainKey(provider: keyProvider)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    func store(_ data: Data, name: String) throws -> URL {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw VaultError.corrupted(name)
        }
        let url = fileURL(for: name)
        #if os(macOS)
        try combined.write(to: url, options: [.atomic])
        #else
        try combined.write(to: url, options: [.atomic, .completeFileProtection])
        #endif
        return url
    }

    func load(name: String) throws -> Data {
        let url = fileURL(for: name)
        guard let combined = try? Data(contentsOf: url) else {
            throw VaultError.fileMissing(name)
        }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultError.corrupted(name)
        }
    }

    func contains(name: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: name).path)
    }

    func remove(name: String) {
        try? fileManager.removeItem(at: fileURL(for: name))
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("sealed")
    }

    // MARK: - 钥匙串托管密钥

    private static let defaultKeychainProvider = KeychainAudioVaultKeyProvider(
        service: "com.benyuan.wristagent.audio-vault-key",
        account: "default"
    )

    private static func keychainKey(provider: AudioVaultKeyProviding? = nil) throws -> SymmetricKey {
        let provider = provider ?? defaultKeychainProvider
        if let existing = provider.readExistingKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try provider.persistNewKey(keyData)
        return key
    }
}
