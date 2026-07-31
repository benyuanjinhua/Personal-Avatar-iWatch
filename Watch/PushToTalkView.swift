import SwiftUI

/// 语音主界面（ESS-29）：按住说话 + 当前回合状态投影 + 权限确认 + 结果播放 + 状态时间线。
/// 半双工：录完即传；退出本页任务继续，重开从 VoiceTurnJournal 恢复。
struct PushToTalkView: View {
    @EnvironmentObject private var pushToTalk: PushToTalkController
    @ObservedObject private var transport: WatchVoiceTransport
    @ObservedObject private var journal: VoiceTurnJournal
    @ObservedObject private var player: SpeechPlayer

    init(transport: WatchVoiceTransport, journal: VoiceTurnJournal, player: SpeechPlayer) {
        self.transport = transport
        self.journal = journal
        self.player = player
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                VoiceOrbView(mode: orbMode, size: 70)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in pushToTalk.pressBegan() }
                            .onEnded { _ in pushToTalk.pressEnded() }
                    )

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
        .navigationTitle("按住说话")
        .onChange(of: journal.activeTurn?.speechFileName) { _, fileName in
            // 结果语音到达时自动播放一次（播放即交付，随后删除密文文件）。
            guard fileName != nil, let turn = journal.activeTurn else { return }
            pushToTalk.playResult(for: turn)
        }
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
        }
        .padding(9)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 投影

    private var isRecording: Bool { pushToTalk.state == .recording }

    private var activeTurn: VoiceTurnRecord? { journal.activeTurn }

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
        guard let turn = activeTurn else { return "按住说话" }
        return turn.phase.title
    }

    private var statusSubtitle: String {
        if isRecording { return "松开发送（最长 60 秒）" }
        if case .failed(let message) = transport.phase { return message }
        guard let turn = activeTurn else { return "松开即发送，结果回来会响铃" }
        return turn.phase.subtitle
    }
}
