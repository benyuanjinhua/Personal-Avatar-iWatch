import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var conversation: ConversationViewModel
    @EnvironmentObject private var settings: WatchSettingsStore
    @EnvironmentObject private var pushToTalk: PushToTalkController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    orb
                        .padding(.top, 4)

                    Text(conversation.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    Text(conversation.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)

                    if !conversation.transcript.isEmpty {
                        Text("“\(conversation.transcript)”")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.vertical, 2)
                    }

                    if let confirmation = conversation.confirmation {
                        confirmationCard(confirmation)
                    }

                    Button {
                        Task { await conversation.mainAction() }
                    } label: {
                        Text(conversation.mainButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(conversation.phase == .confirmation ? .orange : .cyan)

                    if conversation.canReject {
                        Button("取消操作", role: .cancel) {
                            Task { await conversation.answerConfirmation(approved: false) }
                        }
                        .font(.footnote)
                    }

                    if conversation.canUndo {
                        Button("撤回刚才的操作") {
                            Task { await conversation.undo() }
                        }
                        .font(.footnote)
                        .tint(.orange)
                    }

                    NavigationLink {
                        PushToTalkView(
                            transport: pushToTalk.transport,
                            journal: pushToTalk.journal,
                            player: pushToTalk.player
                        )
                    } label: {
                        Label("按住说话", systemImage: "mic.circle.fill")
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .tint(.cyan)

                    NavigationLink {
                        WatchHistoryListView(
                            entries: conversation.historyEntries,
                            onClear: conversation.clearHistory
                        )
                    } label: {
                        Label(
                            conversation.historyEntries.isEmpty
                                ? "历史对话"
                                : "历史对话 \(conversation.historyEntries.count)",
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .tint(.secondary)

                    if settings.configuration.mode == .demo {
                        Text("DEMO")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    /// 语音球统一由 VoiceOrbView 渲染（ESS-29）。
    private var orb: some View {
        VoiceOrbView(mode: orbMode, size: 62)
    }

    private var orbMode: VoiceOrbView.Mode {
        switch conversation.phase {
        case .idle: return .idle
        case .listening: return .listening(level: conversation.recordingLevel)
        case .understanding, .running: return .processing
        case .confirmation: return .confirmation
        case .completed: return .completed
        case .failed: return .failed
        }
    }

    @ViewBuilder
    private func confirmationCard(_ confirmation: AgentConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(confirmation.target, systemImage: "person.2.fill")
                .font(.caption.bold())
            Text(confirmation.impact)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }
}
