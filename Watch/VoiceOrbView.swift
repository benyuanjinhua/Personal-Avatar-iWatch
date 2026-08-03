import SwiftUI

/// ESS-180-B：语音球（Voice Orb）——只表达四态，且每态有专属呼吸节奏。
///
/// 白梦林拍板的三态：**等待输入 / 输入中 / 处理中**，各以不同呼吸动画为主；
/// 加上一个 speaking 态（AI 分身正在说话），仍走呼吸而非静止，用来跟输出
/// 音频节拍对齐。旧 VoiceOrbView 有 8 个子态（sending / delivered /
/// confirmation / completed / failed / cancelled 各占一格 icon），把
/// 「等待手机」「已送达」「处理中」等中间态展示成不同球，反而把「失败」
/// 淹没在这些成功中间态里——原始 bug（截图里的「仍在等 Mac」压过 failed）
/// 正是这样发生的。这里主动收敛到 4 态：
///
/// | 态         | 呼吸频率 | 中心视觉     | 触发                                   |
/// |-----------|--------|-------------|---------------------------------------|
/// | idle       | 0.9 Hz | 麦克图标      | 无进行中 turn                          |
/// | listening  | 2.0 Hz | 电平波形      | 用户按下、录音中                       |
/// | thinking   | 1.3 Hz | 省略号        | accepted → completed/failed 之前的所有中间态 |
/// | speaking   | 1.3 Hz | 扬声器        | player.isPlaying = true               |
///
/// 呼吸动画统一封装在 `BreathingScale` modifier 里，禁止在球体内部内联新
/// 版本——否则复审直接打回。终态（completed / failed / cancelled）**不再
/// 用不同球体显示**，改由 `AvatarErrorCardView` 与结果卡片承担；球体回到
/// idle 态，避免屏幕上同一时刻出现两个矛盾的可视终态。
struct VoiceOrbView: View {
    enum Mode: Equatable {
        case idle
        case listening(level: Float)
        case thinking
        case speaking
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
                .frame(width: size, height: size)
                .shadow(color: colors.last?.opacity(0.55) ?? .clear, radius: size * 0.2)
                .modifier(BreathingScale(hertz: Self.breathHertz(for: mode),
                                         amplitude: Self.breathAmplitude(for: mode)))

            if case .listening = mode {
                WaveformBars(level: listeningLevel)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.3, weight: .bold))
                    .foregroundStyle(.white)
                    .modifier(BreathingScale(hertz: Self.breathHertz(for: mode),
                                             amplitude: Self.breathAmplitude(for: mode) * 0.3))
            }
        }
        .frame(width: size + 16, height: size + 16)
        .animation(.easeInOut(duration: 0.18), value: modeTag)
    }

    private var listeningLevel: Float {
        if case .listening(let level) = mode { return level }
        return 0
    }

    /// 呼吸频率（Hz）——白梦林规格里 idle=0.9 / listening=2 / thinking=1.3 / speaking=1.3。
    /// 暴露为 `internal static` 以便 `VoiceOrbModeTests` 钉住频率表；改数字前先看那份测试。
    static func breathHertz(for mode: Mode) -> Double {
        switch mode {
        case .idle: return 0.9
        case .listening: return 2.0
        case .thinking: return 1.3
        case .speaking: return 1.3
        }
    }

    /// 呼吸幅度（缩放范围）——listening 更明显以配合波形；idle 最柔和。
    static func breathAmplitude(for mode: Mode) -> CGFloat {
        switch mode {
        case .idle: return 0.03
        case .listening: return 0.08
        case .thinking: return 0.06
        case .speaking: return 0.06
        }
    }

    /// 每态的主色三段渐变。冷暖流转：thinking 走冷色（青蓝），speaking 转暖（黄橙）；
    /// listening 用紫，与 idle 的蓝明确区分。
    private var colors: [Color] {
        switch mode {
        case .idle: return [.white, .cyan, .blue]
        case .listening: return [.white, .purple, .indigo]
        case .thinking: return [.white, .cyan, .blue]
        case .speaking: return [.white, .yellow, .orange]
        }
    }

    private var symbol: String {
        switch mode {
        case .idle: return "mic.fill"
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    /// `.animation(_:value:)` 需要 Equatable 且稳定的判别值；listening 电平
    /// 随时间变化不应触发重建，用一个粗粒度 tag。
    private var modeTag: Int {
        switch mode {
        case .idle: return 0
        case .listening: return 1
        case .thinking: return 2
        case .speaking: return 3
        }
    }
}

/// 统一呼吸动画：正弦式缓入缓出的自动往返。频率 Hz + 振幅决定节奏；
/// SwiftUI 的 `.repeatForever(autoreverses:)` 组合足以覆盖，不需要
/// TimelineView，也不吃 CPU。旋钮集中在此，全 App 呼吸口径一致。
private struct BreathingScale: ViewModifier {
    let hertz: Double
    let amplitude: CGFloat
    @State private var expanded = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(expanded ? 1 + amplitude : 1 - amplitude)
            .animation(
                .easeInOut(duration: max(0.15, 0.5 / hertz))
                    .repeatForever(autoreverses: true),
                value: expanded
            )
            .onAppear { expanded = true }
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
