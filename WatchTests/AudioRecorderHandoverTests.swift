import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-72 复现测试（watch 模拟器宿主进程运行，R-02 运行时证据）：
/// 真机取证显示录音刚结束（09:12:15 record_finished）后立刻播放
/// （09:12:17），两级激活全部 !res（AVAudioSession resourceNotAvailable,
/// NSOSStatusErrorDomain#561145203）、play_started 为 0——录音把共享会话
/// 激活成 .playAndRecord 后从未交还。修复：AudioRecorder.finish()/cancel()
/// 调 setActive(false, .notifyOthersOnDeactivation) 并落 session_released
/// 取证事件。
///
/// 模拟器限制：headless 跑测时 macOS 不放行模拟器的真实采集，record()
/// 起录返回 false（LPCM/AAC 皆然，输入路由本身在）。因此本套件分两层：
/// 1. 会话交还测试——不依赖真实采集：AudioRecorder.start() 已把会话配成
///    .playAndRecord 并激活（事故的危险态），走 cancel()/finish() 的生产
///    释放路径，断言 session_released result=true 且随后播放完整出声；
/// 2. 全链交替测试——真机/放行了采集的环境跑完整「录音→播放」两轮，
///    采集不可用时 XCTSkip（跳过原因落在测试输出里，不算通过）。
@MainActor
final class AudioRecorderHandoverTests: XCTestCase {

    private func welcomeSpeechData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "WelcomeSpeech", withExtension: "m4a"),
            "WelcomeSpeech.m4a 不在宿主 App 包内"
        )
        return try Data(contentsOf: url)
    }

    /// 宿主 App 启动即自动播欢迎语（约 3.3s），占着输出通道时起录必败——
    /// 先等它播完再开测，测的才是「录音 → 播放」本身。
    private func waitForHostWelcomeToFinish() async throws {
        try await Task.sleep(for: .seconds(4))
    }

    /// 事件旁路观察（与 G9 自检同一机制）：session_released 是本单要求
    /// 补上的交还观测点，必须在这里被捕获到才算修复可验证。
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(event: String, detail: String?)] = []
        func record(event: String, detail: String?) {
            lock.lock(); defer { lock.unlock() }
            entries.append((event, detail))
        }
        func count(of event: String, detailContains fragment: String? = nil) -> Int {
            lock.lock(); defer { lock.unlock() }
            return entries.filter {
                $0.event == event && (fragment == nil || $0.detail?.contains(fragment!) == true)
            }.count
        }
    }

    /// 验收标准 1/2：录音会话进入 .playAndRecord 激活态后，生产释放路径
    /// 必须交还会话（session_released result=true），紧随其后的播放必须
    /// 完整出声——修复前该激活链两级全 !res、落 playback_activation_exhausted。
    func testPlaybackSucceedsAfterRecordingSessionHandover() async throws {
        try await waitForHostWelcomeToFinish()
        let events = EventLog()
        WatchLog.setObserver { _, event, detail, _ in events.record(event: event, detail: detail) }
        defer { WatchLog.setObserver(nil) }

        let recorder = AudioRecorder()
        var captured = false
        do {
            try await recorder.start()
            captured = true
        } catch RecorderError.permissionDenied {
            throw XCTSkip("宿主未授权麦克风：先 xcrun simctl privacy <sim> grant microphone 再跑")
        } catch RecorderError.cannotCreateRecorder {
            // 模拟器 headless 限制：起录失败，但 start() 已把共享会话配成
            // .playAndRecord 并激活——正是事故的危险态，继续走释放路径。
        }
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playAndRecord, "start() 后会话应处于 .playAndRecord（事故前置态）")

        if captured {
            try await Task.sleep(for: .milliseconds(700))
            let recording = try recorder.finish()
            try? FileManager.default.removeItem(at: recording.fileURL)
            XCTAssertFalse(recording.data.isEmpty, "录音必须产出非空音频")
        } else {
            recorder.cancel()
        }
        XCTAssertGreaterThan(
            events.count(of: "session_released", detailContains: "result=true"), 0,
            "录音收尾必须落 session_released result=true（ESS-72 要求的交还观测点）"
        )

        // 会话刚交还立刻播放——事故链的第二拍，两级激活不得耗尽。
        let player = SpeechPlayer()
        let data = try welcomeSpeechData()
        let finished = expectation(description: "playback finished")
        var playedToEnd = false
        let accepted = player.play(data: data, context: "ess72-record-then-play") { ok in
            playedToEnd = ok
            finished.fulfill()
        }
        XCTAssertTrue(accepted, "play() 必须受理请求")
        await fulfillment(of: [finished], timeout: 20)
        XCTAssertTrue(playedToEnd, "录音收尾后的播放必须完整出声（会话已交还，无 !res）")
        XCTAssertEqual(
            events.count(of: "playback_activation_exhausted"), 0,
            "两级激活不得耗尽——!res 复现即失败"
        )
    }

    /// 验收标准 3：连续「录音→播放」两轮，两个方向都不许坏——
    /// 第二轮录音同时回归 ESS-61 的「播放 → 录音」方向（-50）。
    /// 需要真实采集；headless 模拟器起录必败时跳过（真机装机由 G9 S3R 拦）。
    func testAlternatingRecordPlayTwoRounds() async throws {
        try await waitForHostWelcomeToFinish()
        let recorder = AudioRecorder()
        let player = SpeechPlayer()
        let data = try welcomeSpeechData()

        for round in 1...2 {
            do {
                try await recorder.start()
            } catch RecorderError.permissionDenied {
                throw XCTSkip("宿主未授权麦克风：先 xcrun simctl privacy <sim> grant microphone 再跑")
            } catch RecorderError.cannotCreateRecorder {
                recorder.cancel()
                throw XCTSkip("当前环境无法真实采集（headless 模拟器限制），全链交替只在真机跑")
            }
            try await Task.sleep(for: .milliseconds(700))
            let recording = try recorder.finish()
            try? FileManager.default.removeItem(at: recording.fileURL)
            XCTAssertFalse(recording.data.isEmpty, "第 \(round) 轮录音必须产出非空音频")

            let finished = expectation(description: "round \(round) playback finished")
            var playedToEnd = false
            player.play(data: data, context: "ess72-alternate-r\(round)") { ok in
                playedToEnd = ok
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 20)
            XCTAssertTrue(playedToEnd, "第 \(round) 轮录音→播放必须完整出声")
        }
    }
}
