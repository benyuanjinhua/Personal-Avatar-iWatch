import Combine
import Foundation

/// 欢迎语（ESS-40）：冷启动播放 qwen-audio-realtime 预生成的欢迎语音，
/// 验证下行音频链（Qwen 24kHz PCM → AudioPipe AAC/M4A → Watch 播放）。
/// 资产由 MacRemoteFrontendBridge/generate-welcome-speech.mjs 生成并预置
/// 在 App 包内（需求允许「下行分发或预置缓存」二选一）。
///
/// - 语音缺失/解码失败 → 静默降级为文字欢迎，不阻塞主界面；
/// - 同一进程会话只播一次；把 `wristagent.watch.welcome.every-entry`
///   置为 true 可改成每次进入都播（可配置开关）。
///
/// ESS-42 取证：全路径走统一 WatchLog（os.Logger + JSONL 回传），每次
/// 尝试生成 welcome-<uuidv7> 作为 request_id，资源查找/会话激活/路由/
/// play 结果/完成回调按同一 id 串成完整日志链。
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

    private let player = SpeechPlayer(instanceTag: "welcome")
    private let defaults: UserDefaults
    private var greetedThisSession = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 欢迎横幅是否还应占据主界面（播放中或文字降级展示期）。
    var isActive: Bool { stage == .playing || stage == .textOnly }

    /// 首次进入触发；同一会话内重复进入不重复播放（可配置放开）。
    func greetIfNeeded() {
        let everyEntry = defaults.bool(forKey: Self.everyEntryDefaultsKey)
        guard !greetedThisSession || everyEntry else {
            WatchLog.info(
                "welcome", "dedup_skip",
                detail: "greeted_this_session=\(greetedThisSession) every_entry=\(everyEntry)"
            )
            return
        }
        greetedThisSession = true
        let attemptId = "welcome-\(UUIDv7.generate().uuidString.lowercased())"
        WatchLog.info(
            "welcome", "greet_start", requestId: attemptId,
            detail: "greeted_this_session=false every_entry=\(everyEntry)"
        )

        guard let url = Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a") else {
            WatchLog.error(
                "welcome", "resource_missing", requestId: attemptId,
                detail: "WelcomeSpeech.m4a not in bundle \(Bundle.main.bundlePath)",
                code: "ERR_WELCOME_ASSET_MISSING"
            )
            fallBackToText()
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            WatchLog.error(
                "welcome", "resource_unreadable", requestId: attemptId,
                detail: url.path, code: "ERR_WELCOME_ASSET_UNREADABLE"
            )
            fallBackToText()
            return
        }
        let kind: AudioDownlinkKind = .welcome
        guard kind == .welcome else {
            WatchLog.error("audio", "l1_audio_rejected", requestId: attemptId, detail: "reason=unknown_kind source=welcome", code: "ERR_AUDIO_KIND_REJECTED")
            fallBackToText()
            return
        }
        WatchLog.info("welcome", "resource_found", requestId: attemptId, detail: "path=\(url.path) bytes=\(data.count)")
        stage = .playing
        let started = player.play(data: data, context: attemptId) { [weak self] finished in
            guard let self, self.stage == .playing else { return }
            // 欢迎语没有重播语义：截断也直接收尾，只留取证日志区分。
            WatchLog.info(
                "welcome", "playback_completed", requestId: attemptId,
                detail: "finished=\(finished)"
            )
            self.stage = .finished
            WatchLogShipper.shared.ship(reason: "welcome_completed")
        }
        if started {
            WatchLog.info("welcome", "playback_started", requestId: attemptId, detail: "bytes=\(data.count)")
        } else {
            // 失败环节由 SpeechPlayer 按同一 attemptId 落了具体 error；这里记降级决策。
            WatchLog.error(
                "welcome", "playback_start_failed", requestId: attemptId,
                detail: "fallback=text", code: "ERR_WELCOME_PLAYBACK_START"
            )
            fallBackToText()
        }
    }

    /// 用户开始按住说话时打断欢迎，绝不挡住真实链路。
    func interrupt() {
        guard isActive else { return }
        WatchLog.info("welcome", "interrupted_by_user")
        player.stop()
        stage = .finished
    }

    private func fallBackToText() {
        stage = .textOnly
        WatchLogShipper.shared.ship(reason: "welcome_fallback")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.stage == .textOnly { self?.stage = .finished }
        }
    }
}
