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
                        PushToTalkView(transport: pushToTalk.transport)
                    } label: {
                        Label("按住说话（PoC）", systemImage: "mic.circle.fill")
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

    private var orb: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: orbColors,
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 44
                    )
                )
                .frame(width: orbSize, height: orbSize)
                .shadow(color: orbColors.last?.opacity(0.55) ?? .clear, radius: 14)
                .animation(.easeInOut(duration: 0.12), value: conversation.recordingLevel)

            Image(systemName: orbSymbol)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: conversation.phase == .understanding || conversation.phase == .running)
        }
    }

    private var orbSize: CGFloat {
        conversation.phase == .listening
            ? 58 + CGFloat(conversation.recordingLevel * 16)
            : 62
    }

    private var orbColors: [Color] {
        switch conversation.phase {
        case .listening: return [.white, .purple, .indigo]
        case .confirmation: return [.yellow, .orange, .red]
        case .completed: return [.white, .green, .mint]
        case .failed: return [.white, .red, .pink]
        default: return [.white, .cyan, .blue]
        }
    }

    private var orbSymbol: String {
        switch conversation.phase {
        case .listening: return "waveform"
        case .understanding, .running: return "ellipsis"
        case .confirmation: return "exclamationmark"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        case .idle: return "sparkles"
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
