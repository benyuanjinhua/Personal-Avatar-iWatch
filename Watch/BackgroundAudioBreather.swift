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
/// ESS-603 音频所有权：本器只在**无人持有会话**时才可动共享
/// `AVAudioSession`。会话级路径（ESS-554 `ConversationAudioController`，
/// gate ON）已把 `.playAndRecord` 全程激活并持有两个引擎，那既是
/// 保活来源也是播放来源——此时 breather 若 `setCategory(.playback)`
/// 就改写了 owner 的类别，若 `setActive(false)` 就替 owner 退了会话，
/// 直接导致回复无声。故 `isSessionOwnedExternally` 为真时：
/// 不启动、也不去激活。gate OFF / 普通 PTT 时该闭包恒 false，
/// ESS-519 行为逐字不变。
@MainActor
final class BackgroundAudioBreather {
    /// ESS-519 复审加固：静音保活的绝对上限。回合以非播放方式终结
    /// （失败 cue / 纯文本结果）或结果永远不到达时，若无人停 breather，
    /// 静音循环会在背景无限耗电。超过上限自动停止；此后的结果交付
    /// 降级到 ESS-55 的本地通知链路，不静默丢失。
    nonisolated static let defaultMaxDuration: TimeInterval = 120

    private let maxDuration: TimeInterval
    private var player: AVAudioPlayer?
    private var session: AVAudioSession { AVAudioSession.sharedInstance() }
    private var capTask: Task<Void, Never>?
    private(set) var isActive = false

    /// ESS-603：共享 `AVAudioSession` 是否已被会话级 owner
    /// （`ConversationAudioController`）持有。生产接线见
    /// `PushToTalkController.init`，与 `AudioRecorder.sessionManagedExternally`
    /// 同一口径；默认 false = 无 owner = ESS-519 原行为。
    var isSessionOwnedExternally: () -> Bool = { false }

    init(maxDuration: TimeInterval = BackgroundAudioBreather.defaultMaxDuration) {
        self.maxDuration = maxDuration
    }

    /// Start silent audio playback. Must be called while the app is still
    /// active — audio session activation fails in background (bridge.log
    /// evidence: scene_phase=background → session_activation_failed for both
    /// long_form and foreground policies).
    func start() {
        guard !isActive else { return }
        // ESS-603：会话级 owner 在场时不得启动——保活由它持有的
        // `.playAndRecord` 激活态提供，这里再动会话就是改写他人类别。
        guard !isSessionOwnedExternally() else {
            WatchLog.info(
                "breather", "start_skipped",
                detail: "reason=conversation_session_owned"
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
            try session.setCategory(.playback, mode: .default, policy: .default)
            try session.setActive(true)
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
    /// ESS-603：去激活只在**本器自己激活过会话**时发生。若会话级 owner
    /// 在我们启动之后接管（先起 breather 再进 conversation），本器仍要
    /// 停掉静音循环，但绝不能替 owner 调 `setActive(false)`——首帧回调
    /// `stop(reason: "realtime_playback")` 正是走这条路，一旦去激活，
    /// 回复音频当场失声。`deactivated=` 是该分支的可对账证据（R-02.1）。
    func stop(reason: String = "explicit") {
        guard isActive else { return }
        capTask?.cancel()
        capTask = nil
        player?.stop()
        player = nil
        let ownedExternally = isSessionOwnedExternally()
        if !ownedExternally {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        isActive = false
        WatchLog.info(
            "breather", "stopped",
            detail: "reason=\(reason) deactivated=\(!ownedExternally)"
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
