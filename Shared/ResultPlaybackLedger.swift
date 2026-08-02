import Foundation

/// Persistent autoplay deduplication. A request is recorded before playback starts so a
/// crash/relaunch or duplicated WC transfer cannot make an old answer speak again.
final class ResultPlaybackLedger {
    private let fileURL: URL
    private var requestIds: Set<String>

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("autoplayed-results.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Set<String>.self, from: data) {
            requestIds = saved
        } else {
            requestIds = []
        }
    }

    /// Returns true exactly once across process restarts. Persistence failure fails closed:
    /// avoiding surprise duplicate speech is safer than replaying an old answer.
    func claim(requestId: String) -> Bool {
        guard !requestIds.contains(requestId) else { return false }
        requestIds.insert(requestId)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(requestIds)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }
}
