import Foundation

actor DemoAgentService: AgentServing {
    private var turn = 0

    func submit(audio: Data, conciseReply: Bool) async throws -> AgentTurnResponse {
        try await Task.sleep(for: .milliseconds(900))
        turn += 1
        switch turn % 4 {
        case 1:
            return AgentTurnResponse(
                turnID: UUID().uuidString,
                transcript: "我下午还有什么会？",
                reply: "下午有两场会议。最近一场是两点半的产品评审，四点还有周例会。",
                risk: .readOnly,
                state: .completed,
                taskID: nil,
                confirmation: nil,
                undo: nil,
                ttsAudioBase64: nil
            )
        case 2:
            return AgentTurnResponse(
                turnID: UUID().uuidString,
                transcript: "整理昨天项目群里的决定和待办。",
                reply: "任务已经开始，整理完成后会告诉你。",
                risk: .readOnly,
                state: .running,
                taskID: "demo-task",
                confirmation: nil,
                undo: nil,
                ttsAudioBase64: nil
            )
        case 3:
            return AgentTurnResponse(
                turnID: UUID().uuidString,
                transcript: "提醒我下午五点提交周报。",
                reply: "已创建下午五点提交周报的提醒。",
                risk: .reversible,
                state: .completed,
                taskID: nil,
                confirmation: nil,
                undo: AgentUndo(id: "demo-undo", label: "撤回提醒", expiresAt: nil),
                ttsAudioBase64: nil
            )
        default:
            return AgentTurnResponse(
                turnID: UUID().uuidString,
                transcript: "把刚才的总结发给项目群。",
                reply: "发送前请确认。",
                risk: .confirmationRequired,
                state: .running,
                taskID: nil,
                confirmation: AgentConfirmation(
                    id: "demo-confirmation",
                    title: "发送项目总结",
                    target: "飞船项目群 · 18 人",
                    impact: "群成员会立即收到 3 个决定和 4 个待办。",
                    actionLabel: "确认发送"
                ),
                undo: nil,
                ttsAudioBase64: nil
            )
        }
    }

    func confirm(id: String, approved: Bool) async throws -> AgentTurnResponse {
        try await Task.sleep(for: .milliseconds(600))
        return AgentTurnResponse(
            turnID: UUID().uuidString,
            transcript: "",
            reply: approved ? "已经发送到飞船项目群。" : "已取消发送。",
            risk: .confirmationRequired,
            state: approved ? .completed : .cancelled,
            taskID: nil,
            confirmation: nil,
            undo: nil,
            ttsAudioBase64: nil
        )
    }

    func task(id: String) async throws -> AgentTaskResponse {
        try await Task.sleep(for: .seconds(2))
        return AgentTaskResponse(
            taskID: id,
            state: .completed,
            reply: "整理完成：有三个决定和四个待办，完整结果已发送到 iPhone。"
        )
    }

    func undo(id: String) async throws -> AgentTurnResponse {
        try await Task.sleep(for: .milliseconds(400))
        return AgentTurnResponse(
            turnID: UUID().uuidString,
            transcript: "",
            reply: "提醒已撤回。",
            risk: .reversible,
            state: .cancelled,
            taskID: nil,
            confirmation: nil,
            undo: nil,
            ttsAudioBase64: nil
        )
    }

    func cancel(taskID: String) async {}
}
