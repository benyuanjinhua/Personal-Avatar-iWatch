import Combine
import Foundation
import WatchKit

@MainActor
final class ConversationViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case understanding
        case running
        case confirmation
        case completed
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var title = "有什么要我做？"
    @Published private(set) var detail = "点一下，然后直接说"
    @Published private(set) var transcript = ""
    @Published private(set) var confirmation: AgentConfirmation?
    @Published private(set) var pendingUndo: AgentUndo?
    @Published private(set) var recordingLevel: Float = 0
    @Published private(set) var historyEntries: [ConversationHistoryEntry]

    private let recorder = AudioRecorder()
    private let player = SpeechPlayer()
    private let historyStore: ConversationHistoryStore
    private var service: AgentServing = DemoAgentService()
    private var configuration: AgentConfiguration = .demo
    private var activeTaskID: String?
    private var pollingTask: Task<Void, Never>?

    var mainButtonTitle: String {
        switch phase {
        case .idle, .completed, .failed: return "开始说话"
        case .listening: return "说完了"
        case .understanding, .running: return "取消"
        case .confirmation: return "确认执行"
        }
    }

    var canReject: Bool { phase == .confirmation }
    var canUndo: Bool { phase == .completed && pendingUndo != nil }

    init(historyStore: ConversationHistoryStore? = nil) {
        let resolvedHistoryStore = historyStore ?? ConversationHistoryStore(
            storageKey: "wristagent.watch.conversation.history"
        )
        self.historyStore = resolvedHistoryStore
        historyEntries = resolvedHistoryStore.entries

        recorder.$level
            .receive(on: RunLoop.main)
            .assign(to: &$recordingLevel)

        resolvedHistoryStore.$entries
            .receive(on: RunLoop.main)
            .assign(to: &$historyEntries)
    }

    func configure(with value: AgentConfiguration) {
        configuration = value
        if value.mode == .demo {
            service = DemoAgentService()
        } else {
            do {
                service = try CloudAgentService(configuration: value)
            } catch {
                service = UnavailableAgentService(error: error)
            }
        }
    }

    func mainAction() async {
        switch phase {
        case .idle, .completed, .failed:
            await startListening()
        case .listening:
            await finishListening()
        case .understanding, .running:
            await cancel()
        case .confirmation:
            await answerConfirmation(approved: true)
        }
    }

    func startListening() async {
        pollingTask?.cancel()
        player.stop()
        confirmation = nil
        pendingUndo = nil
        transcript = ""
        do {
            try await recorder.start()
            phase = .listening
            title = "我在听"
            detail = "说完后点一下"
            haptic(.start)
        } catch {
            fail(error)
        }
    }

    func finishListening() async {
        do {
            let audio = try recorder.stop()
            phase = .understanding
            title = "正在听懂"
            detail = "语音已收到"
            haptic(.click)

            let response = try await service.submit(
                audio: audio,
                conciseReply: configuration.conciseReply
            )
            apply(response)
        } catch {
            fail(error)
        }
    }

    func answerConfirmation(approved: Bool) async {
        guard let confirmation else { return }
        phase = .running
        title = approved ? "正在执行" : "正在取消"
        detail = confirmation.title
        do {
            let response = try await service.confirm(id: confirmation.id, approved: approved)
            self.confirmation = nil
            apply(response)
        } catch {
            fail(error)
        }
    }

    func undo() async {
        guard let pendingUndo else { return }
        phase = .running
        title = "正在撤回"
        detail = pendingUndo.label
        do {
            let response = try await service.undo(id: pendingUndo.id)
            self.pendingUndo = nil
            apply(response)
        } catch {
            fail(error)
        }
    }

    func cancel() async {
        recorder.cancel()
        player.stop()
        pollingTask?.cancel()
        if let activeTaskID { await service.cancel(taskID: activeTaskID) }
        activeTaskID = nil
        phase = .idle
        title = "已取消"
        detail = "需要时再叫我"
        haptic(.stop)
    }

    func clearHistory() {
        historyStore.clear()
    }

    private func apply(_ response: AgentTurnResponse) {
        transcript = response.transcript
        historyStore.upsert(
            ConversationHistoryEntry(
                id: response.turnID,
                createdAt: Date(),
                transcript: response.transcript,
                reply: response.reply,
                risk: response.risk,
                state: response.state,
                taskID: response.taskID
            )
        )
        if response.risk == .confirmationRequired, response.confirmation == nil,
           response.state != .completed, response.state != .cancelled {
            fail(AgentServiceError.invalidResponse)
            return
        }
        if let confirmation = response.confirmation {
            self.confirmation = confirmation
            phase = .confirmation
            title = confirmation.title
            detail = confirmation.target
            player.speak("发送前请确认。\(confirmation.target)")
            haptic(.notification)
            return
        }

        if response.state == .running, let taskID = response.taskID {
            activeTaskID = taskID
            phase = .running
            title = "任务已开始"
            detail = response.reply
            player.speak(response.reply, cloudAudioBase64: response.ttsAudioBase64)
            poll(taskID: taskID)
            return
        }

        phase = response.state == .failed ? .failed : .completed
        pendingUndo = response.undo
        title = response.state == .failed ? "没有完成" : "完成了"
        detail = response.reply
        player.speak(response.reply, cloudAudioBase64: response.ttsAudioBase64)
        haptic(response.state == .failed ? .failure : .success)
    }

    private func poll(taskID: String) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<12 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(2))
                do {
                    let result = try await self.service.task(id: taskID)
                    guard result.state != .running else { continue }
                    self.activeTaskID = nil
                    if result.state == .completed {
                        self.phase = .completed
                        self.title = "任务完成"
                        self.detail = result.reply ?? "已完成"
                        self.historyStore.finish(
                            taskID: taskID,
                            state: .completed,
                            reply: result.reply ?? "已完成"
                        )
                        self.player.speak(result.reply ?? "任务已完成")
                        self.haptic(.success)
                    } else {
                        self.phase = .failed
                        self.title = "任务没有完成"
                        self.detail = result.reply ?? "请稍后重试"
                        self.historyStore.finish(
                            taskID: taskID,
                            state: result.state,
                            reply: result.reply ?? "请稍后重试"
                        )
                        self.haptic(.failure)
                    }
                    return
                } catch {
                    if Task.isCancelled { return }
                }
            }
            self.phase = .running
            self.title = "仍在云端执行"
            self.detail = "完成后会通知你"
        }
    }

    private func fail(_ error: Error) {
        phase = .failed
        title = "暂时没完成"
        detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        haptic(.failure)
    }

    private func haptic(_ type: WKHapticType) {
        guard configuration.hapticsEnabled else { return }
        WKInterfaceDevice.current().play(type)
    }
}
