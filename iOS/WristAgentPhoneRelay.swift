import Combine
import CryptoKit
import Foundation
import os
import Security
import UserNotifications

/// Watch 结果/状态回传通道（由 PhoneConnectivity 用 WCSession 实现）。
@MainActor
protocol WatchFeedbackChannel: AnyObject {
    func notifyWatch(status: RelayStatusUpdate)
    func notifyWatch(progress: RelayStatusUpdate)
    func notifyWatch(result: VoiceRelayResultPayload)
    /// 状态/权限/结果信封 → Watch VoiceTurnJournal（ESS-29 时间线 UI 的入账单位）。
    func notifyWatch(voiceStatus: VoiceStatusEnvelope)
    func notifyWatch(resultAudioDegradation: VoiceResultAudioDegradationEnvelope)
    /// 结果语音 transferFile；metadata 带含 speechSha256 的信封，Watch 校验后入加密仓。
    /// 返回 true 表示本条已**持久入队**（或同载荷已在队列/保留期内送达过，属幂等重复）；
    /// 返回 false 表示未能持久化——调用方不得记为已交付，必须允许后续快照重试。
    @discardableResult
    func transferSpeech(fileURL: URL, envelope: VoiceStatusEnvelope) -> Bool
    /// ESS-171：WSS 快照到达 = Bridge 还没收到我们的 /ack。踢一次下行队列，
    /// 让已 deferred / 到期未交付的条目立刻重投，别等 reachability 抖动触发。
    func retryPendingDownlinks(requestIds: [String], trigger: String)
    /// ESS-184/207 探针语音下行：与 transferSpeech 传输语义相同（transferFile），
    /// 但走独立 messageKey（`voice_probe_envelope`）与独立 kind（`.probe`），
    /// Watch 端匹配后进探针分支——不入 vault、不入 journal、播完回 probe_ack。
    @discardableResult
    func transferProbe(fileURL: URL, envelope: VoiceStatusEnvelope) -> Bool
}

/// WristAgentPhoneRelay（ESS-28）：iPhone Companion Relay 编排器。
/// - 接收 Watch 已校验的语音请求，写入加密 outbox（request_id 唯一）；
/// - Mac/Tailscale 不可达时指数退避排队，恢复后以同一 request_id 重试（Bridge 幂等）；
/// - 订阅 WSS /v1/voice/events，把状态/权限/结果映射回 Watch
///   （短文本 sendMessage/transferUserInfo，音频 transferFile）；
/// - 重试多次仍失败时发本地通知提醒打开 App（iPhone 后台限制，§11）；
/// - 只持有 Bridge 设备凭据（Keychain），不保存 DashScope/Codex/Vault 凭据。
@MainActor
final class WristAgentPhoneRelay: ObservableObject {
    private static let downlinkLogger = Logger(subsystem: "com.benyuan.wristagent.phone", category: "VoiceDownlink")
    @Published private(set) var outboxEntries: [VoiceOutboxEntry] = []
    @Published private(set) var relayStatus = "Relay 未配对"
    @Published private(set) var eventsConnected = false
    @Published private(set) var isPaired = false
    @Published var bridgeURLString: String {
        didSet { UserDefaults.standard.set(bridgeURLString, forKey: Self.bridgeURLKey) }
    }

    weak var watchChannel: WatchFeedbackChannel?
    /// ESS-184/207 探针回执上送句柄。iPhone 侧的 `PhoneConnectivity` 收到
    /// Watch 的 `probe_playback_ack` 后调 `postProbeAck(...)`——不走 outbox，
    /// 因为探针本来就是一次性门禁事件、丢了就丢了下一场再跑。
    private var probeAckTasks: [String: Task<Void, Never>] = [:]

    private var outbox: VoiceOutbox?
    private var credentials: RelayDeviceCredentials?
    private let session: URLSession
    private let resultAudioDirectory: URL
    /// Watch 交互日志 chunk → Bridge /v1/client-logs（ESS-42）。
    private(set) var clientLogUplink: ClientLogUplink!

