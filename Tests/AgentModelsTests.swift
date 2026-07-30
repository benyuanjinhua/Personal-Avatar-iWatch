import Foundation
import Testing
@testable import WristAgentCore

@Test
func turnResponseUsesGatewaySnakeCaseKeys() throws {
    let response = AgentTurnResponse(
        turnID: "turn-1",
        transcript: "查一下日程",
        reply: "下午两场会",
        risk: .readOnly,
        state: .completed,
        taskID: "task-1",
        confirmation: nil,
        undo: nil,
        ttsAudioBase64: nil
    )

    let data = try JSONEncoder().encode(response)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["turn_id"] as? String == "turn-1")
    #expect(object["task_id"] as? String == "task-1")
    #expect(object["risk"] as? String == "read_only")
}

@Test
func cloudConfigurationRoundTrips() throws {
    let value = AgentConfiguration(
        mode: .cloud,
        endpoint: "https://agent.example.com",
        bearerToken: "secret",
        autoListen: true,
        hapticsEnabled: true,
        conciseReply: false
    )
    let decoded = try JSONDecoder().decode(
        AgentConfiguration.self,
        from: JSONEncoder().encode(value)
    )
    #expect(decoded == value)
}

@Test
func confirmationPayloadIsExplicit() throws {
    let value = AgentConfirmation(
        id: "confirm-1",
        title: "发送总结",
        target: "项目群",
        impact: "18 人会立即收到消息",
        actionLabel: "确认发送"
    )
    let decoded = try JSONDecoder().decode(
        AgentConfirmation.self,
        from: JSONEncoder().encode(value)
    )
    #expect(decoded == value)
}

@Test @MainActor
func conversationHistoryPersistsAndUpdatesLongTask() throws {
    let suiteName = "WristAgentCoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = ConversationHistoryStore(
        defaults: defaults,
        storageKey: "history",
        maximumCount: 10
    )
    store.upsert(
        ConversationHistoryEntry(
            id: "turn-1",
            createdAt: Date(timeIntervalSince1970: 100),
            transcript: "整理今天的会议",
            reply: "任务已开始",
            risk: .readOnly,
            state: .running,
            taskID: "task-1"
        )
    )
    store.finish(taskID: "task-1", state: .completed, reply: "已整理三场会议")

    let reloaded = ConversationHistoryStore(
        defaults: defaults,
        storageKey: "history",
        maximumCount: 10
    )
    let item = try #require(reloaded.entries.first)
    #expect(item.transcript == "整理今天的会议")
    #expect(item.reply == "已整理三场会议")
    #expect(item.state == .completed)
}

@Test @MainActor
func conversationHistoryKeepsNewestEntriesOnly() throws {
    let suiteName = "WristAgentCoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = ConversationHistoryStore(
        defaults: defaults,
        storageKey: "history",
        maximumCount: 2
    )
    for index in 1...3 {
        store.upsert(
            ConversationHistoryEntry(
                id: "turn-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                transcript: "指令 \(index)",
                reply: "回复 \(index)",
                risk: .readOnly,
                state: .completed,
                taskID: nil
            )
        )
    }

    #expect(store.entries.map(\.id) == ["turn-3", "turn-2"])
}
