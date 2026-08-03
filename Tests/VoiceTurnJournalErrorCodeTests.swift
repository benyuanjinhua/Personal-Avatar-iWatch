import XCTest
@testable import WristAgentCore

/// ESS-180：Journal apply(_:) 把 failed 信封里的稳定 error_code 落到
/// VoiceTurnRecord 上；一旦锁定不被后续乱序事件覆盖。
@MainActor
final class VoiceTurnJournalErrorCodeTests: XCTestCase {
    private let requestId = "019fbbdd-5c39-70fa-9760-dc262ee092b0"

    private func makeJournal() -> VoiceTurnJournal {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ess180-journal-\(UUID().uuidString)")
        return VoiceTurnJournal(directory: dir)
    }

    func testFailedApplyStoresErrorCode() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId, state: .failed,
            detail: "ERR_VOICE_BUSY", failureStage: .execution,
            errorCode: "ERR_VOICE_BUSY"
        )
        XCTAssertTrue(journal.apply(envelope))
        XCTAssertEqual(journal.turn(withId: requestId)?.errorCode, "ERR_VOICE_BUSY")
    }

    func testFailedWithoutErrorCodeLeavesFieldNil() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId, state: .failed,
            failureStage: .execution, errorCode: nil
        )
        XCTAssertTrue(journal.apply(envelope))
        XCTAssertNil(journal.turn(withId: requestId)?.errorCode,
                     "无 code 让 catalog 走 generic，不塞占位符")
    }

    /// ESS-204 复审缺陷回归：failed envelope 一到，`onStateApplied` 触发时
    /// `turns[requestId].errorCode` 必须已经写入，UI 端在回调里 `journal.turn(...)?.errorCode`
    /// 能读到具体 code——不能读到 nil、只能展示 generic 卡片。
    ///
    /// 旧路径的顺序是：append(→ onStateApplied) → 才写 errorCode。回调里读
    /// errorCode 只能得 nil，presenter 展示 generic 后又按 requestId 去重，
    /// 首次失败永远没机会显示正确文案。修复口径：在 apply(_:) 里先挂
    /// permission/result/errorCode，再调 append。
    func testFailedCallbackObservesErrorCodeAlreadyOnRecord() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        var observedCodeInsideCallback: String? = "sentinel"
        journal.onStateApplied = { rid, state in
            guard state == .failed else { return }
            observedCodeInsideCallback = journal.turn(withId: rid)?.errorCode
        }
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId, state: .failed,
            detail: "ERR_VOICE_BUSY", failureStage: .execution,
            errorCode: "ERR_VOICE_BUSY"
        )
        XCTAssertTrue(journal.apply(envelope))
        XCTAssertEqual(observedCodeInsideCallback, "ERR_VOICE_BUSY",
                       "onStateApplied 触发时字段已就位，UI 才能按 code 查表")
    }

    /// ESS-204 二次断言：completed 时 result 载荷同样必须先挂上——旧路径
    /// `onResultRecorded` 在 append 之后触发，但如果哪天迁到 onStateApplied
    /// 里读 result，会遇到同一类竞态。这里把 payload-before-callback 的
    /// 契约作为通用不变量固定下来。
    func testCompletedCallbackObservesResultAlreadyOnRecord() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        var observedResultInsideCallback: VoiceResultPayload? = nil
        journal.onStateApplied = { rid, state in
            guard state == .completed else { return }
            observedResultInsideCallback = journal.turn(withId: rid)?.result
        }
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId, state: .completed,
            result: VoiceResultPayload(summary: "ok", isTruncated: false,
                                        speechSha256: nil, speechDurationMs: nil)
        )
        XCTAssertTrue(journal.apply(envelope))
        XCTAssertEqual(observedResultInsideCallback?.summary, "ok")
    }

    /// ESS-204 回滚不变量：apply 的 payload 只应在 append 成功（能真正
    /// transition）时保留。终态之后再来一个 failed 应被状态机拒绝，且
    /// 之前的 errorCode 不能被这次未生效的写覆盖。
    func testRejectedTransitionRollsBackPayloadWrite() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        // 第一次 failed 落 code_1，锁定。
        XCTAssertTrue(journal.apply(VoiceStatusEnvelope.status(
            requestId: requestId, state: .failed,
            failureStage: .execution, errorCode: "ERR_CODE_ORIGINAL"
        )))
        XCTAssertEqual(journal.turn(withId: requestId)?.errorCode, "ERR_CODE_ORIGINAL")

        // 终态之后再来一次 failed（携带不同 code）：状态机拒绝，errorCode 不变。
        XCTAssertFalse(journal.apply(VoiceStatusEnvelope.status(
            requestId: requestId, state: .failed,
            failureStage: .execution, errorCode: "ERR_CODE_LATER"
        )))
        XCTAssertEqual(journal.turn(withId: requestId)?.errorCode, "ERR_CODE_ORIGINAL",
                       "被拒的 transition 不能覆盖已锁定 errorCode")
    }

    func testCompletedNeverCarriesErrorCode() {
        let journal = makeJournal()
        journal.begin(requestId: requestId)
        // 即使有 bug 把 errorCode 塞进 completed 信封，也不能落到回合上——
        // 语义无效，宁可丢也不装作是失败。
        let envelope = VoiceStatusEnvelope.status(
            requestId: requestId, state: .completed,
            result: VoiceResultPayload(summary: "ok", isTruncated: false, speechSha256: nil, speechDurationMs: nil),
            errorCode: "ERR_SHOULD_BE_IGNORED"
        )
        XCTAssertTrue(journal.apply(envelope))
        XCTAssertNil(journal.turn(withId: requestId)?.errorCode)
    }
}
