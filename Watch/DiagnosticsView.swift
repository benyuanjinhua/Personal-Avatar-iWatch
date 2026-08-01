import SwiftUI

/// 诊断页（ESS-53 §3）：request_id、传输原始状态等调试信息从主链路移到这里，
/// 普通用户主屏零噪音；排障时从状态时间线底部进入。只读，不改任何状态。
struct DiagnosticsView: View {
    @ObservedObject var transport: WatchVoiceTransport
    @ObservedObject var journal: VoiceTurnJournal

    var body: some View {
        List {
            Section("传输通道") {
                LabeledContent("发送阶段", value: transport.phase.displayText)
                LabeledContent("待送达队列", value: "\(transport.pendingCount) 条")
            }

            if let remote = transport.remoteStatus {
                Section("Relay 原始状态") {
                    LabeledContent("phase", value: remote.phase.rawValue)
                    if let detail = remote.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(remote.requestId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            Section("最近请求") {
                if journal.turns.isEmpty {
                    Text("暂无")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(journal.turns.prefix(5)) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.requestId)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack {
                                Text(turn.currentState.rawValue)
                                Spacer()
                                Text(turn.createdAt, style: .time)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("App") {
                LabeledContent(
                    "版本",
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                )
            }
        }
        .font(.footnote)
        .navigationTitle("诊断")
    }
}
