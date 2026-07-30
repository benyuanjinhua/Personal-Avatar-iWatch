import AppIntents

struct OpenWristAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "打开腕语"
    static let description = IntentDescription("打开腕语并开始一次语音 Agent 对话。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct WristAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenWristAgentIntent(),
            phrases: [
                "用 \(.applicationName) 开始对话",
                "打开 \(.applicationName)"
            ],
            shortTitle: "开始语音对话",
            systemImageName: "waveform.circle.fill"
        )
    }
}

