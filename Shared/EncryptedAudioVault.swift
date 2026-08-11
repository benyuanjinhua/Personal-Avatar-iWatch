import CryptoKit
import Foundation
import Security

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
    init(directory: URL, key: SymmetricKey? = nil) throws {
        self.directory = directory
        self.key = try key ?? Self.keychainKey()
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

    private static let keychainService = "com.benyuan.wristagent.audio-vault-key"
    private static let keychainAccount = "default"

    private static func keychainKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            data.count == 32
        {
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = keyData
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultError.keychainSaveFailed(status)
        }
        return key
    }
}