    private var drainTask: Task<Void, Never>?
    private var scheduledDrainTask: Task<Void, Never>?
    private var eventsTask: URLSessionWebSocketTask?
    private var eventsLoopTask: Task<Void, Never>?
    private var eventsReconnectAttempt = 0
    private var notifiedStuckRequestIds: Set<String> = []
    /// 已确认持久入下行队列的结果语音（requestId|sha）：快照重放/补挂事件不重复 transferFile。
    /// 只有 transferSpeech 返回成功才写入——入队失败必须留给后续快照重试的机会。
    private var deliveredResultAudio: Set<String> = []
    /// 下载中的结果语音（requestId|sha）：避免并发重复下载。
    private var activeAudioDownloads: Set<String> = []
    /// Watch 已落盘 ACK 的网络重试。进程存活期间持续重试；若进程被杀，Bridge
    /// 仍保留未 ACK 终态，下一次 snapshot 会触发 Watch 再发同一幂等 ACK。
    private var resultAckTasks: [String: Task<Void, Never>] = [:]
    /// requestId|delivery_sequence：WSS 重连或服务端重放不重复显示/播放 interim。
    private var deliveredInterims: Set<String> = []

    private static let bridgeURLKey = "wristagent.relay.bridge_url"
    /// 连续失败到该次数时提醒用户打开 App（后台网络受限时人工兜底）。
    private static let stuckNotificationThreshold = 3
    /// 结果语音本地上限（最后一道防线；Bridge 侧已有转码上限）。
    private static let maxResultAudioBytes = 20 * 1024 * 1024

    init(session: URLSession = .shared) {
        self.session = session
        bridgeURLString = UserDefaults.standard.string(forKey: Self.bridgeURLKey)
            ?? "https://jackson-macmac-mini.magic.workspace.beer:8443"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        resultAudioDirectory = base.appendingPathComponent("VoiceResultsOutgoing", isDirectory: true)
        try? FileManager.default.createDirectory(at: resultAudioDirectory, withIntermediateDirectories: true)

        outbox = try? VoiceOutbox(
            directory: base.appendingPathComponent("VoiceRelayOutbox", isDirectory: true),
            keyProvider: KeychainOutboxKeyProvider()
        )
        credentials = RelayCredentialsStore.read()
        isPaired = credentials != nil
        relayStatus = isPaired ? "已配对，等待请求" : "Relay 未配对"
        clientLogUplink = ClientLogUplink(
            directory: base.appendingPathComponent("ClientLogQueue", isDirectory: true),
            makeClient: { [weak self] in self?.makeClient() }
        )
        refreshEntries()
    }

    /// App 启动 / 进入前台时调用：清理过期条目并立即尝试补送。
    func start() {
        purgeExpired()
        scheduleDrain(after: 0)
        connectEventsIfNeeded()
        clientLogUplink.start()
    }

    /// WCSession 的激活/可达变化会唤醒 iPhone 进程；每个唤醒点都恢复 events，
    /// 避免只在下一次语音上送时才顺便建立 WebSocket。
    func resumeEvents(trigger: String) {
        guard isPaired else { return }
        relayLog("恢复事件通道（\(trigger)）")
        connectEventsIfNeeded()
    }

    // MARK: - 配对

    func pair(code: String, deviceName: String) async {
        guard let baseURL = URL(string: bridgeURLString) else {
            relayStatus = "Bridge 地址无效"
            return
        }
        do {
            let issued = try await RelayClient.pair(
                baseURL: baseURL, pairingCode: code, deviceName: deviceName, session: session
            )
            RelayCredentialsStore.save(issued)
            credentials = issued
            isPaired = true
            relayStatus = "配对成功"
            scheduleDrain(after: 0)
            connectEventsIfNeeded()
            clientLogUplink.start()
        } catch {
            relayStatus = "配对失败：\((error as? RelayUploadError)?.stableCode ?? error.localizedDescription)"
        }
    }

    // MARK: - Watch 请求入口

