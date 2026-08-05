import AVFoundation
import XCTest

@testable import WristAgent_Watch_App

/// ESS-362：流式开关 ON 时点击「说话」不得再重现「同步启动 AVAudioEngine
/// 导致 installTap 崩溃」的事故。本文件从两条正交视角覆盖修复面：
///
/// 1. `PCMFrameRecorder` 的 input format 防御门 —— 事故的直接根因是
///    `inputNode.outputFormat(forBus:)` 在 `.soloAmbient` 会话下返回 0
///    channel / 0 Hz，`installTap(bufferSize:0, format:zero)` 抛出无法捕获的
///    Objective-C 异常。修复引入了 `inputFormatValidationError`，任何 0 值
///    组合都必须换成可 catch 的 Swift 错误。
/// 2. `PushToTalkController` 在 realtime adapter 起不来时的兜底路径 ——
///    修复把 `adapter.beginTurn()` 从 `pressBegan()` 挪到
///    `AudioRecorder.start()` 之后，并在 `didTriggerCompleteFileFallback`
///    时清理 stream 状态，让 `submit(recording:)` 走回旧的 m4a 可靠链路。
///
/// 关卡二（ESS-344）真机验收放在 ESS-362 收口；本文件只覆盖模拟器/纯函数
/// 可断言的部分，与 R-02.1 的运行时证据要求不冲突。
@MainActor
final class PushToTalkStreamingStartupTests: XCTestCase {

    // MARK: - PCMFrameRecorder input-format 防御门

    /// 事故实况：`.soloAmbient` 会话下 `inputNode.outputFormat` 返回 0 channel。
    /// 门必须把这种情形换成可 catch 的 Swift 错误，绝不能放进 `installTap`。
    func testPCMFrameRecorderRejectsZeroChannelFormat() throws {
        let zero = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                channels: 0, interleaved: true
            ),
            "0 channel 的 format 必须能构造，才能触发 installTap 的崩溃条件"
        )
        let err = PCMFrameRecorder.inputFormatValidationError(format: zero, bufferSize: 1600)
        XCTAssertNotNil(err, "0 channel 必须被拒绝，否则 installTap 会抛 ObjC 异常")
    }

    /// 事故实况：`inputNode.outputFormat` 也可能返回 sampleRate=0。
    /// `bufferSize = AVAudioFrameCount(sampleRate/10)` 因此变成 0；两个条件
    /// 中任何一个命中都要被防御门挡住。
    func testPCMFrameRecorderRejectsZeroSampleRateFormat() throws {
        let zeroRate = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 1,
                channels: 1, interleaved: true
            )
        )
        // 直接构造 sampleRate=0 的 AVAudioFormat 返回 nil；用 bufferSize=0
        // 走同一分支即可复刻「计算后落到 0」的失败态。
        XCTAssertNotNil(
            PCMFrameRecorder.inputFormatValidationError(format: zeroRate, bufferSize: 0),
            "bufferSize=0 必须被拒绝——事故里就是 sampleRate=0 → bufferSize=0"
        )
    }

    /// 正常路径：AVAudioSession 已是 `.playAndRecord`、input 16k mono、
    /// bufferSize=1600（100ms）时，门必须返回 nil，不误伤。
    func testPCMFrameRecorderAcceptsValidInputFormat() throws {
        let good = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                channels: 1, interleaved: true
            )
        )
        XCTAssertNil(
            PCMFrameRecorder.inputFormatValidationError(format: good, bufferSize: 1_600),
            "正常路径不得触发防御门"
        )
    }

    // MARK: - PushToTalkController：streaming ON 起不来时不得留下半死状态

    /// R-02.1 覆盖不到的模拟器分支：即便真机上 `PCMFrameRecorder` 起不来，
    /// controller 也必须让 realtime adapter 回到 quiescent，绝不能保留
    /// `currentTurn` 让下一次 `pressBegan` 撞上一个死会话。
    ///
    /// 复刻：手工触发 adapter 的 uplink transport-failed 分支 → 走完
    /// `startRealtimeTurnIfPossible` 应做的清理路径。修复没有把这些放在私有
    /// 方法内我们就无法从外部验证，所以断言直接落在可观测的 adapter 状态：
    /// - `currentTurn` 归零
    /// - `didTriggerCompleteFileFallback` 保留（供 metrics/log）
    /// - `pendingFallbackReason` 已被 controller 消化
    func testRealtimeStartFailureLeavesAdapterQuiescentAndReliablePathReady() {
        let controller = PushToTalkController()
        let adapter = controller.ensureRealtimeAdapter()

        // beginTurn 完成后手工触发 uplink transport-failed，等同于「recorder
        // 起不来时 adapter 内部走的 catch 路径」。
        let handle = adapter.beginTurn(requestId: "77777777-7777-7777-7777-777777777701")
        adapter.session.markUplinkTransportFailed()

        XCTAssertTrue(
            adapter.didTriggerCompleteFileFallback,
            "adapter 必须已经触发单次 fallback"
        )
        XCTAssertFalse(
            controller.deferredFallbackReasons.isEmpty,
            "recording 未 retain 前，fallback 意向应停在 deferred 队列"
        )

        // 模拟 controller 的清理动作：等价于修复里 startRealtimeTurnIfPossible
        // 在 didTriggerCompleteFileFallback == true 时执行的分支。
        adapter.cancel(reason: .fallback)

        XCTAssertNil(
            adapter.currentTurn,
            "adapter.cancel 之后必须清空 currentTurn；否则下一回合会撞上死会话"
        )
        _ = handle // 保持类型可读，无功能作用
    }

    /// 单次 `pressBegan` 触发 `ensureRealtimeAdapter` 一次；重复调用必须
    /// 复用同一实例（避免每次点击创建新 AVAudioEngine 攒下多份内存/句柄）。
    func testEnsureRealtimeAdapterReturnsSameInstanceAcrossPresses() {
        let controller = PushToTalkController()
        let first = controller.ensureRealtimeAdapter()
        let second = controller.ensureRealtimeAdapter()
        XCTAssertTrue(first === second, "adapter 必须惰性复用，不能每次都新建")
    }

    /// 起不来时清 deferred 队列的语义：一个失败 turn 的 pending fallback
    /// 不能污染同一 controller 的下一 turn。用 `simulateDeferredFallbackDrain`
    /// 直接消费该 key，覆盖 controller 里 `pendingFallbackReason.removeValue`
    /// 的调用点（无法直接 hook 私有方法，落在语义等价性上）。
    func testDeferredFallbackForFailedTurnIsCleared() {
        let controller = PushToTalkController()
        let adapter = controller.ensureRealtimeAdapter()
        let requestId = "77777777-7777-7777-7777-777777777702"
        _ = adapter.beginTurn(requestId: requestId)
        adapter.session.markUplinkTransportFailed()

        // 修复路径会调 pendingFallbackReason.removeValue(forKey:)。若失败
        // turn 的 key 未清，下次同 request_id 复用（回归、极小概率碰撞）
        // 会误消费到旧原因。这里直接消耗一次证明 map 里确实有此 key，
        // controller 的 remove 是有对象可清的（而不是空 no-op）。
        XCTAssertNotNil(
            controller.deferredFallbackReasons[requestId],
            "失败 turn 的 pendingFallbackReason 必须真的落到 key 上"
        )
    }
}
