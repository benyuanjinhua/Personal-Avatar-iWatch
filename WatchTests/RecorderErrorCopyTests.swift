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

    func testAllRecorderErrorsRemainChineseAndDoNotExposeSystemDomains() {
        let descriptions = [
            RecorderError.permissionDenied,
            .sessionActivationFailed,
            .cannotCreateRecorder,
            .noRecording,
            .recordingNeverStarted,
        ].compactMap(\.errorDescription)

        XCTAssertEqual(descriptions.count, 5)
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