    /// PhoneConnectivity 校验（sha256 + request_id 去重）通过后调用。
    /// 入队成功即向 Watch 回执“已到手机，等待 Mac”，随后异步上送。
    func handleAccepted(envelope: VoiceRequestEnvelope, audioData: Data) {
        guard let outbox else {
            relayStatus = "outbox 不可用"
            notify(status: RelayStatusUpdate(
                requestId: envelope.requestId, phase: .failed, detail: "手机没能保存这段录音",
                errorCode: "ERR_RETRY_WRITE_FAILED", failureStage: .execution
            ))
            return
        }
        do {
            switch try outbox.enqueue(envelope: envelope, audioData: audioData) {
            case .enqueued:
                notify(status: RelayStatusUpdate(
                    requestId: envelope.requestId, phase: .waitingForMac, detail: "已到手机，等待 Mac"
                ))
            case .duplicate(let existing):
                // 幂等：不产生第二个请求，只把当前状态重发给 Watch。
                switch existing.state {
                case .delivered:
                    notify(status: RelayStatusUpdate(requestId: existing.requestId, phase: .accepted))
                case .queued:
                    notify(status: RelayStatusUpdate(requestId: existing.requestId, phase: .waitingForMac))
                case .failed:
                    notify(status: RelayStatusUpdate(
                        requestId: existing.requestId, phase: .failed,
                        detail: "这次请求已经结束，请重新发起",
                        errorCode: existing.failureCode ?? "ERR_UNKNOWN", failureStage: .macUnreachable
                    ))
                }
            }
        } catch {
            notify(status: RelayStatusUpdate(
                requestId: envelope.requestId, phase: .failed,
                detail: "手机没能保存这段录音",
                errorCode: "ERR_RETRY_WRITE_FAILED", failureStage: .execution
            ))
        }
        refreshEntries()
        scheduleDrain(after: 0)
    }

    /// 结果音频 transferFile 完成后删除本地临时文件（成功交付即删，§8）。
    func handleResultAudioTransferFinished(fileName: String, error: Error?) {
        guard error == nil else { return }
        try? FileManager.default.removeItem(at: resultAudioDirectory.appendingPathComponent(fileName))
    }

    // MARK: - Outbox 上送

