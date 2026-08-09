import SwiftUI

/// ESS-572（Wave 0 / F7）：VoiceOrbView 五态映射 + 频率渐变动画。
///
/// 白梦林 PRD（ESS-540 F7 + §三·五）定义了 5 个会话态 → 球形态映射，
/// 且要求状态间频率渐变不跳变（§3.5.4）：
///
/// | 会话态      | 球形态          | 频率        | 说明                      |
/// |------------|----------------|------------|---------------------------|
/// | 待机 idle   | 静止/极缓       | 0.6 Hz     | 暗色，x 不显示             |
/// | 建立中       | 缓慢脉冲         | 0.6 Hz     | 通道未就绪时显示            |
/// | 聆听         | 随人声能量起伏    | 2.0 Hz     | 电平驱动波形条             |
/// | 思考         | 快速呼吸         | 1.3 Hz     | VAD 判定结束 → 首个分片到达 |
/// | 回答         | 随输出音频起伏    | 1.3 Hz     | AI 正在说话                |
///
/// 频率渐变：使用 `BreathingScale` 的 hertz 渐变能力，0.6→1.3Hz 之间
/// 自动插值过渡（easeInOut 300ms），突变会让用户误以为「卡了」。
///
/// 终态（completed / failed / cancelled）回到 idle，失败的可见证据由
/// `AvatarErrorCardView` 承担。
struct VoiceOrbView: View {
    enum Mode: Equatable {
        case idle
        case establishing
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
        .onChange(of: modeTag) { _, newTag in
            // AC-6: 每次状态切换落一条 WatchLog 事件
            let name = modeName(for: newTag)
            WatchLog.info("ui", "voice_orb_mode_changed",
                          detail: "target=\(name) mode_tag=\(newTag)")
        }
        .onAppear {
            let name = modeName(for: modeTag)
            WatchLog.info("ui", "voice_orb_mode_appeared",
                          detail: "target=\(name) mode_tag=\(modeTag)")
        }
    }

    private var listeningLevel: Float {
        if case .listening(let level) = mode { return level }
        return 0
    }

    private func modeName(for tag: Int) -> String {
        switch tag {
        case 0: return "idle"
        case 1: return "establishing"
        case 2: return "listening"
        case 3: return "thinking"
        case 4: return "speaking"
        default: return "unknown"
        }
    }

    /// 呼吸频率（Hz）—— ESS-572 F7 五态映射：
    /// idle=0.6 / establishing=0.6 / listening=2.0 / thinking=1.3 / speaking=1.3。
    /// 暴露为 `internal static` 以便 `VoiceOrbModeTests` 钉住频率表。
    static func breathHertz(for mode: Mode) -> Double {
        switch mode {
        case .idle: return 0.6
        case .establishing: return 0.6
        case .listening: return 2.0
        case .thinking: return 1.3
        case .speaking: return 1.3
        }
    }

    /// 呼吸幅度（缩放范围）—— establishing 比 idle 稍明显以传递「正在接通」。
    static func breathAmplitude(for mode: Mode) -> CGFloat {
        switch mode {
        case .idle: return 0.02
        case .establishing: return 0.04
        case .listening: return 0.08
        case .thinking: return 0.06
        case .speaking: return 0.06
        }
    }

    /// 每态的主色三段渐变。
    /// idle: 暗色宁静；establishing: 暖色连接感；
    /// thinking: 冷色（青蓝）；speaking: 暖（黄橙）；listening: 紫。
    private var colors: [Color] {
        switch mode {
        case .idle: return [.white, Color.gray.opacity(0.6), Color.blue.opacity(0.4)]
        case .establishing: return [.white, .orange.opacity(0.7), .orange.opacity(0.4)]
        case .listening: return [.white, .purple, .indigo]
        case .thinking: return [.white, .cyan, .blue]
        case .speaking: return [.white, .yellow, .orange]
        }
    }

    private var symbol: String { Self.symbolName(for: mode) }

    /// 每态图标（static 便于 WatchTests 直接钉住，无需渲染视图）。
    ///
    /// ESS-653 / 设计稿 v2.0 P0：待机图标 `mic.fill` → `phone.fill`——长按
    /// 语义移除后，「这不是按住说话」要在第一眼就成立，换图标是最低成本
    /// 的手段。
    static func symbolName(for mode: Mode) -> String {
        switch mode {
        case .idle: return "phone.fill"
        case .establishing: return "antenna.radiowaves.left.and.right"
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    /// `.animation(_:value:)` 需要 Equatable 且稳定的判别值。
    /// listening 电平变化不改变 modeTag，不触发转场动画重建（AC-4）。
    var modeTag: Int {
        switch mode {
        case .idle: return 0
        case .establishing: return 1
        case .listening: return 2
        case .thinking: return 3
        case .speaking: return 4
        }
    }
}

/// ESS-572：频率渐变动画 —— 状态切换时 hertz 不跳变，在 300ms 内
/// easeInOut 插值过渡（PRD §3.5.4：「频率渐变不得跳变」）。
///
/// **相位连续性（AC-7）**：不使用 wall-clock `timeIntervalSince1970` 直接
/// 乘 hertz（那会在 hertz 变化时导致相位跳变）。改为维护本地 `phase`
/// 累加器：每帧 `phase += currentHertz * dt`。hertz 变化只改变累加速率，
/// 不改变 phase 的值本身，保证过渡期间正弦输出连续性。
///
/// `currentHertz` 在 `onChange(of: hertz)` 时通过 Timer 驱动的
/// easeInOut ramp 平滑过渡。
private struct BreathingScale: ViewModifier {
    let hertz: Double
    let amplitude: CGFloat

    @State private var currentHertz: Double
    @State private var phase: Double = 0
    @State private var scale: CGFloat = 1.0
    @State private var tickTimer: Timer?
    @State private var lastTick: Date = Date()
    @State private var rampTimer: Timer?

    init(hertz: Double, amplitude: CGFloat) {
        self.hertz = hertz
        self.amplitude = amplitude
        self._currentHertz = State(initialValue: hertz)
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onAppear {
                currentHertz = hertz
                lastTick = Date()
                startTickTimer()
            }
            .onDisappear {
                tickTimer?.invalidate()
                tickTimer = nil
                rampTimer?.invalidate()
                rampTimer = nil
            }
            .onChange(of: hertz) { _, newHertz in
                rampTo(newHertz)
            }
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        let driver = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            let now = Date()
            let dt = now.timeIntervalSince(lastTick)
            lastTick = now
            phase += currentHertz * dt
            phase.formTruncatingRemainder(dividingBy: 1.0)
            scale = 1.0 + amplitude * CGFloat(sin(phase * 2 * .pi))
        }
        RunLoop.main.add(driver, forMode: .common)
        tickTimer = driver
    }

    /// 从当前频率 ramp 到目标频率，300ms easeInOut 插值。
    private func rampTo(_ target: Double) {
        rampTimer?.invalidate()
        let start = currentHertz
        let startTime = Date()
        let duration: TimeInterval = 0.3

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(startTime)
            let t = min(elapsed / duration, 1.0)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            currentHertz = start + (target - start) * eased
            if t >= 1.0 {
                timer.invalidate()
                rampTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
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
