import SwiftUI

/// 伴侣 App 诊断页（ESS-53 §3）：语音收件箱原始条目、request_id 等调试信息
/// 从主屏移到这里，主屏只留配置与连接状态。只读，不改任何状态。
struct CompanionDiagnosticsView: View {
    @EnvironmentObject private var connectivity: PhoneConnectivity

    var body: some View {
        Form {
            Section("语音收件箱（PoC）") {
                Label(connectivity.voiceStatus, systemImage: "waveform.circle")
                    .font(.footnote)
                ForEach(connectivity.voiceEntries.suffix(10).reversed()) { entry in
                    LabeledContent {
                        Text("\(entry.durationMs) ms · \(entry.sizeBytes / 1024) KB")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } label: {
                        Text(entry.requestId)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if !connectivity.voiceEntries.isEmpty {
                    LabeledContent("累计接收", value: "\(connectivity.voiceEntries.count) 条")
                }
            }

            Section("Mac Relay 原始状态") {
                Label(connectivity.relay.relayStatus, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.footnote)
                LabeledContent("事件通道", value: connectivity.relay.eventsConnected ? "已连接" : "未连接")
                    .font(.footnote)
                let queued = connectivity.relay.outboxEntries.filter { $0.state == .queued }
                LabeledContent("待上送", value: "\(queued.count) 条")
                    .font(.footnote)
            }
        }
        .navigationTitle("诊断（调试）")
    }
}
