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
    }

    private let directory: URL
    private let key: SymmetricKey
    private let fileManager = FileManager.default

    /// 测试可传入固定密钥；生产用钥匙串托管密钥。
    init(directory: URL, key: SymmetricKey? = nil) throws {
        self.directory = directory
        self.key = key ?? Self.keychainKey()
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

    /// ESS-319 ③屏「清除历史语音」：删除仓内全部密文，返回实际删除的条数。
    ///
    /// 按扩展名过滤而不是无差别清目录——目录由本类独占，但一旦将来有人
    /// 往里放别的东西（临时文件、索引），无差别删除会连带清掉，
    /// 而这个入口是用户手动触发的，误删没有第二次机会。
    @discardableResult
    func removeAll() -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where (name as NSString).pathExtension == "sealed" {
            let url = directory.appendingPathComponent(name)
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("sealed")
    }

    // MARK: - 钥匙串托管密钥

    private static let keychainService = "com.benyuan.wristagent.audio-vault-key"
    private static let keychainAccount = "default"

    private static func keychainKey() -> SymmetricKey {
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
        SecItemAdd(item as CFDictionary, nil)
        return key
    }
}
