import Combine
import CryptoKit
import Foundation
import Security
import UserNotifications

/// Watch 结果/状态回传通道（由 PhoneConnectivity 用 WCSession 实现）。
@MainActor
protocol WatchFeedbackChannel: AnyObject {
    func notifyWatch(status: RelayStatusUpdate)
    func notifyWatch(result: VoiceRelayResultPayload)
    func transferResultAudio(fileURL: URL, payload: VoiceRelayResultPayload)
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
    @Published private(set) var outboxEntries: [VoiceOutboxEntry] = []
    @Published private(set) var relayStatus = "Relay 未配对"
    @Published private(set) var eventsConnected = false
    @Published private(set) var isPaired = false
    @Published var bridgeURLString: String {
        didSet { UserDefaults.standard.set(bridgeURLString, forKey: Self.bridgeURLKey) }
    }

    weak var watchChannel: WatchFeedbackChannel?

    private var outbox: VoiceOutbox?
    private var credentials: RelayDeviceCredentials?
    private let session: URLSession
    private let resultAudioDirectory: URL

    private var drainTask: Task<Void, Never>?
    private var scheduledDrainTask: Task<Void, Never>?
    private var eventsTask: URLSessionWebSocketTask?
    private var eventsLoopTask: Task<Void, Never>?
    private var eventsReconnectAttempt = 0
    private var notifiedStuckRequestIds: Set<String> = []

    private static let bridgeURLKey = "wristagent.relay.bridge_url"
    /// 连续失败到该次数时提醒用户打开 App（后台网络受限时人工兜底）。
    private static let stuckNotificationThreshold = 3

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
        refreshEntries()
    }

    /// App 启动 / 进入前台时调用：清理过期条目并立即尝试补送。
    func start() {
        purgeExpired()
        scheduleDrain(after: 0)
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
                requestId: envelope.requestId, phase: .failed, detail: "手机存储不可用"
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
                let phase: VoiceRelayPhase = existing.state == .delivered ? .accepted : .waitingForMac
                notify(status: RelayStatusUpdate(requestId: existing.requestId, phase: phase))
            }
        } catch {
            notify(status: RelayStatusUpdate(
                requestId: envelope.requestId, phase: .failed,
                detail: "入队失败：\((error as? VoiceOutboxError)?.description ?? error.localizedDescription)"
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
            outbox.remove(requestId: entry.requestId)
            notify(status: RelayStatusUpdate(
                requestId: entry.requestId, phase: .failed, detail: "本地音频已不可用"
            ))
            return
        }
        do {
            _ = try await client.upload(envelope: entry.envelope, audioData: audioData)
            outbox.markDelivered(requestId: entry.requestId)
            notifiedStuckRequestIds.remove(entry.requestId)
            relayStatus = "已上送 \(entry.requestId.prefix(8))…"
            notify(status: RelayStatusUpdate(requestId: entry.requestId, phase: .accepted))
        } catch let error as RelayUploadError where !error.isRetryable {
            // Bridge 稳定 4xx：毒消息，不再重试。
            outbox.remove(requestId: entry.requestId)
            relayStatus = "Bridge 拒绝 \(entry.requestId.prefix(8))…：\(error.stableCode)"
            notify(status: RelayStatusUpdate(
                requestId: entry.requestId, phase: .failed, detail: error.stableCode
            ))
        } catch {
            let next = outbox.markFailed(requestId: entry.requestId)
            relayStatus = "Mac 不可达，等待重试（第 \(entry.attemptCount + 1) 次失败）"
            if let updated = outbox.entry(for: entry.requestId),
               updated.attemptCount == Self.stuckNotificationThreshold,
               !notifiedStuckRequestIds.contains(entry.requestId) {
                notifiedStuckRequestIds.insert(entry.requestId)
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

    private func purgeExpired() {
        guard let outbox else { return }
        for expired in outbox.purgeExpired() {
            notify(status: RelayStatusUpdate(
                requestId: expired.requestId, phase: .failed, detail: "超过保留期未能送达 Mac"
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
        eventsTask?.cancel(with: .goingAway, reason: nil)
        eventsTask = nil
        guard !Task.isCancelled else { return }
        // 指数退避重连；Mac 恢复后事件流自动续上。
        eventsReconnectAttempt += 1
        let delay = RetryBackoff.outboxDefault.delay(forAttempt: eventsReconnectAttempt)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        connectEventsIfNeeded()
    }

    private func handleEvent(data: Data) {
        guard let event = VoiceRelayEvent.decode(from: data) else { return }
        switch event.event {
        case "status":
            guard let phase = event.phase else { return }
            notify(status: RelayStatusUpdate(
                requestId: event.requestId, phase: phase, detail: event.errorCode ?? event.text
            ))
        case "permission_required":
            notify(status: RelayStatusUpdate(
                requestId: event.requestId, phase: .permissionRequired, detail: event.text
            ))
        case "result":
            deliverResult(event)
        default:
            break // 未知事件类型：忽略，不中断事件流。
        }
    }

    private func deliverResult(_ event: VoiceRelayEvent) {
        var audioSha: String?
        var audioURL: URL?
        if let base64 = event.audioBase64, let audioData = Data(base64Encoded: base64) {
            let sha = RelayWire.sha256Hex(audioData)
            let url = resultAudioDirectory.appendingPathComponent("\(event.requestId).m4a")
            if (try? audioData.write(to: url, options: .atomic)) != nil {
                audioSha = sha
                audioURL = url
            }
        }
        let payload = VoiceRelayResultPayload(
            requestId: event.requestId, text: event.text, audioSha256: audioSha
        )
        notifyResult(payload)
        if let audioURL {
            watchChannel?.transferResultAudio(fileURL: audioURL, payload: payload)
        }
        notify(status: RelayStatusUpdate(
            requestId: event.requestId,
            phase: event.phase ?? .completed,
            detail: event.errorCode
        ))
        relayStatus = "已回传结果 \(event.requestId.prefix(8))…"
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
