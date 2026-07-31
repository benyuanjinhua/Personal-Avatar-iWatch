import SwiftUI

struct PushToTalkView: View {
    @EnvironmentObject private var pushToTalk: PushToTalkController
    @ObservedObject private var transport: WatchVoiceTransport

    init(transport: WatchVoiceTransport) {
        self.transport = transport
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: isRecording ? [.white, .red, .orange] : [.white, .cyan, .blue],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 50
                        )
                    )
                    .frame(width: orbSize, height: orbSize)
                    .animation(.easeInOut(duration: 0.12), value: pushToTalk.recordingLevel)

                Image(systemName: isRecording ? "waveform" : "mic.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pushToTalk.pressBegan() }
                    .onEnded { _ in pushToTalk.pressEnded() }
            )

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if transport.pendingCount > 0 {
                Text("待送达 \(transport.pendingCount) 条")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("按住说话")
    }

    private var isRecording: Bool { pushToTalk.state == .recording }

    private var orbSize: CGFloat {
        isRecording ? 66 + CGFloat(pushToTalk.recordingLevel * 16) : 70
    }

    private var statusText: String {
        if let error = pushToTalk.errorMessage { return error }
        if isRecording { return "松开发送（最长 60 秒）" }
        return transport.phase.displayText
    }
}
