import Combine
import Foundation
import WatchKit

/// ESS-45：语音会话期间保持 App 存活，降腕/熄屏不中断等待与播放。
/// - 录音 / 回合等待 / 播放期间持有 WKExtendedRuntimeSession
///   （self-care 型，系统上限 10 分钟——即本单要求的有界执行上限）；
/// - 空闲即释放，回落系统默认熄屏策略；
/// - start / will_expire / invalidated / released 全部落 WatchLog 结构化
///   事件（module=runtime），验收按日志判据，不靠人耳。
/// 持有/释放的决策是纯函数 RuntimeSessionPolicy，单测覆盖在
/// Tests/RuntimeSessionPolicyTests.swift。
@MainActor
final class VoiceSessionKeeper: NSObject, ObservableObject {
    private var session: WKExtendedRuntimeSession?
    private var sessionStartedAt: Date?
    /// start() 已调用、didStart 尚未回调的窗口，防止重复起会话。
    private var startPending = false
    /// 会话被系统收回（到期/失活）后，同一持有窗口内不自动重启——
    /// 否则 10 分钟上限形同虚设。新的按住说话会清除此标记。
    private var restartSuppressed = false
    private var holdReason: String?
    private var recordingStartDeferred = false

    private var latestTurns: [VoiceTurnRecord] = []
    private var deliveredRequestIds: Set<String> = []
    private var isRecording = false
    private var isPlaying = false

    private var reviewTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// 输入全部走 publisher：@Published 在 willSet 时发布，直接读属性会拿到旧值，
    /// 所以这里只依赖发布出来的新值，不回读来源对象。
    func bind(
        turns: AnyPublisher<[VoiceTurnRecord], Never>,
        playing: AnyPublisher<Bool, Never>,
        recording: AnyPublisher<Bool, Never>
    ) {
        turns
            .sink { [weak self] value in
                self?.latestTurns = value
                self?.reevaluate()
            }
            .store(in: &cancellables)
        playing
            .removeDuplicates()
            .sink { [weak self] value in
                self?.isPlaying = value
                self?.reevaluate()
            }
            .store(in: &cancellables)
        recording
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self else { return }
                // 用户新发起的回合：允许重新起会话（有界执行的边界是「一次持有窗口」）。
                if value { self.restartSuppressed = false }
                self.isRecording = value
                self.reevaluate()
            }
            .store(in: &cancellables)
    }

    /// 结果语音播放交付完成（play_finished 后回调）。
    /// journal 里 speechFileName 随即被清空，凭这份内存标记区分
    /// 「已播完」与「音频还没到」。
    func markDelivered(requestId: String) {
        deliveredRequestIds.insert(requestId)
        reevaluate()
    }

    private func reevaluate() {
        let verdict = RuntimeSessionPolicy.decide(
            turns: latestTurns,
            deliveredRequestIds: deliveredRequestIds,
            isRecording: isRecording,
            isPlaying: isPlaying,
            now: Date()
        )
        scheduleReview(at: verdict.reviewAt)
        switch verdict.decision {
        case .hold(let reason):
            holdReason = reason
            if RuntimeSessionPolicy.shouldStartExtendedSession(for: verdict.decision) {
                recordingStartDeferred = false
                startSessionIfNeeded(reason: reason)
            } else if !recordingStartDeferred {
                recordingStartDeferred = true
                WatchLog.info(
                    "runtime", "session_start_deferred",
                    detail: "reason=recording until=gesture_released"
                )
            }
        case .release:
            holdReason = nil
            recordingStartDeferred = false
            restartSuppressed = false
            releaseSession(cause: "idle")
        }
    }

    private func startSessionIfNeeded(reason: String) {
        if startPending { return }
        if let session, session.state == .running || session.state == .scheduled { return }
        guard !restartSuppressed else { return }
        let next = WKExtendedRuntimeSession()
        next.delegate = self
        session = next
        startPending = true
        WatchLog.info("runtime", "session_start_requested", detail: "reason=\(reason)")
        next.start()
    }

    private func releaseSession(cause: String) {
        guard let current = session else { return }
        WatchLog.info("runtime", "session_released", detail: "cause=\(cause) \(heldDescription())")
        // 先解除持有再 invalidate：didInvalidate 回调据此识别这是主动释放，不重复记账。
        session = nil
        sessionStartedAt = nil
        startPending = false
        current.invalidate()
    }

    private func scheduleReview(at date: Date?) {
        reviewTimer?.invalidate()
        reviewTimer = nil
        guard let date else { return }
        let interval = max(date.timeIntervalSinceNow, 0.1) + 0.5
        reviewTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        }
    }

    private func heldDescription() -> String {
        sessionStartedAt.map { String(format: "held=%.1fs", Date().timeIntervalSince($0)) } ?? "held=not_started"
    }
}

extension VoiceSessionKeeper: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            self.startPending = false
            self.sessionStartedAt = Date()
            let expiresIn = extendedRuntimeSession.expirationDate
                .map { String(format: "expires_in=%.0fs", $0.timeIntervalSinceNow) } ?? "expires_in=?"
            WatchLog.info(
                "runtime", "session_started",
                detail: "reason=\(self.holdReason ?? "?") \(expiresIn)"
            )
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            WatchLog.info(
                "runtime", "session_will_expire",
                detail: "reason=\(self.holdReason ?? "-") \(self.heldDescription())"
            )
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        Task { @MainActor in
            // 主动释放（releaseSession 已置空并记账）触发的回调不重复处理。
            guard extendedRuntimeSession === self.session else { return }
            let detail = "reason_code=\(reason.rawValue) hold=\(self.holdReason ?? "-") \(self.heldDescription())"
            if error != nil || reason == .error {
                WatchLog.error(
                    "runtime", "session_invalidated", detail: detail,
                    code: "ERR_RUNTIME_SESSION", error: error
                )
            } else {
                WatchLog.info("runtime", "session_invalidated", detail: detail)
            }
            self.session = nil
            self.sessionStartedAt = nil
            self.startPending = false
            // 有界执行：系统收回后本持有窗口不再自动续命，等下一次用户动作。
            if self.holdReason != nil { self.restartSuppressed = true }
        }
    }
}
