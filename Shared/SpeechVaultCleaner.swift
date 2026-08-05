import Foundation

/// ESS-419：可测试的语音仓清理器。核心规则：
/// - 删除 → 复核（vault.contains / fileExists）→ 确认不存在才计 removed 并清 journal
/// - 复核失败则计 failed 且不清 journal speechFileName（保住 ②屏引用）
/// - 只清结果语音，不动轮次条目与文字结果
@MainActor
struct SpeechVaultCleaner {
    struct ClearResult: Equatable {
        let removed: Int
        let failed: Int
        let orphans: Int
        let vaultAvailable: Bool

        var userMessage: String {
            if !vaultAvailable {
                return "本机语音仓不可用"
            }
            if removed == 0, failed == 0 {
                return "没有可清除的语音"
            }
            var msg: String
            if failed == 0 {
                msg = "已清除 \(removed) 条结果语音"
            } else {
                msg = "\(removed) 条已清，\(failed) 条失败"
            }
            if orphans > 0 {
                msg += "（另清理 \(orphans) 个残留文件）"
            }
            return msg
        }

        var logDetail: String {
            if !vaultAvailable { return "vault_unavailable" }
            return "removed=\(removed) failed=\(failed) orphan=\(orphans)"
        }
    }

    private let journal: VoiceTurnJournal
    private let vault: EncryptedAudioVault?
    private let vaultDirectoryURL: URL
    private let fileManager: FileManager

    init(
        journal: VoiceTurnJournal,
        vault: EncryptedAudioVault?,
        vaultDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.journal = journal
        self.vault = vault
        self.vaultDirectoryURL = vaultDirectoryURL
        self.fileManager = fileManager
    }

    func clearHistorySpeech() -> ClearResult {
        guard let vault else {
            return ClearResult(removed: 0, failed: 0, orphans: 0, vaultAvailable: false)
        }

        let turns = journal.turns
        var removed = 0
        var failed = 0

        // 1. 遍历 turns，清除有 speechFileName 的语音（删后复核）
        if !turns.isEmpty {
            for turn in turns {
                guard let fileName = turn.speechFileName else { continue }
                vault.remove(name: fileName)
                if vault.contains(name: fileName) {
                    // 删后仍存在 → 删除失败，不清 journal
                    failed += 1
                } else {
                    // 确认不存在 → 计入成功，清 journal 引用
                    _ = journal.clearSpeech(requestId: turn.requestId, matching: fileName)
                    removed += 1
                }
            }
        }

        // 2. 扫描 vault 目录清 journal 已不引用的残留（删后复核）
        let referencedNames = Set(turns.compactMap { $0.speechFileName })
        var orphanCount = 0
        if let contents = try? fileManager.contentsOfDirectory(
            at: vaultDirectoryURL, includingPropertiesForKeys: nil
        ) {
            for url in contents {
                let name = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "sealed", !referencedNames.contains(name) else { continue }
                try? fileManager.removeItem(at: url)
                if fileManager.fileExists(atPath: url.path) {
                    // 删除失败，不计数
                    continue
                }
                orphanCount += 1
            }
        }

        return ClearResult(
            removed: removed,
            failed: failed,
            orphans: orphanCount,
            vaultAvailable: true
        )
    }
}
