import AVFoundation
import Foundation
import WatchKit

/// ESS-519: Keeps the process alive in background during the voice-turn wait
/// phase by playing silent PCM audio on loop. The `audio` background mode
/// prevents process suspension when `WKExtendedRuntimeSession` is killed by
/// `.resignedFrontmost` (wrist-down / screen-off).
///
/// Without this, the `WKExtendedRuntimeSession` session type `.default` is
/// inherently killed by the system when the app resigns frontmost status, and
/// without an active audio session the process is suspended shortly after.
///
/// Lifecycle:
/// - `start()`: called after recording ends while app is still active.
///   Activates a `.playback` audio session and plays silent WAV on loop.
/// - `stop()`: called when real playback starts or the app becomes active
///   again. Releases the audio session.
///
/// ESS-603 所有权边界：本类改写的是**共享** `AVAudioSession`。当
/// `ConversationAudioController`（ESS-554）已按会话级持有该 session 时，
/// breather 必须完全让开——既不 `setCategory(.playback)`，也不
/// `setActive(false)`。见 `isSessionOwnedExternally`。
@MainActor
final class BackgroundAudioBreather {
    /// ESS-519 复审加固：静音保活的绝对上限。回合以非播放方式终结
    /// （失败 cue / 纯文本结果）或结果永远不到达时，若无人停 breather，
    /// 静音循环会在背景无限耗电。超过上限自动停止；此后的结果交付
    /// 降级到 ESS-55 的本地通知链路，不静默丢失。
    nonisolated static let defaultMaxDuration: TimeInterval = 120

    private let maxDuration: TimeInterval
    private var player: AVAudioPlayer?
    private let session: any ConversationAudioSessionDriving
    private var capTask: Task<Void, Never>?
    private(set) var isActive = false

    /// ESS-603：共享 `AVAudioSession` 此刻是否已被会话级 owner
    /// （`ConversationAudioController`）持有。
    ///
    /// 为什么必须让开：ESS-554 的契约是 conversation 期间由 controller 独占
    /// `.playAndRecord` 激活态，**只有显式退出（点 X）才 deactivate**。而
    /// App 自己改 category 不触发 interruption 通知，controller 的
    /// `isAcquired` 仍为 true —— 一旦 breather 把 session 翻成 `.playback`
    /// 再 `setActive(false)`，会话级播放引擎就挂在一个已失效的 session 上，
    /// 表现为回答音频无声且无自愈（ESS-598 的 L2 冲突链）。
    ///
    /// 会话模式下不启动 breather 不损失后台存活：controller 持有的
    /// `.playAndRecord` 本身就是活跃音频会话，`audio` 后台模式的保活效果
    /// 与 ESS-519 静音循环同源，无需第二份。
    ///
    /// 默认 `false` = ESS-519 原行为（普通 PTT / 会话开关关闭 / 会话
    /// acquire 失败降级），本单不改动那条路径。
    var isSessionOwnedExternally: () -> Bool = { false }

    init(
        maxDuration: TimeInterval = BackgroundAudioBreather.defaultMaxDuration,
        session: any ConversationAudioSessionDriving = AVAudioSession.sharedInstance()
    ) {
        self.maxDuration = maxDuration
        self.session = session
    }

    /// Start silent audio playback. Must be called while the app is still
    /// active — audio session activation fails in background (bridge.log
    /// evidence: scene_phase=background → session_activation_failed for both
    /// long_form and foreground policies).
    func start() {
        guard !isActive else { return }
        // ESS-603：会话级 owner 持有期间直接让开——放在 app 状态检查之前，
        // 让「没启动」的原因在日志里唯一可判（R-02.1 对账靠这条事件）。
        guard !isSessionOwnedExternally() else {
            WatchLog.info(
                "breather", "start_skipped",
                detail: "reason=conversation_audio_owned"
            )
            return
        }
        let appState = WKApplication.shared().applicationState
        guard appState == .active else {
            WatchLog.info(
                "breather", "start_skipped",
                detail: "reason=app_not_active state=\(Self.stateDescription(appState))"
            )
            return
        }
        let silentData = Self.makeSilentWAV()
        do {
            let p = try AVAudioPlayer(data: silentData)
            p.numberOfLoops = -1
            p.volume = 0
            try session.setCategory(.playback, mode: .default, policy: .default, options: [])
            try session.setActive(true, options: [])
            guard p.play() else {
                WatchLog.error(
                    "breather", "play_returned_false",
                    code: "ERR_BREATHER_PLAY"
                )
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            player = p
            isActive = true
            let cap = maxDuration
            capTask?.cancel()
            capTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stop(reason: "safety_cap")
            }
            WatchLog.info("breather", "started", detail: "sample_rate=8000 duration_s=2 loops=-1")
        } catch {
            WatchLog.error(
                "breather", "start_failed",
                detail: "error=\(error.localizedDescription)",
                error: error
            )
        }
    }

    /// Stop silent audio playback and release the audio session.
    ///
    /// ESS-603：`deactivated=false` 表示会话级 owner 在此期间接管了共享
    /// session——此时只停静音播放器，**不 deactivate**，把 session 留给
    /// owner（PD-2：只有显式退出才 deactivate）。
    func stop(reason: String = "explicit") {
        guard isActive else { return }
        capTask?.cancel()
        capTask = nil
        player?.stop()
        player = nil
        let deactivated = !isSessionOwnedExternally()
        if deactivated {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        isActive = false
        WatchLog.info(
            "breather", "stopped",
            detail: "reason=\(reason) deactivated=\(deactivated)"
        )
    }

    // MARK: - Silent WAV generation

    /// Generate a 2-second silent 16-bit mono PCM WAV at 8000 Hz.
    /// 8000 Hz minimises payload size (32 KB) while still being a valid
    /// PCM sample rate accepted by AVAudioPlayer on watchOS.
    static func makeSilentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let durationSec: Float64 = 2.0
        let numSamples = UInt32(Float64(sampleRate) * durationSec)
        let dataSize = numSamples * UInt32(bitsPerSample / 8)

        var wav = Data()
        wav.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        wav.append(contentsOf: "RIFF".utf8)
        var fileSize = UInt32(36 + dataSize).littleEndian
        wav.append(Data(bytes: &fileSize, count: 4))
        wav.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        wav.append(contentsOf: "fmt ".utf8)
        var fmtSize = UInt32(16).littleEndian
        wav.append(Data(bytes: &fmtSize, count: 4))
        var formatTag = UInt16(1).littleEndian  // PCM = 1
        wav.append(Data(bytes: &formatTag, count: 2))
        var chCount = channels.littleEndian
        wav.append(Data(bytes: &chCount, count: 2))
        var sr = sampleRate.littleEndian
        wav.append(Data(bytes: &sr, count: 4))
        var byteRate = UInt32(sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)).littleEndian
        wav.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(channels * bitsPerSample / 8).littleEndian
        wav.append(Data(bytes: &blockAlign, count: 2))
        var bps = bitsPerSample.littleEndian
        wav.append(Data(bytes: &bps, count: 2))

        // data sub-chunk
        wav.append(contentsOf: "data".utf8)
        var ds = dataSize.littleEndian
        wav.append(Data(bytes: &ds, count: 4))
        // All zeros = absolute silence (16-bit signed PCM, 0 = centre)
        wav.append(Data(count: Int(dataSize)))

        return wav
    }

    private static func stateDescription(_ state: WKApplicationState) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