    private func scheduleDrain(after delay: TimeInterval) {
        scheduledDrainTask?.cancel()
        scheduledDrainTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    private func drain() async {
        guard drainTask == nil else { return }
        guard let outbox, let client = makeClient() else { return }
        let task = Task { [weak self] in
            for entry in outbox.dueEntries() {
                guard !Task.isCancelled else { break }
                await self?.upload(entry: entry, outbox: outbox, client: client)
            }
        }
        drainTask = task
        await task.value
        drainTask = nil
        refreshEntries()
        // 仍有排队条目：按最近的重试时间安排下一轮。
        if let next = outbox.earliestNextAttempt() {
            scheduleDrain(after: max(0.5, next.timeIntervalSinceNow))
        }
    }

    private func upload(entry: VoiceOutboxEntry, outbox: VoiceOutbox, client: RelayClient) async {
        let audioData: Data
        do {
            audioData = try outbox.audioData(for: entry.requestId)
        } catch {
            // 密文缺失/损坏：无法重建同一请求，明确失败而不是伪造内容。
            outbox.markTerminalFailed(requestId: entry.requestId, code: "ERR_RETRY_CACHE_MISSING")
            notify(status: RelayStatusUpdate(
                requestId: entry.requestId, phase: .failed, detail: "原来的录音没有留住",
                errorCode: "ERR_RETRY_CACHE_MISSING", failureStage: .execution
            ))
            return
        }
        do {
            _ = try await client.upload(envelope: entry.envelope, audioData: audioData)
            outbox.markDelivered(requestId: entry.requestId)
            notifiedStuckRequestIds.remove(entry.requestId)
            relayStatus = "已上送 \(entry.requestId.prefix(8))…"
            notify(status: RelayStatusUpdate(requestId: entry.requestId, phase: .accepted))
            connectEventsIfNeeded()
        } catch let error as RelayUploadError where !error.isRetryable {
            // Bridge 稳定 4xx：毒消息，不再重试。
            outbox.markTerminalFailed(requestId: entry.requestId, code: error.stableCode)
            relayStatus = "Bridge 拒绝 \(entry.requestId.prefix(8))…：\(error.stableCode)"
            notify(status: RelayStatusUpdate(
                requestId: entry.requestId, phase: .failed, detail: "Mac 拒绝了这次请求",
                errorCode: error.stableCode, failureStage: .execution
            ))
        } catch {
            let next = outbox.markFailed(requestId: entry.requestId)
            relayStatus = "Mac 不可达，等待重试（第 \(entry.attemptCount + 1) 次失败）"
            if let updated = outbox.entry(for: entry.requestId),
               updated.attemptCount == Self.stuckNotificationThreshold,
               !notifiedStuckRequestIds.contains(entry.requestId) {
                notifiedStuckRequestIds.insert(entry.requestId)
                // ESS-253 / U2 / D2 E-18：达到有界阈值即结束本次自动重试，
                // 明确告诉 Watch 进入 S-FAIL；用户可从 Watch 的缓存录音手动重试。
                let code = (error as? RelayUploadError)?.stableCode ?? "ERR_TRANSPORT"
                outbox.markTerminalFailed(requestId: entry.requestId, code: code)
                notify(status: RelayStatusUpdate(
                    requestId: entry.requestId, phase: .failed,
                    detail: "Mac 没有应答，请确认助手正在运行",
                    errorCode: code, failureStage: .macUnreachable
                ))
                postStuckNotification()
            }
            _ = next
        }
        refreshEntries()
    }

    private func makeClient() -> RelayClient? {
        guard let credentials, let baseURL = URL(string: bridgeURLString) else { return nil }
        return RelayClient(baseURL: baseURL, credentials: credentials, session: session)
    }

    func acknowledgeResult(requestId: String) {
        guard resultAckTasks[requestId] == nil else { return }
        resultAckTasks[requestId] = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let client = self.makeClient() {
                    do {
                        try await client.acknowledgeResult(requestId: requestId)
                        self.relayStatus = "手表已确认结果 \(requestId.prefix(8))…"
                        self.resultAckTasks[requestId] = nil
                        return
                    } catch {
                        self.relayLog("结果确认暂未送达，正在重试")
                    }
                }
                attempt += 1
                let delay = RetryBackoff.outboxDefault.delay(forAttempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func purgeExpired() {
        guard let outbox else { return }
        for expired in outbox.purgeExpired() {
            notify(status: RelayStatusUpdate(
                requestId: expired.requestId, phase: .failed,
                detail: "Mac 一直没有应答",
                errorCode: "ERR_TRANSPORT", failureStage: .macUnreachable
            ))
        }
        refreshEntries()
    }

    private func refreshEntries() {
        outboxEntries = outbox?.entries ?? []
    }

    // MARK: - WSS /v1/voice/events

    private func connectEventsIfNeeded() {
        guard eventsTask == nil, let credentials else { return }
        guard var components = URLComponents(string: bridgeURLString) else { return }
        components.scheme = "wss"
        components.path = "/v1/voice/events"
        guard let url = components.url else { return }

        let builder = RelaySignedRequestBuilder(
            baseURL: url.deletingLastPathComponent(), credentials: credentials
        )
        var request = builder.request(
            method: "GET", path: "/v1/voice/events",
            requestId: UUID().uuidString.lowercased(), body: nil
        )
        request.url = url

        let task = session.webSocketTask(with: request)
        eventsTask = task
        task.resume()
        eventsLoopTask = Task { [weak self] in
            await self?.runEventsLoop(task)
        }
    }

    private func runEventsLoop(_ task: URLSessionWebSocketTask) async {
        var pingTask: Task<Void, Never>?
        defer { pingTask?.cancel() }
        // 应用层 ping：上游不承诺心跳，超时即视为断线重连。
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                task.sendPing { _ in }
            }
        }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                eventsConnected = true
                eventsReconnectAttempt = 0
                switch message {
                case .string(let text):
                    handleEvent(data: Data(text.utf8))
                case .data(let data):
                    handleEvent(data: data)
                @unknown default:
                    break
                }
            } catch {
                break
            }
        }
        eventsConnected = false
        task.cancel(with: .goingAway, reason: nil)
        // 旧连接的迟到失败不得清掉已由唤醒入口建立的新连接。
        if eventsTask === task { eventsTask = nil }
        guard !Task.isCancelled else { return }
        // 指数退避重连；Mac 恢复后事件流自动续上。
        eventsReconnectAttempt += 1
        let delay = RetryBackoff.outboxDefault.delay(forAttempt: eventsReconnectAttempt)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        connectEventsIfNeeded()
    }

    /// Bridge 事件入口（ESS-38）：真实契约是 `turn.state` 增量 + 连接回放
    /// `snapshot`（非终态 + TTL 内未 ACK 终态）。快照重放靠 request_id + 音频 sha 幂等去重。
    private func handleEvent(data: Data) {
        guard let message = BridgeEventMessage.decode(from: data) else { return }
        switch message.type {
        case "turn.state":
            if let turn = message.turn { process(projection: turn) }
        case "snapshot":
            // ESS-171：completed turn 出现在 snapshot 里 = Bridge 还没收到我们的 /ack。
            // 先清掉这些 request_id 的乐观缓存（否则 stageAndTransferSpeech 会短路），
            // 再走一次正常投影处理，最后踢一下下行队列。
            let pendingCompleted = (message.turns ?? []).filter { $0.status == "completed" }
            for turn in pendingCompleted {
                if let sha = turn.result?.audio?.sha256.lowercased() {
                    deliveredResultAudio.remove(audioDeliveryKey(turn.requestId, sha))
                }
            }
            watchChannel?.retryPendingDownlinks(
                requestIds: pendingCompleted.map(\.requestId), trigger: "wss-snapshot"
            )
            message.turns?.forEach { process(projection: $0) }
        case "turn.interim":
            if let interim = message.interim { process(interim: interim) }
        case "turn.progress":
            if let progress = message.progress, progress.isValid { process(progress: progress) }
        default:
            break // 未知事件类型：忽略，不中断事件流。
        }
    }

    private func process(progress: BridgeProgressProjection) {
        // No result/audio payload: progress is always text-only.
        watchChannel?.notifyWatch(progress: RelayStatusUpdate(
            requestId: progress.requestId, phase: .backgroundProcessing,
            detail: progress.text, updatedAt: progress.occurredAt
        ))
    }

    private func process(interim: BridgeInterimProjection) {
        let key = "\(interim.requestId)|\(interim.deliverySequence)"
        guard !deliveredInterims.contains(key) else { return }
        let result = VoiceResultPayload(
            summary: interim.text, isTruncated: false,
            speechSha256: interim.audio?.sha256.lowercased(),
            speechDurationMs: interim.audio?.durationMs
        )
        let envelope = VoiceStatusEnvelope.status(
            requestId: interim.requestId, state: .backgroundAccepted,
            detail: interim.text, result: result, audioKind: interim.audio?.kind
        )
        watchChannel?.notifyWatch(voiceStatus: envelope)
        guard let audio = interim.audio,
              let data = Data(base64Encoded: audio.base64),
              RelayWire.sha256Hex(data) == audio.sha256.lowercased()
        else {
            deliveredInterims.insert(key) // 文字已经可靠入队；音频缺失时不伪造
            return
        }
        let url = resultAudioDirectory.appendingPathComponent("\(interim.requestId)-interim-\(interim.deliverySequence).m4a")
        guard (try? data.write(to: url, options: .atomic)) != nil,
              watchChannel?.transferSpeech(fileURL: url, envelope: envelope) == true
        else { return }
        deliveredInterims.insert(key)
    }

    private func process(projection: BridgeTurnProjection) {
        // ESS-184/207：kind=probe 走独立通道——不入结果账本、不发状态信封、
        // 不占 iPhone 前台状态行；只把音频直投给 Watch 走探针分支。
        // 探针 turn 只能是 completed（Bridge 侧 /v1/probe/inject 直接进终态），
        // 但仍防御性检查，避免注入路径变化时把非 completed 事件误发。
        if projection.result?.audio?.kind == .probe {
            guard projection.status == "completed" else { return }
            deliverProbeAudio(projection: projection)
            return
        }
        guard let envelope = projection.statusEnvelope() else { return }
        // 旧版 caption 通道照旧（iPhone 前台状态行）。
        if let phase = VoiceRelayPhase(rawValue: envelope.state.rawValue) {
            notify(status: RelayStatusUpdate(
                requestId: projection.requestId, phase: phase, detail: projection.detailText,
                errorCode: projection.errorCode,
                failureStage: envelope.failureStage
            ))
        }
        // 终态先下发文本（§ESS-38：文字先行，语音随后 transferFile 补上）。
        watchChannel?.notifyWatch(voiceStatus: envelope)
        guard projection.status == "completed" else { return }
        notifyResult(VoiceRelayResultPayload(
            requestId: projection.requestId,
            text: projection.result?.text ?? projection.result?.speechText,
            audioSha256: projection.result?.audio?.sha256.lowercased()
        ))
        relayStatus = "已回传结果 \(projection.requestId.prefix(8))…"
        deliverResultAudio(projection: projection)
    }

    // MARK: - 结果语音下行（ESS-38）

    /// 已（开始）交付的结果语音：requestId|sha。快照重放/迟到补挂事件不重复下发。
    private func audioDeliveryKey(_ requestId: String, _ sha: String) -> String { "\(requestId)|\(sha)" }

    private func deliverResultAudio(projection: BridgeTurnProjection) {
        guard let result = projection.result else {
            notifyAudioDegradation(requestId: projection.requestId, sourceCode: "ERR_NO_SPEECH_FILE")
            return
        }
        // inline base64 优先（≤ Bridge 上限时随投影内联下发）。
        if let base64 = result.audioBase64, let data = Data(base64Encoded: base64) {
            let sha = RelayWire.sha256Hex(data)
            if let expected = result.audio?.sha256.lowercased(), expected != sha {
                // 内联数据与元数据不一致：不用坏数据，转下载路径兜底。
                relayLog("结果语音内联数据校验失败，转下载")
            } else {
                stageAndTransferSpeech(projection: projection, data: data, sha: sha)
                return
            }
        }
        // 无内联（超限被裁）：凭元数据经 HTTPS 有界下载，支持断点续传。
        guard let meta = result.audio else {
            notifyAudioDegradation(requestId: projection.requestId, sourceCode: "ERR_NO_SPEECH_FILE")
            return
        }
        let key = audioDeliveryKey(projection.requestId, meta.sha256.lowercased())
        guard !deliveredResultAudio.contains(key), !activeAudioDownloads.contains(key) else { return }
        activeAudioDownloads.insert(key)
        Task { [weak self] in
            await self?.downloadAndTransferSpeech(projection: projection, meta: meta)
            self?.activeAudioDownloads.remove(key)
        }
    }

    private func stageAndTransferSpeech(projection: BridgeTurnProjection, data: Data, sha: String) {
        let key = audioDeliveryKey(projection.requestId, sha)
        guard !deliveredResultAudio.contains(key) else { return }
        let url = resultAudioDirectory.appendingPathComponent("\(projection.requestId).m4a")
        guard (try? data.write(to: url, options: .atomic)) != nil else {
            notifyAudioDegradation(requestId: projection.requestId, sourceCode: "ERR_VAULT_STORE")
            return
        }
        // transferFile 的信封以实际字节的 sha 为准（Watch 端以此校验入库）。
        guard let envelope = speechEnvelope(projection: projection, sha: sha) else {
            notifyAudioDegradation(requestId: projection.requestId, sourceCode: "ERR_NO_SPEECH_FILE")
            return
        }
        Self.downlinkLogger.log("l2_relay_audio_ready request_id=\(projection.requestId, privacy: .public) bytes=\(data.count) sha256=\(sha, privacy: .public) source=\(projection.path ?? "unknown", privacy: .public)")
        guard watchChannel?.transferSpeech(fileURL: url, envelope: envelope) == true else {
            // 编码/读文件/落盘任一环失败：不写内存去重，下一次快照重放还能重试这条语音。
            relayLog("结果语音入队失败，等待快照重试 \(projection.requestId.prefix(8))…")
            notifyAudioDegradation(requestId: projection.requestId, sourceCode: "ERR_AUDIO_FETCH")
            return
        }
        deliveredResultAudio.insert(key)
    }

    private func speechEnvelope(projection: BridgeTurnProjection, sha: String) -> VoiceStatusEnvelope? {
        let result = VoiceResultPayload(
            summary: projection.result?.text ?? projection.result?.speechText ?? "已完成",
            isTruncated: projection.result?.truncated ?? false,
            speechSha256: sha,
            speechDurationMs: projection.result?.audio?.durationMs
        )
        return VoiceStatusEnvelope.status(
            requestId: projection.requestId, state: .completed,
            detail: projection.detailText, result: result, audioKind: projection.result?.audio?.kind
        )
    }

    /// 结果语音下载：Range 断点续传 + sha256 校验，校验不过重下、不过夜。
    // MARK: - 探针语音下行（ESS-184/207）

    /// kind=probe 的语音：只有 inline base64（Bridge /v1/probe/inject 一次性
    /// 注入，走真实链路但不上传大文件、不进 result-audio 有界下载路径）。
    /// 与结果链路完全隔离——不走 ResultAudioLedger、不落 ConversationHistory、
    /// 不发状态信封（避免 Watch VoiceTurnJournal 记一条假 turn）。
    private func deliverProbeAudio(projection: BridgeTurnProjection) {
        guard let result = projection.result,
              let meta = result.audio,
              let base64 = result.audioBase64,
              let data = Data(base64Encoded: base64) else {
            relayLog("探针语音缺 inline base64，跳过（探针 turn 不走下载兜底）")
            return
        }
        let sha = RelayWire.sha256Hex(data)
        guard sha == meta.sha256.lowercased() else {
            relayLog("探针语音内联校验失败 \(projection.requestId.prefix(8))…")
            return
        }
        let url = resultAudioDirectory.appendingPathComponent("\(projection.requestId)-probe.m4a")
        guard (try? data.write(to: url, options: .atomic)) != nil else {
            relayLog("探针语音落盘失败 \(projection.requestId.prefix(8))…")
            return
        }
        // 探针专用信封：state 保持 completed 便于 Watch 端沿用 VoiceStatusEnvelope
        // 解码，但携带 kind=.probe——Watch 端严格按 kind 分流到 playProbe，绝不
        // 走 storeSpeech（后者会入 vault + journal）。
        let payload = VoiceResultPayload(
            summary: result.text ?? result.speechText ?? "探针",
            isTruncated: false,
            speechSha256: sha,
            speechDurationMs: meta.durationMs
        )
        let envelope = VoiceStatusEnvelope.status(
            requestId: projection.requestId,
            state: .completed,
            detail: "kind=probe",
            result: payload,
            audioKind: .probe
        )
        Self.downlinkLogger.log("l2_relay_probe_ready request_id=\(projection.requestId, privacy: .public) bytes=\(data.count) sha256=\(sha, privacy: .public)")
        guard watchChannel?.transferProbe(fileURL: url, envelope: envelope) == true else {
            relayLog("探针语音入队失败 \(projection.requestId.prefix(8))…")
            return
        }
    }

    /// PhoneConnectivity 收到 Watch 的 `probe_playback_ack` 后调用；HTTP 上送
    /// Bridge /v1/probe/ack。失败仅重试一小段窗口——探针是一次性门禁，超期就
    /// 让下一场探针重跑，别把 iPhone 卡在无限重试里。
    func postProbeAck(_ ack: ProbeAckEnvelope) {
        // 同一 request_id 的探针 ack 已在途/已发过：不重复。
        guard probeAckTasks[ack.requestId] == nil else { return }
        probeAckTasks[ack.requestId] = Task { [weak self] in
            var attempt = 0
            let maxAttempts = 5
            while attempt < maxAttempts && !Task.isCancelled {
                guard let self else { return }
                if let client = self.makeClient() {
                    do {
                        try await client.acknowledgeProbe(ack)
                        self.relayStatus = "探针回执已发 \(ack.requestId.prefix(8))…"
                        self.probeAckTasks[ack.requestId] = nil
                        return
                    } catch {
                        self.relayLog("探针回执上送失败，重试中")
                    }
                }
                attempt += 1
                let delay = RetryBackoff.outboxDefault.delay(forAttempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await MainActor.run { self?.probeAckTasks[ack.requestId] = nil }
        }
    }

    private func downloadAndTransferSpeech(
        projection: BridgeTurnProjection, meta: BridgeResultAudioMeta
    ) async {
        guard let client = makeClient() else { return }
        if let size = meta.sizeBytes, size > Self.maxResultAudioBytes {
            relayLog("结果语音超出本地上限（\(size)B），保留文本降级")
            notifyAudioDegradation(requestId: projection.requestId, sourceCode: "ERR_NO_SPEECH_FILE")
            return
        }
        let partialURL = resultAudioDirectory
            .appendingPathComponent("\(projection.requestId).m4a.partial")
        var assembled = (try? Data(contentsOf: partialURL)) ?? Data()
        Self.downlinkLogger.info(
            "result audio fetch started request_id=\(projection.requestId, privacy: .public) state=queued bytes_staged=\(assembled.count) expected_bytes=\(meta.sizeBytes ?? -1)"
        )
        for attempt in 0..<3 {
            do {
                let rangeStart = assembled.isEmpty ? nil : assembled.count
                Self.downlinkLogger.info(
                    "result audio fetch attempted request_id=\(projection.requestId, privacy: .public) state=attempted attempt=\(attempt + 1) range_start=\(rangeStart ?? 0)"
                )
                let (data, status) = try await client.fetchResultAudio(
                    requestId: projection.requestId,
                    rangeStart: rangeStart
                )
                switch status {
                case 206: assembled.append(data)
                case 200: assembled = data
                case 404:
                    Self.downlinkLogger.error(
                        "result audio fetch failed request_id=\(projection.requestId, privacy: .public) state=failed reason=not-found attempt=\(attempt + 1)"
                    )
                    notifyAudioDegradation(requestId: projection.requestId, sourceCode: "ERR_NO_SPEECH_FILE")
                    return
                case 416: assembled = Data() // 断点越界：从头再来
                default: throw RelayUploadError.bridge(code: "ERR_AUDIO_FETCH", httpStatus: status)
                }
                if RelayWire.sha256Hex(assembled) == meta.sha256.lowercased() {
                    try? FileManager.default.removeItem(at: partialURL)
                    Self.downlinkLogger.info(
                        "result audio fetch completed request_id=\(projection.requestId, privacy: .public) state=downloaded bytes=\(assembled.count) attempt=\(attempt + 1)"
                    )
                    stageAndTransferSpeech(projection: projection, data: assembled, sha: meta.sha256.lowercased())
                    return
                }
                if let size = meta.sizeBytes, assembled.count >= size {
                    assembled = Data() // 齐了却校验不过：数据不可信，整体重下
                }
            } catch {
                try? assembled.write(to: partialURL, options: .atomic) // 保留断点
                Self.downlinkLogger.error(
                    "result audio fetch interrupted request_id=\(projection.requestId, privacy: .public) state=attempted-no-ack bytes_staged=\(assembled.count) attempt=\(attempt + 1) error=\(String(describing: error), privacy: .public)"
                )
                let delay = RetryBackoff.outboxDefault.delay(forAttempt: attempt + 1)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        try? assembled.write(to: partialURL, options: .atomic)
        Self.downlinkLogger.error(
            "result audio fetch deferred request_id=\(projection.requestId, privacy: .public) state=queued bytes_staged=\(assembled.count) reason=retry-exhausted"
        )
        relayLog("结果语音下载未完成，已保留断点；文本结果已先行送达")
        notifyAudioDegradation(requestId: projection.requestId, sourceCode: "ERR_AUDIO_FETCH")
    }

    private func notifyAudioDegradation(requestId: String, sourceCode: String) {
        Self.downlinkLogger.error(
            "result audio degraded request_id=\(requestId, privacy: .public) source_code=\(sourceCode, privacy: .public) projected_code=ERR_NO_SPEECH_FILE"
        )
        watchChannel?.notifyWatch(resultAudioDegradation: .event(requestId: requestId))
    }

    private func relayLog(_ message: String) {
        relayStatus = message
    }

    // MARK: - Watch 回执 / 本地通知

    private func notify(status: RelayStatusUpdate) {
        watchChannel?.notifyWatch(status: status)
    }

    private func notifyResult(_ payload: VoiceRelayResultPayload) {
        watchChannel?.notifyWatch(result: payload)
    }

    /// iPhone 后台网络受限时（§11 风险项）提醒用户打开 App 完成补送。
    private func postStuckNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "腕语任务等待送达"
            content.body = "有语音请求暂时无法送达 Mac，打开 App 可立即重试。"
            let request = UNNotificationRequest(
                identifier: "wristagent.relay.stuck", content: content, trigger: nil
            )
            center.add(request)
        }
    }
}

// MARK: - Keychain 存储

/// outbox 音频加密密钥：首次生成后存 Keychain（本机、首次解锁后可用）。
struct KeychainOutboxKeyProvider: VoiceOutboxKeyProviding {
    private static let service = "com.benyuan.wristagent.relay-outbox-key"
    private static let account = "default"

    func outboxKey() throws -> SymmetricKey {
        if let data = KeychainData.read(service: Self.service, account: Self.account) {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        guard KeychainData.save(data, service: Self.service, account: Self.account) else {
            throw VoiceOutboxError.storageFailure("无法写入 Keychain 密钥")
        }
        return key
    }
}

/// Bridge 设备凭据（device_id + token）只存 iPhone Keychain，不同步、不进日志。
enum RelayCredentialsStore {
    private static let service = "com.benyuan.wristagent.relay-credentials"
    private static let account = "default"

    static func read() -> RelayDeviceCredentials? {
        guard let data = KeychainData.read(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(RelayDeviceCredentials.self, from: data)
    }

    static func save(_ credentials: RelayDeviceCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        _ = KeychainData.save(data, service: service, account: account)
    }
}

enum KeychainData {
    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
