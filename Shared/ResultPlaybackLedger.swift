import Foundation

/// Persistent autoplay deduplication. A token is recorded before playback starts so a
/// crash/relaunch or duplicated WC transfer cannot make the same audio speak again.
///
/// ESS-182：一次回合的 interim 与 final 语音共用同一 request_id，内容却不同——
/// 因此 token 需带上语音内容的判别（`speechFileName` 已经是 `<requestId>-<sha>.m4a`
/// 形式，用它作 token 即可）。旧格式（裸 request_id）遗留条目对新的带扩展名 token
/// 天然不冲突，无需迁移，只是历史条目从此不再阻塞任何新播放。
final class ResultPlaybackLedger {
    private let fileURL: URL
    private var tokens: Set<String>

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("autoplayed-results.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Set<String>.self, from: data) {
            tokens = saved
        } else {
            tokens = []
        }
    }

    /// Returns true exactly once across process restarts for a given token. Persistence
    /// failure fails closed: avoiding surprise duplicate speech is safer than replaying
    /// an old answer.
    ///
    /// Callers should pass a token that discriminates *content*, not just the turn —
    /// use `speechFileName` (which encodes the audio sha) so interim and final of the
    /// same request_id each get their own claim.
    func claim(token: String) -> Bool {
        guard !tokens.contains(token) else { return false }
        tokens.insert(token)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(tokens)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }
}
