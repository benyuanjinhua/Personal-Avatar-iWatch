import Combine
import Foundation
import os

/// 欢迎语（ESS-40）：冷启动播放 qwen-audio-realtime 预生成的欢迎语音，
/// 验证下行音频链（Qwen 24kHz PCM → AudioPipe AAC/M4A → Watch 播放）。
/// 资产由 MacRemoteFrontendBridge/generate-welcome-speech.mjs 生成并预置
/// 在 App 包内（需求允许「下行分发或预置缓存」二选一）。
///
/// - 语音缺失/解码失败 → 静默降级为文字欢迎，不阻塞主界面；
/// - 同一进程会话只播一次；把 `wristagent.watch.welcome.every-entry`
///   置为 true 可改成每次进入都播（可配置开关）。
@MainActor
final class WelcomeGreeter: ObservableObject {
    static let welcomeText = "你好Jackson，我是你的AI分身"
    static let everyEntryDefaultsKey = "wristagent.watch.welcome.every-entry"

    enum Stage: Equatable {
        case pending
        case playing
        case textOnly
        case finished
    }

    @Published private(set) var stage: Stage = .pending

    // ESS-41 B3 取证：每个分支都留播放结果日志，真机上按 category 过滤即可
    // 逐项排除「资源缺失 / 会话激活失败 / 去重误判 / 播放器启动失败」。
    private static let logger = Logger(subsystem: "com.benyuan.wristagent.watch", category: "WelcomeGreeter")

    private let player = SpeechPlayer()
    private let defaults: UserDefaults
    private var greetedThisSession = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 欢迎横幅是否还应占据主界面（播放中或文字降级展示期）。
    var isActive: Bool { stage == .playing || stage == .textOnly }

    /// 首次进入触发；同一会话内重复进入不重复播放（可配置放开）。
    func greetIfNeeded() {
        guard !greetedThisSession || defaults.bool(forKey: Self.everyEntryDefaultsKey) else {
            Self.logger.info("greet skipped: already greeted this session")
            return
        }
        greetedThisSession = true

        guard let url = Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a") else {
            Self.logger.error("WelcomeSpeech.m4a missing from bundle → text fallback")
            fallBackToText()
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            Self.logger.error("WelcomeSpeech.m4a unreadable → text fallback")
            fallBackToText()
            return
        }
        stage = .playing
        let started = player.play(data: data) { [weak self] in
            guard let self, self.stage == .playing else { return }
            Self.logger.info("welcome playback completed")
            self.stage = .finished
        }
        if started {
            Self.logger.info("welcome playback started (bytes=\(data.count))")
        } else {
            Self.logger.error("welcome playback failed to start → text fallback")
            fallBackToText()
        }
    }

    /// 用户开始按住说话时打断欢迎，绝不挡住真实链路。
    func interrupt() {
        guard isActive else { return }
        player.stop()
        stage = .finished
    }

    private func fallBackToText() {
        stage = .textOnly
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.stage == .textOnly { self?.stage = .finished }
        }
    }
}
