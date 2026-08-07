import XCTest

@testable import WristAgent_Watch_App

@MainActor
final class RecorderErrorCopyTests: XCTestCase {
    func testPermissionDeniedPointsToMicrophoneSettings() {
        XCTAssertEqual(
            RecorderError.permissionDenied.errorDescription,
            "麦克风权限未开启，请前往手表设置 → 隐私 → 麦克风，允许腕语访问。"
        )
    }

    func testRecorderInitializationFailureProvidesImmediateRetryAction() {
        XCTAssertEqual(
            RecorderError.cannotCreateRecorder.errorDescription,
            "录音器启动失败，请松开后再按住重试。"
        )
    }

    func testRecordingTooShortAsksUserToSpeakLonger() {
        XCTAssertEqual(
            RecorderError.recordingTooShortDescription,
            "按住时间太短，请按住不放再说。"
        )
    }

    /// ESS-538：被息屏/中断截断的录音给出「被打断、重说」的可行动文案，
    /// 与「按太短」区分——用户不是按太短，是录音被系统打断了。
    func testRecordingInterruptedAsksUserToReRecord() {
        XCTAssertEqual(
            RecorderError.recordingInterrupted.errorDescription,
            "刚才录音被打断了，请按住重新说一次。"
        )
    }

    func testAllRecorderErrorsRemainChineseAndDoNotExposeSystemDomains() {
        let descriptions = [
            RecorderError.permissionDenied,
            .sessionActivationFailed,
            .cannotCreateRecorder,
            .noRecording,
            .recordingNeverStarted,
            .recordingInterrupted,
        ].compactMap(\.errorDescription)

        XCTAssertEqual(descriptions.count, 6)
        for description in descriptions {
            XCTAssertFalse(description.contains("OSStatus"))
            XCTAssertFalse(description.contains("NSOSStatusErrorDomain"))
        }
    }

    func testUnexpectedSystemErrorIsSanitizedBeforeReachingUI() {
        let systemError = NSError(
            domain: "NSOSStatusErrorDomain",
            code: -50,
            userInfo: [NSLocalizedDescriptionKey: "The operation failed. (OSStatus error -50.)"]
        )

        let description = PushToTalkController.recordingErrorDescription(systemError)

        XCTAssertEqual(description, "录音启动失败，请松开后再按住重试。")
        XCTAssertFalse(description.contains("OSStatus"))
        XCTAssertFalse(description.contains("NSOSStatusErrorDomain"))
    }
}
