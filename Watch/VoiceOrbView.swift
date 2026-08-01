import SwiftUI

/// 语音球（ESS-29）：复刻 H5 原型的渐变光球 + 波形视觉。
/// H5 仅作设计参照，这里是原生 SwiftUI 实现（watchOS 无 PWA/WKWebView 容器）。
struct VoiceOrbView: View {
    enum Mode: Equatable {
        case idle
        case listening(level: Float)
        case waiting
        case processing
        case confirmation
        case completed
        case failed
        case cancelled
    }

    var mode: Mode
    var size: CGFloat = 70

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: colors,
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: size * 0.72
                    )
                )
                .frame(width: currentSize, height: currentSize)
                .shadow(color: colors.last?.opacity(0.55) ?? .clear, radius: size * 0.2)
                .animation(.easeInOut(duration: 0.12), value: level)

            if case .listening = mode {
                WaveformBars(level: level)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.3, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: isPulsing)
            }
        }
        .frame(width: size + 16, height: size + 16)
    }

    private var level: Float {
        if case .listening(let level) = mode { return level }
        return 0
    }

    private var currentSize: CGFloat {
        if case .listening = mode {
            return size * 0.94 + CGFloat(level) * size * 0.24
        }
        return size
    }

    private var isPulsing: Bool {
        mode == .processing || mode == .waiting
    }

    private var colors: [Color] {
        switch mode {
        case .idle: return [.white, .cyan, .blue]
        case .listening: return [.white, .purple, .indigo]
        case .waiting: return [.white, .teal, .blue]
        case .processing: return [.white, .cyan, .blue]
        case .confirmation: return [.yellow, .orange, .red]
        case .completed: return [.white, .green, .mint]
        case .failed: return [.white, .red, .pink]
        case .cancelled: return [.white, .gray, Color(white: 0.35)]
        }
    }

    private var symbol: String {
        switch mode {
        case .idle: return "mic.fill"
        case .listening: return "waveform"
        case .waiting: return "clock"
        case .processing: return "ellipsis"
        case .confirmation: return "exclamationmark"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        case .cancelled: return "minus"
        }
    }
}

/// 录音时随音量起伏的波形条（H5 波形的原生复刻）。
private struct WaveformBars: View {
    let level: Float

    private static let profiles: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.55]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.profiles.enumerated()), id: \.offset) { _, profile in
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: 8 + profile * CGFloat(level) * 26)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: level)
    }
}
