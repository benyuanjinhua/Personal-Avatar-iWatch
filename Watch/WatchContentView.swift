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
                        ConversationTimelineView(journal: journal, transport: transport)
                    } label: {
                        Label("状态时间线", systemImage: "list.bullet.rectangle")
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    // Relay 原始状态行已移入诊断页（ESS-53 §3）：主屏只留人话状态。
                }
                .padding(.horizontal, 6)
            }
        }
        // 结果语音的自动播放已下沉到 PushToTalkController（journal.onSpeechAttached
        // 按 request_id 定向触发，ESS-41 B3）：不再依赖本视图挂载或该回合仍是
        // activeTurn——旧的 onChange 触发在「语音后到 + 回合已切换/已判失败」时
        // 会静默漏播。
        // 字幕式播放视图（ESS-48）：播放开始/纯文本结果到达时由控制器置入会话。
        .sheet(item: $pushToTalk.subtitleSession) { session in
            SubtitlePlaybackView(session: session, player: pushToTalk.player) {
                pushToTalk.replayResult(requestId: session.requestId)
            }
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

        if turn.currentState == .failed {
            failureCard(turn)
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

    /// 失败卡片（ESS-53 §5）：失败不能只有红叉——原因 + 差异化恢复动作。
    @ViewBuilder
    private func failureCard(_ turn: VoiceTurnRecord) -> some View {
        let stage = turn.failureStage ?? .execution
        VStack(alignment: .leading, spacing: 4) {
            Label(stage.displayName, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.bold())
                .foregroundStyle(.red)

            Text(stage.recoveryHint)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // 录音还压在待送达队列里（手机不可达型失败）：给一键重试，
            // request_id 不变、接收端幂等，触发 outbox 重新提交。
            if stage == .phoneUnreachable && transport.pendingCount > 0 {
                Button {
                    transport.retryPending()
                } label: {
                    Label("立即重试", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .font(.footnote)
            }
        }
        .padding(9)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
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

            // 播放/暂停/继续/重播（ESS-53 §6）：播完加密仓已删仍可从内存缓存重播。
            if pushToTalk.hasPlayableAudio(for: turn) {
                Button {
                    pushToTalk.togglePlayback(for: turn)
                } label: {
                    Label(playbackButtonTitle(for: turn), systemImage: playbackButtonIcon(for: turn))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .font(.footnote)
            }

            // 回看入口（ESS-48）：语音播完（音频交付后已删）仍可完整查看全文。
            if !result.displaySummary.isEmpty {
                Button {
                    pushToTalk.showTranscript(for: turn)
                } label: {
                    Label("查看全文", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .font(.footnote)
            }
        }
        .padding(9)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 投影

    private func playbackButtonTitle(for turn: VoiceTurnRecord) -> String {
        if player.progress(matching: turn.requestId) != nil {
            return player.isPlaying ? "暂停" : "继续播放"
        }
        return turn.speechFileName != nil ? "播放语音" : "重播"
    }

    private func playbackButtonIcon(for turn: VoiceTurnRecord) -> String {
        if player.progress(matching: turn.requestId) != nil {
            return player.isPlaying ? "pause.circle.fill" : "play.circle.fill"
        }
        return turn.speechFileName != nil ? "play.circle.fill" : "arrow.counterclockwise.circle.fill"
    }

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
