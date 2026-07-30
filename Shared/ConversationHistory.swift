import Combine
import Foundation

struct ConversationHistoryEntry: Codable, Equatable, Identifiable {
    let id: String
    let createdAt: Date
    let transcript: String
    let reply: String
    let risk: AgentRisk
    let state: AgentTaskState
    let taskID: String?

    var preview: String {
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "语音指令" : value
    }
}

@MainActor
final class ConversationHistoryStore: ObservableObject {
    @Published private(set) var entries: [ConversationHistoryEntry]

    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumCount: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "wristagent.conversation.history",
        maximumCount: Int = 50
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumCount = maximumCount
        entries = Self.load(defaults: defaults, storageKey: storageKey)
    }

    func upsert(_ entry: ConversationHistoryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            let original = entries[index]
            entries[index] = ConversationHistoryEntry(
                id: entry.id,
                createdAt: original.createdAt,
                transcript: entry.transcript,
                reply: entry.reply,
                risk: entry.risk,
                state: entry.state,
                taskID: entry.taskID
            )
        } else {
            entries.insert(entry, at: 0)
        }
        entries.sort { $0.createdAt > $1.createdAt }
        if entries.count > maximumCount {
            entries.removeLast(entries.count - maximumCount)
        }
        save()
    }

    func finish(taskID: String, state: AgentTaskState, reply: String) {
        guard let index = entries.firstIndex(where: { $0.taskID == taskID }) else { return }
        let current = entries[index]
        entries[index] = ConversationHistoryEntry(
            id: current.id,
            createdAt: current.createdAt,
            transcript: current.transcript,
            reply: reply,
            risk: current.risk,
            state: state,
            taskID: current.taskID
        )
        save()
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: storageKey)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(defaults: UserDefaults, storageKey: String) -> [ConversationHistoryEntry] {
        guard
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode([ConversationHistoryEntry].self, from: data)
        else {
            return []
        }
        return saved.sorted { $0.createdAt > $1.createdAt }
    }
}

enum HistoryMessage {
    static let key = "conversation_history"
}
