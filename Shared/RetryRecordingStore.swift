import Foundation

/// ESS-55 一键重试：失败后重发不需要用户重新说话。
/// 只保留最近一条录音（音频 + 时长），失败时用它换新 request_id 重发；
/// 回合走到 completed/cancelled 即清理（交付后删除，与语音仓同一原则）。
final class RetryRecordingStore {
    struct Stored: Equatable {
        let data: Data
        let durationMs: Int
    }

    private struct Meta: Codable {
        let requestId: String
        let durationMs: Int
    }

    private let audioURL: URL
    private let metaURL: URL
    private let fileManager = FileManager.default

    init(directory: URL) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        audioURL = directory.appendingPathComponent("last-recording.m4a")
        metaURL = directory.appendingPathComponent("last-recording.json")
    }

    /// 保存/改绑最近一条录音（覆盖旧的，只留一条）。
    func save(requestId: String, data: Data, durationMs: Int) {
        guard
            (try? data.write(to: audioURL, options: .atomic)) != nil,
            let metaData = try? JSONEncoder().encode(Meta(requestId: requestId, durationMs: durationMs)),
            (try? metaData.write(to: metaURL, options: .atomic)) != nil
        else {
            clearAll()
            return
        }
    }

    /// 重试改绑到新 request_id：音频不动，只换归属。
    func rebind(to requestId: String) {
        guard let meta = loadMeta() else { return }
        guard let metaData = try? JSONEncoder().encode(Meta(requestId: requestId, durationMs: meta.durationMs)) else { return }
        try? metaData.write(to: metaURL, options: .atomic)
    }

    /// 该回合的录音（不匹配或已清理则 nil）。
    func stored(for requestId: String) -> Stored? {
        guard
            let meta = loadMeta(),
            meta.requestId == requestId,
            let data = try? Data(contentsOf: audioURL),
            !data.isEmpty
        else { return nil }
        return Stored(data: data, durationMs: meta.durationMs)
    }

    /// 回合成功交付/取消后清理；requestId 不匹配时不动（新回合已覆盖）。
    func clear(requestId: String) {
        guard loadMeta()?.requestId == requestId else { return }
        clearAll()
    }

    func clearAll() {
        try? fileManager.removeItem(at: audioURL)
        try? fileManager.removeItem(at: metaURL)
    }

    private func loadMeta() -> Meta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }
}
