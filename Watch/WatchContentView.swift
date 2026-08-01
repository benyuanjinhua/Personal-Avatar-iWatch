import SwiftUI

/// 主界面（ESS-40）：首屏即「按住说话」真实链路（ESS-29 PoC 转正，静态 demo 已删除）。
/// 要素：语音球 + 状态文案 + 按住说话手势 + 结果时间线入口 + 欢迎语（下行音频链验证）。
/// 半双工：录完即传；退出 App 任务继续，重开从 VoiceTurnJournal 恢复。
struct WatchContentView: View {
    @ObservedObject private var pushToTalk: PushToTalkController
    @ObservedObject private var welcome: WelcomeGreeter
    @ObservedObject private var transport: WatchVoiceTransport
    @ObservedObject private var journal: VoiceTurnJournal
    @ObservedObject private var player: SpeechPlayer

    init(pushToTalk: PushToTalkController, welcome: WelcomeGreeter) {
        self.pushToTalk = pushToTalk
        self.welcome = welcome
        self.transport = pushToTalk.transport
        self.journal = pushToTalk.journal
        self.player = pushToTalk.player
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    VoiceOrbView(mode: orbMode, size: 70)
                        .padding(.top, 4)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    welcome.interrupt()
                                    pushToTalk.pressBegan()
                                }
                                .onEnded { _ in pushToTalk.pressEnded() }
                        )

                    if showWelcomeBanner {
                        welcomeBanner
                    }

                    Text(statusTitle)
                        .font(.footnote.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    Text(statusSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    if transport.pendingCount > 0 {
                        Text("待送达 \(transport.pendingCount) 条")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if let turn = activeTurn {
                        turnContent(turn)
                    }

                    NavigationLink {
                        ConversationTimelineView(journal: journal)
                    } label: {
                        Label("状态时间线", systemImage: "list.bullet.rectangle")
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .tint(.secondary)

                    if let remote = transport.remoteStatus {
                        Text(remote.detail ?? remote.phase.displayText)
                            .font(.caption2)
                            .foregroundStyle(remote.phase == .failed ? .red : .secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .onChange(of: journal.activeTurn?.speechFileName) { _, fileName in
            // 结果语音到达时自动播放一次；密文保留（退出重进可重播），
            // 由保留期清理兜底（ESS-38 复测：失败不清文件、不静默）。
            guard fileName != nil, let turn = journal.activeTurn else { return }
            welcome.interrupt()
            pushToTalk.playResult(for: turn)
        }
    }

    // MARK: - 欢迎语（ESS-40）

    private var showWelcomeBanner: Bool {
        welcome.isActive && !isRecording && activeTurn == nil
    }

    private var welcomeBanner: some View {
        VStack(spacing: 3) {
            Text(WelcomeGreeter.welcomeText)
                .font(.footnote.bold())
                .multilineTextAlignment(.center)

            if welcome.stage == .playing {
                Label("欢迎语播放中", systemImage: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 当前回合区块

    @ViewBuilder
    private func turnContent(_ turn: VoiceTurnRecord) -> some View {
        if turn.currentState == .permissionRequired, let permission = turn.permission {
            PermissionRequestView(
                permission: permission,
                decision: turn.permissionApproved
            ) { approved in
                pushToTalk.respondPermission(approved: approved)
            }
        }

        if let result = turn.result, turn.currentState == .completed {
            resultCard(turn: turn, result: result)
        }

        if turn.isActive && !isRecording && turn.currentState != .permissionRequired {
            Button("取消本次请求", role: .cancel) {
                pushToTalk.cancelActiveTurn()
            }
            .font(.caption2)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultCard(turn: VoiceTurnRecord, result: VoiceResultPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.displaySummary)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)

            if result.displayIsTruncated {
                Text("已截断，完整内容在 Mac 上")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if turn.speechFileName != nil {
                Button {
                    pushToTalk.playResult(for: turn)
                } label: {
                    Label(
                        player.isPlaying ? "播放中…" : "播放语音",
                        systemImage: player.isPlaying ? "speaker.wave.2.fill" : "play.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .font(.footnote)
                .disabled(player.isPlaying)
            }

            // 语音失败必须可观测：保留文本降级的同时给出失败原因（可重试）。
            if let playbackError = player.lastError {
                Text(playbackError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .padding(9)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 投影

    private var isRecording: Bool { pushToTalk.state == .recording }

    private var activeTurn: VoiceTurnRecord? { journal.activeTurn }

    private var isSpeaking: Bool {
        player.isPlaying || welcome.stage == .playing
    }

    private var orbMode: VoiceOrbView.Mode {
        if isRecording { return .listening(level: pushToTalk.recordingLevel) }
        guard let phase = activeTurn?.phase else { return .idle }
        switch phase {
        case .sending, .waitingForPhone, .waitingForMac: return .waiting
        case .delivered, .processing: return .processing
        case .needsConfirmation: return .confirmation
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .idle
        }
    }

    private var statusTitle: String {
        if let error = pushToTalk.errorMessage { return error }
        if isRecording { return "我在听" }
        if isSpeaking { return "播放中" }
        guard let turn = activeTurn else { return "按住说话" }
        return turn.phase.title
    }

    private var statusSubtitle: String {
        if isRecording { return "松开发送（最长 60 秒）" }
        if case .failed(let message) = transport.phase { return message }
        if showWelcomeBanner { return "按住语音球开始对话" }
        guard let turn = activeTurn else { return "松开即发送，结果回来会响铃" }
        return turn.phase.subtitle
    }
}
