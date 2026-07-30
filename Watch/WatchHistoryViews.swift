import SwiftUI

struct WatchHistoryListView: View {
    let entries: [ConversationHistoryEntry]
    let onClear: () -> Void

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "暂无对话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("完成一次语音对话后会显示在这里")
                )
            } else {
                List {
                    ForEach(entries) { entry in
                        NavigationLink {
                            WatchHistoryDetailView(entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.preview)
                                    .font(.footnote.bold())
                                    .lineLimit(2)
                                HStack(spacing: 4) {
                                    Image(systemName: entry.state.historySymbol)
                                    Text(entry.createdAt, style: .time)
                                }
                                .font(.caption2)
                                .foregroundStyle(entry.state.historyColor)
                            }
                        }
                    }

                    Button("清空历史", role: .destructive, action: onClear)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("历史对话")
    }
}

struct WatchHistoryDetailView: View {
    let entry: ConversationHistoryEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label(entry.state.historyTitle, systemImage: entry.state.historySymbol)
                    .font(.headline)
                    .foregroundStyle(entry.state.historyColor)

                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                historyBlock(title: "你说", text: entry.preview, color: .cyan)
                historyBlock(
                    title: "腕语",
                    text: entry.reply.isEmpty ? "等待执行结果" : entry.reply,
                    color: .purple
                )

                Label(entry.risk.displayName, systemImage: "shield.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .navigationTitle("对话详情")
    }

    private func historyBlock(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(color)
            Text(text)
                .font(.footnote)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension AgentTaskState {
    var historyTitle: String {
        switch self {
        case .completed: return "已完成"
        case .running: return "执行中"
        case .failed: return "未完成"
        case .cancelled: return "已取消"
        }
    }

    var historySymbol: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .running: return "ellipsis.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    var historyColor: Color {
        switch self {
        case .completed: return .green
        case .running: return .orange
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
